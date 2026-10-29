import SwiftUI
import AppKit
import PDFCore

// MARK: - Mes documents LaTeX

/// Les documents créés avec Toolbox (TD, TP, cours, tests…) + ceux du dossier Documents/Toolbox LaTeX
/// + les .tex ouverts récemment : on les rouvre pour les modifier, ou on les met à la corbeille.
final class LatexDocsStore: ObservableObject {
    static let shared = LatexDocsStore()
    private let key = "latexdocs.registry"

    struct Entry: Codable, Equatable {
        var path: String
        var kind: String          // td, tp, cours, test, rapport, autre, projet
        var title: String
        var matiere: String
        var created: Date
    }

    struct Doc: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let kind: String          // … ou « ouvert » pour un fichier qui ne vient pas de Toolbox
        let title: String
        let matiere: String
        let modified: Date
        let createdByToolbox: Bool

        var pdf: URL { url.deletingPathExtension().appendingPathExtension("pdf") }
        var hasPDF: Bool { FileManager.default.fileExists(atPath: pdf.path) }
        var docKind: LatexDocKind? { LatexDocKind(rawValue: kind) }
        var icon: String { docKind?.icon ?? (kind == "projet" ? "folder" : "doc.plaintext") }
        var color: Color { docKind?.color ?? (kind == "projet" ? .teal : .secondary) }
        var kindTitle: String { docKind?.title ?? (kind == "projet" ? "Projet" : "Ouvert") }
    }

    @Published private(set) var docs: [Doc] = []
    @Published var query = ""
    @Published var filter = "tous"
    @Published var showPopover = false

    private var registry: [Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    func register(_ url: URL, kind: String, title: String, matiere: String) {
        var list = registry.filter { $0.path != url.path }
        list.insert(Entry(path: url.path, kind: kind, title: title, matiere: matiere, created: Date()), at: 0)
        registry = Array(list.prefix(400))
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [Doc] = []
        func modified(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        // 1. créés avec Toolbox
        var kept: [Entry] = []
        for e in registry where fm.fileExists(atPath: e.path) {
            kept.append(e)
            let u = URL(fileURLWithPath: e.path)
            guard seen.insert(u.path).inserted else { continue }
            out.append(Doc(url: u, kind: e.kind, title: e.title.isEmpty ? Self.guessTitle(u) : e.title,
                           matiere: e.matiere, modified: modified(u), createdByToolbox: true))
        }
        if kept.count != registry.count { registry = kept }
        // 2. le dossier Documents/Toolbox LaTeX (documents d'avant ce registre)
        if let e = fm.enumerator(at: LatexModel.draftsFolder, includingPropertiesForKeys: nil,
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            while let u = e.nextObject() as? URL {
                if e.level > 3 { e.skipDescendants(); continue }
                guard u.pathExtension.lowercased() == "tex", seen.insert(u.path).inserted else { continue }
                out.append(Doc(url: u, kind: Self.guessKind(u), title: Self.guessTitle(u), matiere: "",
                               modified: modified(u), createdByToolbox: true))
            }
        }
        // 3. les .tex ouverts récemment
        for u in RecentFiles.list where u.pathExtension.lowercased() == "tex" && seen.insert(u.path).inserted {
            out.append(Doc(url: u, kind: "ouvert", title: Self.guessTitle(u), matiere: "",
                           modified: modified(u), createdByToolbox: false))
        }
        docs = out.sorted { $0.modified > $1.modified }
    }

    var visible: [Doc] {
        let q = LatexLibrary.fold(query.trimmingCharacters(in: .whitespaces))
        return docs.filter { d in
            (filter == "tous" || d.kind == filter || (filter == "ouvert" && !d.createdByToolbox))
                && (q.isEmpty || LatexLibrary.fold(d.title + " " + d.matiere + " " + d.url.path).contains(q))
        }
    }

    var kindsPresent: [String] {
        let order = LatexDocKind.allCases.map { $0.rawValue } + ["projet", "ouvert"]
        let present = Set(docs.map { $0.kind })
        return order.filter { present.contains($0) }
    }

    // MARK: Devinettes pour les documents non enregistrés

    static func guessTitle(_ u: URL) -> String {
        if let text = try? String(contentsOf: u, encoding: .utf8) {
            let head = String(text.prefix(6000))
            let ns = head as NSString
            for pattern in [#"\\titre\{([^}]+)\}"#, #"\\title\{([^}]+)\}"#, #"\{\\LARGE\\bfseries ([^}\\]+)"#] {
                if let re = try? NSRegularExpression(pattern: pattern),
                   let m = re.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
                    let t = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "--", with: "–")
                        .trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty, t != "Sans titre" { return t }
                }
            }
        }
        let base = u.deletingPathExtension().lastPathComponent
        return base == "main" ? u.deletingLastPathComponent().lastPathComponent : base
    }

    static func guessKind(_ u: URL) -> String {
        let name = u.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Test-") { return "test" }
        switch CourseKind.guess(fileName: name + " " + u.deletingLastPathComponent().lastPathComponent) {
        case .td: return "td"
        case .tp: return "tp"
        case .cours: return "cours"
        default: return "autre"
        }
    }

    // MARK: Suppression

    static let derivedExtensions: Set<String> = ["pdf", "aux", "log", "out", "toc", "fls", "fdb_latexmk", "synctex.gz", "synctex",
                                                  "bbl", "blg", "bcf", "run.xml", "nav", "snm", "vrb", "lof", "lot", "idx", "ilg", "ind", "xdv"]

    /// Ce que la suppression va mettre à la corbeille : le dossier entier s'il ne contient que ce document,
    /// sinon seulement le .tex et ses fichiers de compilation (le sujet PDF ou tes autres fichiers restent).
    static func targets(for doc: Doc) -> (items: [URL], wholeFolder: Bool) {
        let fm = FileManager.default
        let dir = doc.url.deletingLastPathComponent()
        let base = doc.url.deletingPathExtension().lastPathComponent
        let content = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        func belongs(_ u: URL) -> Bool {
            let name = u.lastPathComponent
            if name.hasPrefix(base + ".") { return true }
            if ["images", "references.bib", "_minted-" + base].contains(name) { return true }
            return false
        }
        let protectedDirs: [URL] = [LatexModel.draftsFolder, CoursesStore.shared.root].compactMap { $0 }
        let isProtected = protectedDirs.contains { $0.standardizedFileURL.path == dir.standardizedFileURL.path }
            || CoursesStore.shared.courses.contains { c in
                c.url.standardizedFileURL.path == dir.standardizedFileURL.path
                    || CourseKind.allCases.contains { c.folder(for: $0).standardizedFileURL.path == dir.standardizedFileURL.path }
            }
        if doc.createdByToolbox, !isProtected, !content.isEmpty, content.allSatisfy(belongs) {
            return ([dir], true)
        }
        let files = content.filter { u in
            let name = u.lastPathComponent
            guard name.hasPrefix(base + ".") else { return false }
            let ext = String(name.dropFirst(base.count + 1)).lowercased()
            return ext == "tex" || derivedExtensions.contains(ext)
        }
        return (files.isEmpty ? [doc.url] : files, false)
    }

    func delete(_ doc: Doc, model: LatexModel) {
        let t = Self.targets(for: doc)
        let what = t.wholeFolder
            ? "Le dossier « \(t.items[0].lastPathComponent) » et tout son contenu iront à la corbeille."
            : t.items.map { $0.lastPathComponent }.joined(separator: ", ") + " iront à la corbeille. Les autres fichiers du dossier ne sont pas touchés."
        guard confirmDestructive("Supprimer « \(doc.title) » ?", what + "\nTu peux le récupérer depuis la Corbeille.", button: "Mettre à la corbeille") else { return }
        if let open = model.texURL, open.path == doc.url.path || (t.wholeFolder && open.path.hasPrefix(t.items[0].path + "/")) {
            model.close()
        }
        let fm = FileManager.default
        var failed: Error?
        for u in t.items {
            do { try fm.trashItem(at: u, resultingItemURL: nil) } catch { failed = error }
        }
        // historique des versions de ce document
        let hist = LatexHistory.folder(for: doc.url)
        if fm.fileExists(atPath: hist.path) { try? fm.trashItem(at: hist, resultingItemURL: nil) }
        registry = registry.filter { $0.path != doc.url.path }
        var recents = UserDefaults.standard.stringArray(forKey: RecentFiles.key) ?? []
        recents.removeAll { $0 == doc.url.path }
        UserDefaults.standard.set(recents, forKey: RecentFiles.key)
        if let root = CoursesStore.shared.root, doc.url.path.hasPrefix(root.path) { CoursesStore.shared.scan() }
        refresh()
        if let e = failed {
            ToastCenter.shared.show("Suppression incomplète : \(e.localizedDescription)", seconds: 6)
        } else {
            ToastCenter.shared.show("🗑 « \(doc.title) » mis à la corbeille")
        }
    }
}

