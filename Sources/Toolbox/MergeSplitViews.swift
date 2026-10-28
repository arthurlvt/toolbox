import SwiftUI
import PDFCore

// Note : pas de @State ici. Sur les SDK récents, @State est une macro qui n'est
// fournie qu'avec Xcode complet ; avec les Command Line Tools seuls, on passe
// donc par des ObservableObject + @StateObject (simples property wrappers).

// MARK: - Fusionner

final class MergeStore: ObservableObject {
    @Published var files: [FileItem] = []
    @Published var selection = Set<FileItem.ID>()
    @Published var status: StatusMessage?
    @Published var working = false

    var totalPages: Int { files.compactMap(\.pageCount).reduce(0, +) }

    func add(_ urls: [URL]) {
        let items = urls.map(FileItem.init)
        let unreadable = items.filter { $0.pageCount == nil }
        files += items.filter { $0.pageCount != nil }
        if !unreadable.isEmpty {
            status = .err("Fichier(s) illisible(s) ignoré(s) : \(unreadable.map(\.name).joined(separator: ", "))")
        }
    }

    func removeSelected() {
        files.removeAll { selection.contains($0.id) }
        selection = []
    }

    func sortByName() {
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func merge() {
        guard let first = files.first,
              let output = Panels.save(suggested: "fusion.pdf", type: .pdf,
                                       directory: first.url.deletingLastPathComponent()) else { return }
        let inputs = files.map(\.url)
        working = true
        runInBackground({ try PDFOps.merge(inputs, into: output) }) { [weak self] result in
            guard let self = self else { return }
            self.working = false
            switch result {
            case .success(let pages): self.status = .ok("\(output.lastPathComponent) créé (\(pages) pages).", files: [output])
            case .failure(let e): self.status = .err(e)
            }
        }
    }
}

struct MergeToolView: View {
    @ObservedObject var s: MergeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .merge)
            if s.files.isEmpty {
                DropZone(title: "Dépose les PDF à fusionner",
                         subtitle: "Tu pourras ensuite les remettre dans l'ordre par glisser-déposer.",
                         types: [.pdf]) { s.add($0) }
                Spacer()
            } else {
                List(selection: $s.selection) {
                    ForEach(s.files) { FileRow(item: $0) }
                        .onMove { s.files.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { s.files.remove(atOffsets: $0) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .fileDrop(types: [.pdf]) { s.add($0) }

                HStack {
                    Button { s.add(Panels.open([.pdf], multiple: true)) } label: { Label("Ajouter", systemImage: "plus") }
                    Button { s.removeSelected() } label: { Label("Retirer", systemImage: "minus") }
                        .disabled(s.selection.isEmpty)
                    Button { s.sortByName() } label: { Label("Trier par nom", systemImage: "arrow.up.arrow.down") }
                    Button("Tout vider") { s.files = []; s.selection = [] }
                    Spacer()
                    Text("\(s.files.count) fichiers · \(s.totalPages) pages").foregroundStyle(.secondary)
                    if s.working { ProgressView().controlSize(.small) }
                    Button { s.merge() } label: { Label("Fusionner…", systemImage: "doc.on.doc.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.files.count < 2 || s.working)
                }
                Text("Astuce : glisse les lignes pour changer l'ordre.").font(.caption).foregroundStyle(.secondary)
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }
}

// MARK: - Diviser

enum SplitChoice: String, CaseIterable, Identifiable {
    case each = "Chaque page"
    case every = "Toutes les N pages"
    case ranges = "Plages personnalisées"
    case extract = "Extraire des pages"
    var id: String { rawValue }
}

final class SplitStore: ObservableObject {
    @Published var file: FileItem?
    @Published var mode: SplitChoice = .each
    @Published var chunk = 2
    @Published var ranges = ""
    @Published var status: StatusMessage?
    @Published var working = false

    var pageCount: Int { file?.pageCount ?? 0 }

    var needsRanges: Bool {
        (mode == .ranges || mode == .extract) && ranges.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var preview: String {
        let n = pageCount
        guard n > 0 else { return "" }
        switch mode {
        case .each:
            return "→ \(n) fichiers"
        case .every:
            return "→ \(Int((Double(n) / Double(max(1, chunk))).rounded(.up))) fichiers"
        case .ranges:
            if let g = try? PageRanges.parse(ranges, pageCount: n) { return "→ \(g.count) fichiers" }
            return ranges.isEmpty ? "" : "Plage invalide (le document a \(n) pages)"
        case .extract:
            if let i = try? PageRanges.indices(ranges, pageCount: n) { return "→ 1 fichier de \(i.count) pages" }
            return ranges.isEmpty ? "" : "Plage invalide (le document a \(n) pages)"
        }
    }

    func choose(_ url: URL) {
        let item = FileItem(url)
        if item.pageCount == nil {
            status = .err("Impossible d'ouvrir « \(item.name) ».")
        } else {
            file = item
            status = nil
        }
    }

    func run() {
        guard let file = file else { return }
        let input = file.url
        let base = input.deletingPathExtension().lastPathComponent

        if mode == .extract {
            guard let out = Panels.save(suggested: "\(base)_extrait.pdf", type: .pdf,
                                        directory: input.deletingLastPathComponent()) else { return }
            let text = ranges
            working = true
            runInBackground({ try PDFOps.extract(input, pages: text, to: out) }) { [weak self] result in
                guard let self = self else { return }
                self.working = false
                switch result {
                case .success(let n): self.status = .ok("\(out.lastPathComponent) créé (\(n) pages).", files: [out])
                case .failure(let e): self.status = .err(e)
                }
            }
            return
        }

        guard let parent = Panels.folder(directory: input.deletingLastPathComponent(),
                                         prompt: "Diviser ici") else { return }
        let folder = FileUtils.unique(parent.appendingPathComponent("\(base)_divisé"))
        let splitMode: PDFOps.SplitMode
        switch mode {
        case .every: splitMode = .every(chunk)
        case .ranges: splitMode = .ranges(ranges)
        default: splitMode = .everyPage
        }
        working = true
        runInBackground({ try PDFOps.split(input, mode: splitMode, into: folder) }) { [weak self] result in
            guard let self = self else { return }
            self.working = false
            switch result {
            case .success(let urls):
                self.status = .ok("\(urls.count) fichiers créés dans « \(folder.lastPathComponent) ».", files: [folder])
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }
}

struct SplitToolView: View {
    @StateObject private var s = SplitStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolHeader(tool: .split)
            if let file = s.file {
                ChosenFileCard(item: file, types: [.pdf]) { s.choose($0) }

                Picker("Mode", selection: $s.mode) {
                    ForEach(SplitChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                options

                HStack {
                    Text(s.preview).foregroundStyle(.secondary)
                    Spacer()
                    if s.working { ProgressView().controlSize(.small) }
                    Button { s.run() } label: {
                        Label(s.mode == .extract ? "Extraire…" : "Diviser…", systemImage: "scissors")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.working || s.needsRanges)
                }
                Spacer()
            } else {
                DropZone(title: "Dépose le PDF à diviser",
                         subtitle: "Une page par fichier, par paquets de N pages ou selon tes propres plages.",
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
        case .each:
            Text("Chaque page devient un PDF séparé.").foregroundStyle(.secondary)
        case .every:
            Stepper("Un fichier toutes les \(s.chunk) pages", value: $s.chunk, in: 1...max(1, s.pageCount))
                .frame(maxWidth: 320, alignment: .leading)
        case .ranges, .extract:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Ex. : 1-3, 5, 8-", text: $s.ranges)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Text(s.mode == .ranges
                     ? "Chaque plage devient un fichier. « 8- » = de la page 8 à la fin."
                     : "Les pages indiquées sont réunies dans un seul PDF, dans l'ordre donné (« 3, 1, 2 » réordonne).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
