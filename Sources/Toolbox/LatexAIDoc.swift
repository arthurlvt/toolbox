import SwiftUI
import AppKit
import PDFCore

// MARK: - Modèle LaTeX sur mesure, rédigé par l'IA locale

/// « Autre » + une description : Ollama écrit un document dans le style des modèles Toolbox,
/// Toolbox le compile pour vérifier, et renvoie les erreurs à l'IA (3 essais au plus).
final class LatexDocGenerator: ObservableObject {
    static let shared = LatexDocGenerator()

    @Published private(set) var running = false
    @Published private(set) var phase = ""
    @Published private(set) var chars = 0
    @Published private(set) var tail = ""
    @Published var error: String?

    static let maxAttempts = 3
    private var task: Task<Void, Never>?

    /// Mémoire : contexte limité à 8 k jetons (au lieu de 16 k) et modèle déchargé dès la fin.
    static let contextTokens = 8192
    private var loadedModel: String?

    func cancel() {
        task?.cancel()
        task = nil
        running = false
        phase = ""
        releaseMemory()
    }

    /// Décharge le modèle tout de suite : la RAM est rendue au Mac dès la fin de la génération.
    func releaseMemory() {
        guard let m = loadedModel else { return }
        loadedModel = nil
        let client = OllamaService.shared.client
        Task { await client.unload(m) }
    }

    func generate(form: NewLatexDocForm, model: LatexModel) {
        let request = form.aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !running else { return }
        if form.title.trimmingCharacters(in: .whitespaces).isEmpty {
            form.title = Self.shortTitle(request)
        }
        running = true
        error = nil
        chars = 0
        tail = ""
        phase = "Démarrage d'Ollama…"
        OllamaService.shared.ensureRunning { [weak self] ok in
            guard let self = self, self.running else { return }
            guard ok else { self.fail(OllamaService.shared.state.label); return }
            self.phase = "Choix du modèle…"
            model.ai.refreshModels { [weak self] in
                guard let self = self, self.running else { return }
                let name = model.ai.model
                guard !name.isEmpty else { self.fail("Aucun modèle Ollama installé. Dans le Terminal : ollama pull qwen2.5-coder:7b"); return }
                self.run(request: request, modelName: name, form: form, model: model)
            }
        }
    }

    private func fail(_ message: String) {
        releaseMemory()
        running = false
        phase = ""
        error = message
    }

