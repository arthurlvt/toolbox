import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFCore

/// IA locale (Ollama) dans l'éditeur LaTeX : expliquer une erreur, transcrire une formule photographiée.
/// Même serveur que l'onglet Annalyse (adresse réglée dans Annalyse → Réglages).
final class LatexAI: ObservableObject {
    @Published var models: [OllamaModel] = []
    @Published var vision: Set<String> = []
    @Published var model: String = UserDefaults.standard.string(forKey: "latex.aimodel") ?? "" {
        didSet { UserDefaults.standard.set(model, forKey: "latex.aimodel") }
    }
    @Published var ollamaError = ""

    // Explication d'erreur
    @Published var showExplain = false
    @Published var explainTitle = ""
    @Published var explainText = ""
    @Published var running = false
    @Published var suggestion: String?
    var suggestionTarget: (file: URL, from: Int, to: Int)?

    // Formule depuis une image
    @Published var showFormula = false
    @Published var formulaImage: NSImage?
    @Published var formulaTex = ""
    @Published var formulaPDF: URL?
    @Published var formulaPreviewToken = 0
    @Published var formulaError = ""
    @Published var formulaRunning = false
    @Published var formulaDisplay = true

    private var task: Task<Void, Never>?

    var host: String {
        let h = UserDefaults.standard.string(forKey: "annales.host") ?? ""
        return h.isEmpty ? OllamaClient.defaultHost : h
    }

    var client: OllamaClient { OllamaClient(host: host) }

    // MARK: Modèles

