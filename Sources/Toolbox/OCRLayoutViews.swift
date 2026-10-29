import SwiftUI
import PDFCore

// MARK: - OCR

enum OCRLanguage: String, CaseIterable, Identifiable {
    case frenchEnglish = "Français + anglais"
    case french = "Français"
    case english = "Anglais"

    var id: String { rawValue }

    var codes: [String] {
        switch self {
        case .frenchEnglish: return ["fr-FR", "en-US"]
        case .french: return ["fr-FR"]
        case .english: return ["en-US"]
        }
    }
}

final class OCRStore: ObservableObject {
    @Published var files: [FileItem] = []
    @Published var language: OCRLanguage = .frenchEnglish
    @Published var skipPagesWithText = true
    @Published var progress = ""
    @Published var working = false
    @Published var status: StatusMessage?

    func add(_ urls: [URL]) {
        files += urls.map(FileItem.init).filter { $0.pageCount != nil }
    }

    func run() {
        let inputs = files.map(\.url)
        guard !inputs.isEmpty else { return }
        var configured = OCROptions()
        configured.languages = language.codes
        configured.skipPagesWithText = skipPagesWithText
        let options = configured
        working = true
        progress = "Préparation…"

        runInBackground({ () -> ([URL], Int, Int) in
            var outputs: [URL] = []
            var pages = 0
            var chars = 0
            for (i, url) in inputs.enumerated() {
                let out = FileUtils.sibling(of: url, suffix: "_ocr")
                let r = try OCR.makeSearchable(url, options: options, to: out) { page, total in
                    DispatchQueue.main.async {
                        self.progress = "Fichier \(i + 1)/\(inputs.count) · page \(page)/\(total)"
                    }
                }
                pages += r.recognizedPages
                chars += r.characters
                outputs.append(out)
            }
            return (outputs, pages, chars)
        }) { [weak self] result in
            guard let self = self else { return }
            self.working = false
            self.progress = ""
            switch result {
            case .success(let (outs, pages, chars)):
                self.status = pages == 0
                    ? .info("Aucune page à traiter : ces PDF contiennent déjà du texte. Décoche l'option pour forcer l'OCR.")
                    : .ok("\(outs.count) fichier(s) « _ocr » créé(s) : \(pages) page(s) reconnue(s), \(chars) caractères.", files: outs)
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }
}

struct OCRToolView: View {
    @StateObject private var s = OCRStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .ocr)
            HStack(spacing: 24) {
                Picker("Langue", selection: $s.language) {
                    ForEach(OCRLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Toggle("Ignorer les pages qui ont déjà du texte", isOn: $s.skipPagesWithText)
                Spacer()
            }
            if s.files.isEmpty {
                DropZone(title: "Dépose des PDF scannés",
                         subtitle: "Le moteur de reconnaissance d'Apple ajoute une couche de texte invisible : l'aspect ne change pas, mais tu peux chercher (⌘F) et copier le texte. Tout se passe hors ligne.",
                         types: [.pdf]) { s.add($0) }
                Spacer()
            } else {
                List {
                    ForEach(s.files) { FileRow(item: $0) }
                        .onDelete { s.files.remove(atOffsets: $0) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .fileDrop(types: [.pdf]) { s.add($0) }
                HStack {
                    Button { s.add(Panels.open([.pdf], multiple: true)) } label: { Label("Ajouter", systemImage: "plus") }
                    Button("Tout vider") { s.files = [] }
                    Spacer()
                    if s.working {
                        ProgressView().controlSize(.small)
                        Text(s.progress).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button { s.run() } label: { Label("Lancer l'OCR", systemImage: "text.viewfinder") }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.working)
                }
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }
}

// MARK: - Mise en page

enum LayoutChoice: String, CaseIterable, Identifiable {
    case autoCrop = "Rogner automatiquement"
    case crop = "Rogner manuellement"
    case impose = "Plusieurs pages par feuille"

    var id: String { rawValue }
}

final class LayoutStore: ObservableObject {
    @Published var file: FileItem?
    @Published var mode: LayoutChoice = .autoCrop
    @Published var margins = Margins.all(10)
    @Published var keepMM = 5.0
    @Published var ranges = ""
    @Published var sheet: SheetLayout = .twoUp
    @Published var status: StatusMessage?
    @Published var working = false

    func choose(_ url: URL) {
        let item = FileItem(url)
        guard item.pageCount != nil else { status = .err("Impossible d'ouvrir « \(item.name) »."); return }
        file = item
        status = nil
    }

    private var suffix: String {
        switch mode {
        case .autoCrop, .crop: return "_rogné"
        case .impose:
            switch sheet {
            case .twoUp: return "_2-par-feuille"
            case .fourUp: return "_4-par-feuille"
            case .booklet: return "_livret"
            }
        }
    }

    func run() {
        guard let file = file else { return }
        let input = file.url
        guard let out = Panels.save(suggested: input.deletingPathExtension().lastPathComponent + suffix + ".pdf",
                                    type: .pdf, directory: input.deletingLastPathComponent()) else { return }
        let mode = self.mode, margins = self.margins, keep = keepMM, sheet = self.sheet
        let pages: String? = ranges.trimmingCharacters(in: .whitespaces).isEmpty ? nil : ranges
        working = true
        runInBackground({ () -> String in
            switch mode {
            case .autoCrop:
                let n = try Layout.autoCrop(input, keepMM: keep, pages: pages, to: out)
                return "\(n) page(s) rognée(s) automatiquement."
            case .crop:
                let n = try Layout.crop(input, margins: margins, pages: pages, to: out)
                return "\(n) page(s) rognée(s)."
            case .impose:
                let n = try Layout.impose(input, layout: sheet, to: out)
                return sheet == .booklet
                    ? "Livret de \(n) faces. Imprime en recto-verso, retournement sur le bord court, puis plie au milieu."
                    : "\(n) feuille(s) créée(s)."
            }
        }) { [weak self] result in
            guard let self = self else { return }
            self.working = false
            switch result {
            case .success(let message): self.status = .ok("\(out.lastPathComponent) : \(message)", files: [out])
            case .failure(let e): self.status = .err(e)
            }
        }
    }
}

struct LayoutToolView: View {
    @StateObject private var s = LayoutStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolHeader(tool: .layout)
            if let file = s.file {
                ChosenFileCard(item: file, types: [.pdf]) { s.choose($0) }
                Picker("Mode", selection: $s.mode) {
                    ForEach(LayoutChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 620)

                options
                    .frame(maxWidth: 520, alignment: .leading)

                HStack {
                    Spacer()
                    if s.working { ProgressView().controlSize(.small) }
                    Button { s.run() } label: { Label("Créer…", systemImage: "rectangle.split.2x1") }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.working)
                }
                Spacer()
            } else {
                DropZone(title: "Dépose un PDF",
                         subtitle: "Retirer les marges blanches des scans et des slides, ou préparer une impression économe : 2 ou 4 pages par feuille, ou livret plié.",
                         types: [.pdf], multiple: false) { urls in
                    if let u = urls.first { s.choose(u) }
                }
                Spacer()
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }

    @ViewBuilder
    private var options: some View {
        switch s.mode {
        case .autoCrop:
            Form {
                Stepper("Garder \(Int(s.keepMM)) mm autour du contenu", value: $s.keepMM, in: 0...30, step: 1)
                TextField("Pages", text: $s.ranges, prompt: Text("Toutes (ou ex. : 2-10)"))
                Text("Le recadrage ne supprime rien : il change seulement la zone visible, c'est réversible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        case .crop:
            Form {
                Stepper("Haut : \(Int(s.margins.top)) mm", value: $s.margins.top, in: 0...150, step: 1)
                Stepper("Bas : \(Int(s.margins.bottom)) mm", value: $s.margins.bottom, in: 0...150, step: 1)
                Stepper("Gauche : \(Int(s.margins.left)) mm", value: $s.margins.left, in: 0...150, step: 1)
                Stepper("Droite : \(Int(s.margins.right)) mm", value: $s.margins.right, in: 0...150, step: 1)
                TextField("Pages", text: $s.ranges, prompt: Text("Toutes (ou ex. : 2-10)"))
            }
            .formStyle(.grouped)
        case .impose:
            Form {
                Picker("Disposition", selection: $s.sheet) {
                    ForEach(SheetLayout.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(s.sheet == .booklet
                     ? "Pages remises dans l'ordre d'un livret A5 : imprime en recto-verso (bord court), plie, c'est lu dans l'ordre."
                     : "Feuilles A4, pages réduites et centrées.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Traitement par lots

final class BatchStore: ObservableObject {
    @Published var files: [FileItem] = []
    @Published var ocr = false
    @Published var numbering = false
    @Published var watermark = ""
    @Published var compress = true
    @Published var level: CompressionLevel = .balanced
    @Published var author = ""
    @Published var pattern = "{nom}"
    @Published var progress = ""
    @Published var results: [BatchItemResult] = []
    @Published var working = false
    @Published var status: StatusMessage?

    func add(_ urls: [URL]) {
        files += urls.map(FileItem.init).filter { $0.pageCount != nil }
    }

    var options: BatchOptions {
        var o = BatchOptions()
        o.ocr = ocr
        var stamp = StampOptions()
        stamp.numbering = numbering
        stamp.watermark = watermark
        o.stamp = stamp
        o.compression = compress ? level : nil
        if !author.trimmingCharacters(in: .whitespaces).isEmpty {
            var m = PDFMetadata()
            m.author = author
            o.metadata = m
        }
        o.renamePattern = pattern
        return o
    }

    var example: String {
        guard let first = files.first else { return "" }
        return Batch.outputName(for: first.url, pattern: pattern, index: 1, total: files.count)
    }

    func run() {
        let inputs = files.map(\.url)
        guard let first = inputs.first,
              let parent = Panels.folder(directory: first.deletingLastPathComponent(), prompt: "Enregistrer ici") else { return }
        let folder = FileUtils.unique(parent.appendingPathComponent("lot-traité"))
        let o = options
        working = true
        results = []
        runInBackground({ () -> [BatchItemResult] in
            Batch.run(inputs, options: o, into: folder) { i, n, name in
                DispatchQueue.main.async { self.progress = "\(i)/\(n) · \(name)" }
            }
        }) { [weak self] result in
            guard let self = self else { return }
            self.working = false
            self.progress = ""
            if case .success(let list) = result {
                self.results = list
                let ok = list.filter { $0.error == nil }.count
                let failed = list.count - ok
                self.status = failed == 0
                    ? .ok("\(ok) fichier(s) traité(s) dans « \(folder.lastPathComponent) ».", files: [folder])
                    : .err("\(ok) réussi(s), \(failed) échec(s) — détails dans la liste.")
            }
        }
    }
}

struct BatchToolView: View {
    @StateObject private var s = BatchStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .batch)
            HStack(alignment: .top, spacing: 16) {
                steps.frame(width: 380)
                VStack(alignment: .leading, spacing: 10) {
                    if s.files.isEmpty {
                        DropZone(title: "Dépose tout le lot de PDF",
                                 subtitle: "Par exemple les annales scannées : OCR, compression, auteur et renommage en une fois. Les originaux ne sont pas modifiés.",
                                 types: [.pdf]) { s.add($0) }
                    } else {
                        fileList
                    }
                }
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }

    private var steps: some View {
        Form {
            Section("Étapes (dans cet ordre)") {
                Toggle("1. OCR (rendre cherchable)", isOn: $s.ocr)
                Toggle("2. Numéroter les pages", isOn: $s.numbering)
                TextField("2. Filigrane", text: $s.watermark, prompt: Text("Aucun"))
                TextField("3. Auteur", text: $s.author, prompt: Text("Inchangé"))
                Toggle("4. Compresser", isOn: $s.compress)
                Picker("Niveau", selection: $s.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!s.compress)
            }
            Section("Nom des fichiers") {
                TextField("Modèle", text: $s.pattern)
                Text("{nom} nom d'origine · {n} numéro · {date} date du jour")
                    .font(.caption).foregroundStyle(.secondary)
                if !s.example.isEmpty {
                    Text("Ex. : \(s.example)").font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                if s.results.isEmpty {
                    ForEach(s.files) { FileRow(item: $0) }
                        .onDelete { s.files.remove(atOffsets: $0) }
                } else {
                    ForEach(Array(s.results.enumerated()), id: \.offset) { _, r in
                        HStack {
                            Image(systemName: r.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.error == nil ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.input.lastPathComponent)
                                Text(r.error ?? ("→ " + (r.output?.lastPathComponent ?? "")))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .fileDrop(types: [.pdf]) { s.add($0); s.results = [] }
            HStack {
                Button { s.add(Panels.open([.pdf], multiple: true)) } label: { Label("Ajouter", systemImage: "plus") }
                Button("Tout vider") { s.files = []; s.results = [] }
                Spacer()
                if s.working {
                    ProgressView().controlSize(.small)
                    Text(s.progress).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                Button { s.run() } label: { Label("Lancer (\(s.files.count))", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.working || s.files.isEmpty)
            }
        }
    }
}