    private func run(request: String, modelName: String, form: NewLatexDocForm, model: LatexModel) {
        let url = form.destination()
        var ref = form.values
        ref.kind = .cours
        // référence courte (préambule + encadrés) : moins de jetons = moins de mémoire
        let reference = LatexDocTemplates.preamble(cours: true, fancy: true, v: ref, lang: nil)
            + "\n\n" + LatexDocTemplates.courseBoxes
            + "\n\n\\begin{document}\n\\section{Titre}\n\\begin{definition}[nom]\n\\dots\n\\end{definition}\n\\end{document}"
        self.loadedModel = modelName
        let v = form.values
        let client = OllamaService.shared.client
        let system = Self.systemPrompt
        let user = """
        Modèle de référence (style à reprendre : préambule, couleurs, encadrés, en-têtes) :
        ```latex
        \(reference)
        ```

        Informations à utiliser :
        - auteur : \(v.author.isEmpty ? "(aucun)" : v.author)
        - formation : \(v.formation), Avignon Université (CERI)
        - année universitaire : \(v.annee.replacingOccurrences(of: "--", with: "–"))
        - titre souhaité : \(form.title)

        Demande de l'étudiant :
        \(request)
        """
        task = Task { [weak self] in
            guard let self = self else { return }
            var messages = [OllamaMessage(role: "system", content: system), OllamaMessage(role: "user", content: user)]
            var lastLog = ""
            var compiled = false
            var wrote = false
            for attempt in 1...Self.maxAttempts {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.phase = attempt == 1 ? "Rédaction par \(modelName)…" : "Correction par l'IA (essai \(attempt)/\(Self.maxAttempts))…"
                    self.chars = 0
                    self.tail = ""
                }
                let answer: String
                do {
                    answer = try await client.chat(model: modelName, messages: messages,
                                                   options: ["temperature": 0.3, "num_ctx": Self.contextTokens],
                                                   keepAlive: "1m") { piece in
                        DispatchQueue.main.async {
                            self.chars += piece.count
                            self.tail = String((self.tail + piece).suffix(160))
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { self.fail(error.localizedDescription) }
                    return
                }
                if Task.isCancelled { return }
                guard let tex = Self.extractDocument(answer) else {
                    messages = [OllamaMessage(role: "system", content: system),
                                OllamaMessage(role: "user", content: user + "\n\nIMPORTANT : renvoie UNIQUEMENT le document entier, de \\documentclass à \\end{document}, dans un seul bloc ```latex.")]
                    continue
                }
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ("% Modèle rédigé par l'IA locale (\(modelName)) avec Toolbox\n% Demande : "
                         + request.replacingOccurrences(of: "\n", with: " ") + "\n" + tex)
                        .write(to: url, atomically: true, encoding: .utf8)
                    wrote = true
                } catch {
                    await MainActor.run { self.fail(error.localizedDescription) }
                    return
                }
                await MainActor.run { self.phase = "Compilation de vérification…" }
                let engine = LatexModel.guessEngine(url)
                let result = await Task.detached { try? Latex.compile(url, engine: engine) }.value
                if result?.success == true { compiled = true; break }
                lastLog = result?.log ?? ""
                let errors = Latex.parseIssues(lastLog).filter { !$0.isWarning }.prefix(4)
                let report = errors.isEmpty
                    ? String(lastLog.suffix(1500))
                    : errors.map { "- \($0.location.isEmpty ? "" : $0.location + " : ")\($0.message)" }.joined(separator: "\n")
                // on repart d'une conversation courte (document + erreurs) pour ne pas faire gonfler le contexte
                messages = [OllamaMessage(role: "system", content: system), OllamaMessage(role: "user", content: """
                Ce document LaTeX ne compile pas avec \(engine.rawValue).
                ```latex
                \(tex)
                ```
                Erreurs :
                \(report)

                Corrige-les (n'utilise que des paquets standards de TeX Live) et renvoie le document COMPLET corrigé, dans un seul bloc ```latex, sans explication.
                """)]
            }
            let ok = compiled, written = wrote
            await MainActor.run {
                self.releaseMemory()
                self.running = false
                self.phase = ""
                guard written else {
                    self.error = "L'IA n'a pas renvoyé de document exploitable. Reformule ta demande ou essaie un autre modèle."
                    return
                }
                LatexDocsStore.shared.register(url, kind: "autre", title: form.title, matiere: form.kind == .autre ? "" : form.courseName)
                form.remember()
                form.aiPrompt = ""
                form.show = false
                model.open(url)
                model.compile()
                if ok {
                    ToastCenter.shared.show("✨ Modèle créé par l'IA et compilé sans erreur")
                } else {
                    model.status = .err("L'IA n'a pas réussi à le faire compiler en \(Self.maxAttempts) essais : clique une erreur puis ✨ pour la corriger.")
                }
            }
        }
    }

    static let systemPrompt = """
    Tu es un expert LaTeX qui prépare des modèles de documents pour un étudiant français en informatique.
    Règles :
    - Réponds UNIQUEMENT par un document LaTeX complet (de \\documentclass à \\end{document}) dans un seul bloc ```latex, sans aucune explication.
    - Il doit compiler avec pdflatex et les paquets standards de TeX Live : pas de fichier externe, pas d'image, pas de \\input, pas de classe maison, pas de police système.
    - Reprends le style du modèle de référence : même préambule (iftex, babel french, couleurs annbleu, annvert, annorange…, tcolorbox, listings, fancyhdr) et ses encadrés quand ils sont utiles. N'ajoute une page de titre et un sommaire que si le document est long.
    - Adapte la mise en page à la demande (taille du texte, colonnes, tableaux, encadrés, marges…).
    - Rédige en français. Pré-remplis la structure avec des titres, de courts exemples et des emplacements \\dots à compléter ; ne rédige pas tout le contenu.
    - Ferme tous les environnements et échappe les caractères & % # _ dans le texte.
    """