    func refreshModels(then next: (() -> Void)? = nil) {
        Task {
            do {
                let list = try await client.models()
                var caps: Set<String> = []
                for m in list {
                    if await client.capabilities(m.name).contains("vision") { caps.insert(m.name) }
                }
                let visionModels = caps
                await MainActor.run {
                    self.models = list
                    self.vision = visionModels
                    self.ollamaError = list.isEmpty ? "Aucun modèle installé (ollama pull qwen2.5:7b)." : ""
                    if self.model.isEmpty || !list.contains(where: { $0.name == self.model }) {
                        let annales = UserDefaults.standard.string(forKey: "annales.model") ?? ""
                        self.model = list.first { $0.name == annales }?.name ?? list.first?.name ?? ""
                    }
                    next?()
                }
            } catch {
                await MainActor.run {
                    self.models = []
                    self.ollamaError = error.localizedDescription
                    next?()
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
        formulaRunning = false
    }

    // MARK: Expliquer une erreur

    func explain(issue: LatexIssue, file: URL?, text: String, log: String) {
        cancel()
        explainTitle = issue.message
        explainText = ""
        suggestion = nil
        suggestionTarget = nil
        showExplain = true

        // Les lignes autour de l'erreur, numérotées.
        let lines = text.components(separatedBy: "\n")
        var excerpt = ""
        if let file = file, let line = issue.line, line >= 1, line <= max(1, lines.count) {
            let from = max(1, line - 6), to = min(lines.count, line + 6)
            excerpt = (from...to).map { "\($0): \(lines[$0 - 1])" }.joined(separator: "\n")
            suggestionTarget = (file, from, to)
        }
        // Le passage du journal qui parle de cette erreur.
        var logPart = ""
        let key = String(issue.message.prefix(40))
        if !key.isEmpty, let r = log.range(of: key) {
            logPart = String(log[r.lowerBound...].prefix(1200))
        } else {
            logPart = String(log.suffix(1200))
        }
        let where_ = issue.location.isEmpty ? "" : " (\(issue.location))"
        let prompt = """
        Erreur de compilation LaTeX\(where_) : \(issue.message)

        Extrait du journal :
        \(logPart)

        \(excerpt.isEmpty ? "Le numéro de ligne n'est pas connu." : "Lignes concernées du fichier (numérotées) :\n" + excerpt)
        """
        let system = """
        Tu es un expert LaTeX qui aide un étudiant francophone. Réponds en français, de façon courte et concrète :
        1) ce que veut dire cette erreur, en une ou deux phrases simples ;
        2) la cause dans le code fourni ;
        3) comment la corriger.
        \(excerpt.isEmpty ? "" : "Termine par les lignes corrigées, SANS leurs numéros, dans un unique bloc ```latex … ``` qui remplace exactement toutes les lignes numérotées fournies (recopie à l'identique celles qui ne changent pas). Si la correction est ailleurs (paquet manquant dans le préambule…), dis-le et ne mets pas de bloc.")
        """
        runExplain(system: system, prompt: prompt)
    }

    private func runExplain(system: String, prompt: String) {
        running = true
        let finish: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.running = false
            self.suggestion = Self.latexBlock(in: self.explainText)
        }
        refreshModels { [weak self] in
            guard let self = self else { return }
            guard !self.model.isEmpty else {
                self.explainText = "Ollama n'est pas joignable ou aucun modèle n'est installé.\n\(self.ollamaError)"
                self.running = false
                return
            }
            let model = self.model, client = self.client
            self.task = Task {
                do {
                    _ = try await client.chat(model: model,
                                              messages: [OllamaMessage(role: "system", content: system),
                                                         OllamaMessage(role: "user", content: prompt)],
                                              options: ["temperature": 0.2, "num_ctx": 8192]) { piece in
                        DispatchQueue.main.async { self.explainText += piece }
                    }
                    await MainActor.run { finish() }
                } catch {
                    await MainActor.run {
                        self.explainText += "\n\n⚠️ " + error.localizedDescription
                        self.running = false
                    }
                }
            }
        }
    }

    static func latexBlock(in text: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: "```(?:latex|tex)?[ \\t]*\\n(.*?)```", options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let m = rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let block = ns.substring(with: m.range(at: 1))
        // au cas où le modèle aurait laissé les numéros de ligne
        let cleaned = block.components(separatedBy: "\n").map { line -> String in
            if let r = line.range(of: #"^\d+: ?"#, options: .regularExpression) { return String(line[r.upperBound...]) }
            return line
        }.joined(separator: "\n")
        return cleaned.trimmingCharacters(in: .newlines).isEmpty ? nil : cleaned.trimmingCharacters(in: .newlines)
    }

    // MARK: Formule depuis une image

    func openFormula() {
        cancel()
        formulaImage = nil
        formulaTex = ""
        formulaPDF = nil
        formulaError = ""
        showFormula = true
        refreshModels()
        // Une image déjà copiée (capture d'écran) ? On la prend directement.
        if let img = NSImage(pasteboard: NSPasteboard.general), NSPasteboard.general.string(forType: .string) == nil {
            formulaImage = img
        }
    }

    func setImage(_ image: NSImage?) {
        guard let image = image else { return }
        formulaImage = image
        formulaTex = ""
        formulaPDF = nil
        formulaError = ""
        transcribe()
    }

    var visionModel: String? {
        if vision.contains(model) { return model }
        return models.first { vision.contains($0.name) }?.name
    }

    func transcribe() {
        guard let image = formulaImage, let b64 = Self.jpegBase64(image) else { return }
        cancel()
        formulaRunning = true
        formulaError = ""
        refreshModels { [weak self] in
            guard let self = self else { return }
            guard let model = self.visionModel else {
                self.formulaRunning = false
                self.formulaError = self.models.isEmpty
                    ? "Ollama n'est pas joignable. \(self.ollamaError)"
                    : "Aucun modèle installé ne sait lire les images. Dans le Terminal : ollama pull qwen2.5vl:7b"
                return
            }
            let client = self.client
            let prompt = """
            Transcris en code LaTeX (amsmath) la ou les formules mathématiques de cette image.
            Réponds UNIQUEMENT avec le code LaTeX, sans $ ni \\[ \\] autour, sans phrase d'explication.
            S'il y a plusieurs lignes, sépare-les par \\\\.
            """
            self.task = Task {
                do {
                    let answer = try await client.chat(model: model,
                                                       messages: [OllamaMessage(role: "user", content: prompt, images: [b64])],
                                                       options: ["temperature": 0])
                    await MainActor.run {
                        self.formulaTex = Self.cleanFormula(answer)
                        self.formulaRunning = false
                        self.renderPreview()
                    }
                } catch {
                    await MainActor.run {
                        self.formulaRunning = false
                        self.formulaError = error.localizedDescription
                    }
                }
            }
        }
    }

    static func cleanFormula(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let block = latexBlock(in: t) { t = block }
        t = t.replacingOccurrences(of: "```", with: "")
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")] {
            if t.hasPrefix(open) && t.hasSuffix(close) && t.count > open.count + close.count {
                t = String(t.dropFirst(open.count).dropLast(close.count))
                break
            }
        }
        for env in ["equation*", "equation", "align*", "align", "gather*", "gather"] {
            t = t.replacingOccurrences(of: "\\begin{\(env)}", with: "").replacingOccurrences(of: "\\end{\(env)}", with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var multiline: Bool { formulaTex.contains("\\\\") }

    /// Petit document « standalone » compilé pour vérifier la formule.
    func renderPreview() {
        let tex = formulaTex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tex.isEmpty else { return }
        let body = multiline ? "\\begin{gather*}\n\(tex)\n\\end{gather*}" : "$\\displaystyle \(tex)$"
        let doc = """
        \\documentclass[preview,border=6pt,varwidth=14cm]{standalone}
        \\usepackage[utf8]{inputenc}
        \\usepackage[T1]{fontenc}
        \\usepackage{amsmath,amssymb}
        \\begin{document}
        \(body)
        \\end{document}
        """
        formulaRunning = true
        runInBackground({ () -> (URL?, String) in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-formule", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("formule.tex")
            try doc.write(to: url, atomically: true, encoding: .utf8)
            let r = try Latex.compile(url, engine: .pdflatex)
            let firstError = Latex.parseIssues(r.log).first { !$0.isWarning }?.message ?? "erreur de compilation"
            return (r.success ? r.pdf : nil, firstError)
        }) { [weak self] result in
            guard let self = self else { return }
            self.formulaRunning = false
            switch result {
            case .success(let (pdf, err)):
                self.formulaPDF = pdf
                self.formulaPreviewToken += 1
                self.formulaError = pdf == nil ? "La formule ne compile pas : \(err). Corrige-la ci-dessous." : ""
            case .failure(let e):
                self.formulaError = e.localizedDescription
            }
        }
    }

    func insertion() -> String {
        let tex = formulaTex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !formulaDisplay { return "$\(tex)$" }
        return multiline ? "\\begin{align*}\n  \(tex)\n\\end{align*}\n" : "\\[\n  \(tex)\n\\]\n"
    }

    static func jpegBase64(_ image: NSImage, maxSide: CGFloat = 1600) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: small)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])?.base64EncodedString()
    }
}

// MARK: - Fenêtre « Expliquer l'erreur »

struct ExplainSheet: View {
    @ObservedObject var model: LatexModel
    @ObservedObject var ai: LatexAI

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Explication de l'erreur", systemImage: "sparkles").font(.title3.bold())
                Spacer()
                Picker("Modèle", selection: $ai.model) {
                    ForEach(ai.models) { Text($0.name).tag($0.name) }
                }
                .frame(maxWidth: 240)
                .disabled(ai.running)
            }
            Text(ai.explainTitle).font(.callout.monospaced()).foregroundStyle(Color.red).lineLimit(3)
            ScrollView {
                Text(ai.explainText.isEmpty ? (ai.running ? "L'IA réfléchit…" : "") : ai.explainText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .frame(minHeight: 260)
            HStack {
                if ai.running { ProgressView().controlSize(.small); Text("Réponse en cours…").foregroundStyle(.secondary) }
                Spacer()
                Button(ai.running ? "Arrêter" : "Fermer") {
                    if ai.running { ai.cancel() } else { ai.showExplain = false }
                }
                .keyboardShortcut(.cancelAction)
                if let t = ai.suggestionTarget, ai.suggestion != nil, !ai.running {
                    Button("Remplacer les lignes \(t.from) à \(t.to)") { model.applySuggestion() }
                        .buttonStyle(.borderedProminent)
                        .help("Applique les lignes corrigées dans l'éditeur (⌘Z pour annuler)")
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}

// MARK: - Fenêtre « Formule depuis une image »

struct FormulaSheet: View {
    @ObservedObject var model: LatexModel
    @ObservedObject var ai: LatexAI

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Formule depuis une image", systemImage: "camera.viewfinder").font(.title3.bold())
            Text("Photo d'un tableau, d'un poly ou capture d'écran (⌃⇧⌘4 puis ⌘V ici) : l'IA locale la transcrit en LaTeX, tu vérifies l'aperçu, puis tu l'insères au curseur.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                imageArea.frame(width: 260, height: 190)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Code LaTeX").font(.subheadline.bold())
                    TextEditor(text: $ai.formulaTex)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Button("Mettre à jour l'aperçu") { ai.renderPreview() }
                            .disabled(ai.formulaTex.isEmpty || ai.formulaRunning)
                        Button("Relancer l'IA") { ai.transcribe() }
                            .disabled(ai.formulaImage == nil || ai.formulaRunning)
                    }
                }
            }
            ZStack {
                PDFPreview(url: ai.formulaPDF, reloadToken: ai.formulaPreviewToken)
                if ai.formulaPDF == nil {
                    Text(ai.formulaRunning ? "Transcription et compilation…" : "L'aperçu de la formule s'affichera ici.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if !ai.formulaError.isEmpty {
                Text(ai.formulaError).font(.caption).foregroundStyle(Color.orange).textSelection(.enabled)
            }
            HStack {
                Picker("", selection: $ai.formulaDisplay) {
                    Text("Centrée \\[ … \\]").tag(true)
                    Text("Dans le texte $ … $").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                if ai.formulaRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Annuler") { ai.cancel(); ai.showFormula = false }.keyboardShortcut(.cancelAction)
                Button("Insérer") {
                    model.send(.insert(ai.insertion()))
                    ai.showFormula = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(ai.formulaTex.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear { if ai.formulaImage != nil && ai.formulaTex.isEmpty { ai.transcribe() } }
    }

    private var imageArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(Color.secondary.opacity(0.5))
            if let img = ai.formulaImage {
                Image(nsImage: img).resizable().scaledToFit().padding(6)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30, weight: .light))
                    Text("Dépose une image ici").font(.callout)
                    HStack {
                        Button("Choisir…") {
                            if let u = Panels.open([.image]).first { ai.setImage(NSImage(contentsOf: u)) }
                        }
                        Button("Coller") { ai.setImage(NSImage(pasteboard: NSPasteboard.general)) }
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    DispatchQueue.main.async { ai.setImage(obj as? NSImage) }
                }
                return true
            }
            FileDrop.load(providers) { urls in
                if let u = urls.first { ai.setImage(NSImage(contentsOf: u)) }
            }
            return true
        }
    }
}