// MARK: - Liste

struct LatexDocsList: View {
    @ObservedObject var model: LatexModel
    @ObservedObject var s = LatexDocsStore.shared
    var compact = false

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mes documents LaTeX", systemImage: "doc.on.doc").font(.headline)
                Spacer()
                Button { s.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Actualiser")
            }
            TextField("Rechercher un document, une matière…", text: $s.query).textFieldStyle(.roundedBorder)
            if s.kindsPresent.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("tous", "Tous")
                        ForEach(s.kindsPresent, id: \.self) { k in
                            chip(k, LatexDocKind(rawValue: k)?.title ?? (k == "projet" ? "Projets" : "Ouverts"))
                        }
                    }
                }
            }
            let list = s.visible
            if list.isEmpty {
                Text(s.docs.isEmpty ? "Aucun document pour l'instant : crée-en un avec « Nouveau document… »." : "Rien trouvé.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) { ForEach(list) { row($0) } }
                }
            }
        }
        .onAppear { s.refresh() }
    }

    private func chip(_ key: String, _ title: String) -> some View {
        let on = s.filter == key
        return Button { s.filter = key } label: {
            Text(title).font(.caption.weight(on ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private func row(_ d: LatexDocsStore.Doc) -> some View {
        let isOpen = model.texURL?.path == d.url.path
        return HStack(spacing: 10) {
            Image(systemName: d.icon)
                .font(.title3).foregroundStyle(d.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if isOpen { Text("ouvert").font(.caption2).foregroundStyle(Color.green) }
                }
                Text([d.kindTitle, d.matiere, d.url.lastPathComponent, Self.relative.localizedString(for: d.modified, relativeTo: Date())]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { open(d) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Ouvrir pour modifier")
            if !compact {
                Button { NSWorkspace.shared.activateFileViewerSelecting([d.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Afficher dans le Finder")
                if d.hasPDF {
                    Button { NSWorkspace.shared.open(d.pdf) } label: { Image(systemName: "doc.richtext") }
                        .buttonStyle(.borderless).help("Ouvrir le PDF")
                }
            }
            Button { s.delete(d, model: model) } label: { Image(systemName: "trash").foregroundStyle(Color.red) }
                .buttonStyle(.borderless).help("Mettre à la corbeille")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(isOpen ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(d) }
        .contextMenu {
            Button("Ouvrir pour modifier") { open(d) }
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([d.url]) }
            if d.hasPDF { Button("Ouvrir le PDF") { NSWorkspace.shared.open(d.pdf) } }
            Button("Ouvrir dans un éditeur externe") { Editor.open(d.url, line: nil) }
            Divider()
            Button("Mettre à la corbeille…") { s.delete(d, model: model) }
        }
    }

    private func open(_ d: LatexDocsStore.Doc) {
        s.showPopover = false
        if model.texURL?.path != d.url.path { model.open(d.url); model.compile() }
    }
}
