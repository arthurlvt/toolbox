import SwiftUI
import UniformTypeIdentifiers
import PDFCore

// MARK: - Compresser

final class CompressStore: ObservableObject {
    @Published var files: [FileItem] = []
    @Published var level: CompressionLevel = .balanced
    @Published var results: [UUID: Result<CompressionResult, Error>] = [:]
    @Published var working = false
    @Published var status: StatusMessage?

    let ghostscript = Compressor.ghostscriptPath

    func add(_ urls: [URL]) {
        files += urls.map(FileItem.init).filter { $0.pageCount != nil }
    }

    func clear() {
        files = []
        results = [:]
    }

    func resultText(_ f: FileItem) -> String? {
        switch results[f.id] {
        case .some(.success(let r)): return r.summary
        case .some(.failure): return "échec"
        case .none: return working ? "…" : nil
        }
    }

    func resultColor(_ f: FileItem) -> Color {
        switch results[f.id] {
        case .some(.success(let r)): return r.keptOriginal ? .secondary : .green
        case .some(.failure): return .red
        case .none: return .secondary
        }
    }

    func compressAll() {
        let todo = files
        let level = self.level
        results = [:]
        working = true
        status = .info("Compression en cours…")
        runInBackground({ () -> [(UUID, Result<CompressionResult, Error>)] in
            todo.map { (f: FileItem) -> (UUID, Result<CompressionResult, Error>) in
                let out = FileUtils.sibling(of: f.url, suffix: "_compressé")
                return (f.id, Result(catching: { try Compressor.compress(f.url, level: level, to: out) }))
            }
        }) { [weak self] outcome in
            guard let self = self else { return }
            self.working = false
            guard case .success(let list) = outcome else { return }
            for (id, r) in list { self.results[id] = r }
            let ok = list.compactMap { try? $0.1.get() }
            let before = ok.map(\.before).reduce(0, +)
            let after = ok.map(\.after).reduce(0, +)
            let failures = list.count - ok.count
            var text = "\(ok.count) fichier(s) : \(FileUtils.formatBytes(before)) → \(FileUtils.formatBytes(after))"
            if failures > 0 { text += " · \(failures) échec(s)" }
            self.status = .ok(text, files: ok.map(\.output))
        }
    }
}