    /// Le document dans la réponse : le dernier bloc ```latex, sinon de \documentclass à \end{document}.
    static func extractDocument(_ answer: String) -> String? {
        var text = LatexAI.latexBlock(in: answer) ?? answer
        if !text.contains("\\documentclass") { text = answer }
        guard let start = text.range(of: "\\documentclass"),
              let end = text.range(of: "\\end{document}", options: .backwards), end.lowerBound > start.lowerBound else { return nil }
        // garde les commentaires « % !TEX » éventuels juste avant \documentclass
        var from = start.lowerBound
        let before = text[..<from]
        if let r = before.range(of: "% !TEX", options: .backwards), !before[r.lowerBound...].contains("\\") { from = r.lowerBound }
        return String(text[from..<end.upperBound]) + "\n"
    }

    static func shortTitle(_ request: String) -> String {
        let firstLine = request.components(separatedBy: .newlines).first ?? request
        let words = firstLine.split(separator: " ").prefix(7).joined(separator: " ")
        let t = words.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?"))
        return t.isEmpty ? "Document IA" : t.prefix(1).uppercased() + t.dropFirst()
    }
}

// MARK: - Champs dans la feuille « Nouveau document » (type Autre)

struct AIDocFields: View {
    @ObservedObject var f = NewLatexDocForm.shared
    @ObservedObject var ai: LatexAI
    @ObservedObject var ollama = OllamaService.shared

    /// Un modèle qui occupe plus de ~45 % de la RAM fait ramer tout le Mac.
    private var memoryWarning: String? {
        guard let m = ai.models.first(where: { $0.name == ai.model }), m.size > 0 else { return nil }
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        let need = Double(m.size) * 1.25 + 0.6e9       // poids + contexte 8 k
        guard need > ram * 0.45 else { return nil }
        let gb: (Double) -> String = { String(format: "%.1f Go", $0 / 1e9) }
        let lighter = ai.models.filter { Double($0.size) * 1.25 + 0.6e9 <= ram * 0.45 }.min { $0.size < $1.size }
        return "\(m.name) demande environ \(gb(need)) sur \(gb(ram)) de RAM : ton Mac va ramer. "
            + (lighter.map { "Prends plutôt \($0.name)." } ?? "Installe un modèle plus léger : ollama pull qwen2.5-coder:3b (≈ 2 Go).")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Décris ce que tu veux (facultatif) : l'IA locale prépare un modèle sur mesure", systemImage: "sparkles")
                .font(.callout.weight(.medium))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $f.aiPrompt)
                    .font(.callout)
                    .frame(height: 76)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                if f.aiPrompt.isEmpty {
                    Text("Ex. : une fiche de révision recto-verso sur les suites, deux colonnes, avec un tableau des limites usuelles")
                        .font(.callout).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            if let warn = memoryWarning {
                Label(warn, systemImage: "memorychip")
                    .font(.caption).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Circle().fill(ollama.state.ok ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(ollama.state.ok ? "Ollama prêt" : ollama.state.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !ai.models.isEmpty {
                    Picker("Modèle", selection: $ai.model) {
                        ForEach(ai.models) { m in Text("\(m.name) (\(m.sizeLabel))").tag(m.name) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            if ai.models.isEmpty {
                OllamaService.shared.ensureRunning { ok in if ok { ai.refreshModels() } }
            }
        }
    }
}

/// Bandeau de progression pendant la génération.
struct AIDocProgress: View {
    @ObservedObject var g = LatexDocGenerator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(g.phase).font(.callout.weight(.medium))
                Spacer()
                if g.chars > 0 { Text("\(g.chars) caractères").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if !g.tail.isEmpty {
                Text(g.tail.replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.head)
            }
            Text("Sur un MacBook Air, compte 30 s à 1 min 30 par essai.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.08)))
    }
}