struct CompressToolView: View {
    @StateObject private var s = CompressStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .compress)

            HStack(alignment: .top, spacing: 24) {
                Picker("Niveau", selection: $s.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .fixedSize()
                engineInfo
                Spacer()
            }

            if s.files.isEmpty {
                DropZone(title: "Dépose les PDF à compresser",
                         subtitle: "Les originaux ne sont jamais modifiés : un fichier « _compressé » est créé à côté.",
                         types: [.pdf]) { s.add($0) }
                Spacer()
            } else {
                List {
                    ForEach(s.files) { f in
                        FileRow(item: f, trailing: s.resultText(f), trailingColor: s.resultColor(f))
                    }
                    .onDelete { s.files.remove(atOffsets: $0) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .fileDrop(types: [.pdf]) { s.add($0) }

                HStack {
                    Button { s.add(Panels.open([.pdf], multiple: true)) } label: { Label("Ajouter", systemImage: "plus") }
                    Button("Tout vider") { s.clear() }
                    Spacer()
                    if s.working { ProgressView().controlSize(.small) }
                    Button { s.compressAll() } label: {
                        Label("Compresser", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.working)
                }
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }

    @ViewBuilder
    private var engineInfo: some View {
        if s.ghostscript != nil {
            Label("Ghostscript détecté : compression optimale", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.green)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Ghostscript non installé : compression basique (PDFKit)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.orange)
                Text("Pour de bien meilleurs résultats : brew install ghostscript")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Convertir

enum ConvertChoice: String, CaseIterable, Identifiable {
    case imagesToPDF = "Images → PDF"
    case pdfToImages = "PDF → Images"
    case pdfToText = "PDF → Texte"
    case rag = "Export RAG"
    var id: String { rawValue }
}

final class ConvertStore: ObservableObject {
    @Published var mode: ConvertChoice = .imagesToPDF
    @Published var status: StatusMessage?
    @Published var working = false

    // Images → PDF
    @Published var images: [FileItem] = []
    @Published var imageSelection = Set<FileItem.ID>()
    @Published var pageSize: PageSize = .a4

    // PDF → images
    @Published var pdf: FileItem?
    @Published var format: ImageFormat = .png
    @Published var dpi = 150
    @Published var ranges = ""

    // PDF → texte
    @Published var textFiles: [FileItem] = []

    // Export RAG
    @Published var ragFiles: [FileItem] = []
    @Published var ragFormat: RAGFormat = .markdown

    private func finish<T>(_ result: Result<T, Error>, _ success: (T) -> StatusMessage) {
        working = false
        switch result {
        case .success(let v): status = success(v)
        case .failure(let e): status = .err(e)
        }
    }

    func addImages(_ urls: [URL]) { images += urls.map(FileItem.init) }

    func removeSelectedImages() {
        images.removeAll { imageSelection.contains($0.id) }
        imageSelection = []
    }

    func sortImages() {
        images.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func imagesToPDF() {
        guard let first = images.first,
              let out = Panels.save(suggested: "images.pdf", type: .pdf,
                                    directory: first.url.deletingLastPathComponent()) else { return }
        let urls = images.map(\.url)
        let size = pageSize
        working = true
        runInBackground({ try Converter.imagesToPDF(urls, pageSize: size, to: out) }) { [weak self] result in
            self?.finish(result) { .ok("\(out.lastPathComponent) créé (\($0) pages).", files: [out]) }
        }
    }

    func pdfToImages() {
        guard let file = pdf else { return }
        let input = file.url
        guard let parent = Panels.folder(directory: input.deletingLastPathComponent(),
                                         prompt: "Exporter ici") else { return }
        let folder = FileUtils.unique(parent.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_images"))
        let format = self.format
        let dpi = Double(self.dpi)
        let text = ranges
        working = true
        runInBackground({ try Converter.pdfToImages(input, format: format, dpi: dpi, pages: text, into: folder) }) { [weak self] result in
            self?.finish(result) { .ok("\($0.count) image(s) exportée(s) dans « \(folder.lastPathComponent) ».", files: [folder]) }
        }
    }

    func exportRAG() {
        let inputs = ragFiles.map(\.url)
        let format = ragFormat
        working = true
        runInBackground({ () -> [URL] in
            try inputs.map { (url: URL) -> URL in
                let out = FileUtils.sibling(of: url, suffix: "", ext: format.fileExtension)
                try RAGExport.export(url, format: format, to: out)
                return out
            }
        }) { [weak self] result in
            self?.finish(result) { .ok("\($0.count) fichier(s) \(format.fileExtension) créé(s), une entrée par page avec source et numéro.", files: $0) }
        }
    }

    func extractText() {
        let inputs = textFiles.map(\.url)
        working = true
        runInBackground({ () -> [URL] in
            try inputs.map { (url: URL) -> URL in
                let out = FileUtils.sibling(of: url, suffix: "", ext: "txt")
                try Converter.pdfToText(url, to: out)
                return out
            }
        }) { [weak self] result in
            self?.finish(result) { .ok("\($0.count) fichier(s) texte créé(s).", files: $0) }
        }
    }
}

struct ConvertToolView: View {
    @ObservedObject var s: ConvertStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .convert)
            Picker("Conversion", selection: $s.mode) {
                ForEach(ConvertChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)

            switch s.mode {
            case .imagesToPDF: imagesPane
            case .pdfToImages: pdfToImagesPane
            case .pdfToText: textPane
            case .rag: ragPane
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }

    // MARK: Images → PDF

    @ViewBuilder
    private var imagesPane: some View {
        if s.images.isEmpty {
            DropZone(title: "Dépose tes images (PNG, JPEG, HEIC…)",
                     subtitle: "Chaque image devient une page, dans l'ordre de la liste.",
                     types: [.image]) { s.addImages($0) }
            Spacer()
        } else {
            List(selection: $s.imageSelection) {
                ForEach(s.images) { FileRow(item: $0) }
                    .onMove { s.images.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { s.images.remove(atOffsets: $0) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .fileDrop(types: [.image]) { s.addImages($0) }

            HStack {
                Button { s.addImages(Panels.open([.image], multiple: true)) } label: {
                    Label("Ajouter", systemImage: "plus")
                }
                Button { s.removeSelectedImages() } label: { Label("Retirer", systemImage: "minus") }
                    .disabled(s.imageSelection.isEmpty)
                Button { s.sortImages() } label: { Label("Trier par nom", systemImage: "arrow.up.arrow.down") }
                Spacer()
                Picker("Pages", selection: $s.pageSize) {
                    ForEach(PageSize.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                if s.working { ProgressView().controlSize(.small) }
                Button { s.imagesToPDF() } label: { Label("Créer le PDF…", systemImage: "doc.badge.plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.working)
            }
        }
    }

    // MARK: PDF → images

    @ViewBuilder
    private var pdfToImagesPane: some View {
        if let pdf = s.pdf {
            ChosenFileCard(item: pdf, types: [.pdf]) { s.pdf = FileItem($0) }
            Form {
                Picker("Format", selection: $s.format) {
                    ForEach(ImageFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Résolution", selection: $s.dpi) {
                    Text("72 dpi (écran)").tag(72)
                    Text("150 dpi").tag(150)
                    Text("300 dpi (impression)").tag(300)
                    Text("600 dpi").tag(600)
                }
                TextField("Pages (vide = toutes)", text: $s.ranges, prompt: Text("Ex. : 1-3, 7"))
            }
            .frame(maxWidth: 460)
            HStack {
                Spacer()
                if s.working { ProgressView().controlSize(.small) }
                Button { s.pdfToImages() } label: { Label("Exporter les images…", systemImage: "photo.on.rectangle") }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.working)
            }
            Spacer()
        } else {
            DropZone(title: "Dépose un PDF à convertir en images",
                     types: [.pdf], multiple: false) { urls in
                if let u = urls.first { s.pdf = FileItem(u) }
            }
            Spacer()
        }
    }

    // MARK: Export RAG

    @ViewBuilder
    private var ragPane: some View {
        if s.ragFiles.isEmpty {
            DropZone(title: "Dépose les PDF à préparer pour ton RAG",
                     subtitle: "Texte nettoyé (césures recollées, espaces normalisés), une entrée par page avec le fichier source et le numéro de page, pour citer les sources.",
                     types: [.pdf]) { s.ragFiles += $0.map(FileItem.init) }
            Spacer()
        } else {
            List {
                ForEach(s.ragFiles) { FileRow(item: $0) }
                    .onDelete { s.ragFiles.remove(atOffsets: $0) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .fileDrop(types: [.pdf]) { s.ragFiles += $0.map(FileItem.init) }
            HStack {
                Button("Tout vider") { s.ragFiles = [] }
                Spacer()
                Picker("Format", selection: $s.ragFormat) {
                    ForEach(RAGFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                if s.working { ProgressView().controlSize(.small) }
                Button { s.exportRAG() } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.working)
            }
            Text("Astuce : passe d'abord les scans dans l'outil OCR, sinon ils n'ont pas de texte.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: PDF → texte

    @ViewBuilder
    private var textPane: some View {
        if s.textFiles.isEmpty {
            DropZone(title: "Dépose les PDF dont tu veux le texte",
                     subtitle: "Un fichier .txt est créé à côté de chaque PDF. (Les PDF scannés sans couche texte resteront vides.)",
                     types: [.pdf]) { s.textFiles += $0.map(FileItem.init) }
            Spacer()
        } else {
            List {
                ForEach(s.textFiles) { FileRow(item: $0) }
                    .onDelete { s.textFiles.remove(atOffsets: $0) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .fileDrop(types: [.pdf]) { s.textFiles += $0.map(FileItem.init) }
            HStack {
                Button("Tout vider") { s.textFiles = [] }
                Spacer()
                if s.working { ProgressView().controlSize(.small) }
                Button { s.extractText() } label: { Label("Extraire le texte", systemImage: "text.alignleft") }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.working)
            }
        }
    }
}
