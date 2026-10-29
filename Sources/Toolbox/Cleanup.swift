import SwiftUI
import AppKit
import CryptoKit
import PDFCore

// MARK: - Nettoyer le Mac : ce qui prend de la place, et ce qu'on peut enlever sans risque

enum CleanKind: String, CaseIterable, Identifiable {
    case caches, devCaches, buildFolders, latexAux, trash, downloads, bigFiles, duplicates, ollama
    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: return "Caches des apps"
        case .devCaches: return "Caches de développement"
        case .buildFolders: return "Dossiers de compilation"
        case .latexAux: return "Fichiers de compilation LaTeX"
        case .trash: return "Corbeille"
        case .downloads: return "Vieux téléchargements"
        case .bigFiles: return "Gros fichiers"
        case .duplicates: return "PDF en double"
        case .ollama: return "Modèles IA (Ollama)"
        }
    }
    var detail: String {
        switch self {
        case .caches: return "Recréés automatiquement par les apps quand elles en ont besoin"
        case .devCaches: return "Xcode DerivedData, Homebrew, npm, pip, Swift : se retéléchargent ou se recompilent"
        case .buildFolders: return "node_modules, .build, build, __pycache__, venv dans tes projets : se recréent"
        case .latexAux: return ".aux, .log, .synctex.gz… à côté de tes .tex (le PDF est gardé)"
        case .trash: return "Tant qu'elle n'est pas vidée, rien n'est vraiment libéré"
        case .downloads: return "Pas ouverts depuis plus de 60 jours : à vérifier"
        case .bigFiles: return "Plus de 300 Mo dans ton dossier personnel : à vérifier"
        case .duplicates: return "Même contenu exactement : on garde le plus ancien"
        case .ollama: return "Chaque modèle pèse plusieurs Go"
        }
    }
    var icon: String {
        switch self {
        case .caches: return "internaldrive"
        case .devCaches: return "hammer"
        case .buildFolders: return "shippingbox"
        case .latexAux: return "function"
        case .trash: return "trash"
        case .downloads: return "arrow.down.circle"
        case .bigFiles: return "externaldrive.badge.exclamationmark"
        case .duplicates: return "doc.on.doc"
        case .ollama: return "cpu"
        }
    }
    /// Sans risque : régénéré tout seul → supprimé directement (sinon : corbeille).
    var regenerable: Bool { [.caches, .devCaches, .buildFolders, .latexAux].contains(self) }
    /// Coché d'office après l'analyse
    var preselected: Bool { regenerable }
}

struct CleanItem: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    let size: Int64
    var note: String = ""
}

struct CleanGroup: Identifiable {
    var id: String { kind.rawValue }
    let kind: CleanKind
    var items: [CleanItem]
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum DiskScanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let minItem: Int64 = 1_000_000            // en dessous d'1 Mo : pas la peine d'afficher

    static func size(_ u: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true {
            let r = try? u.resourceValues(forKeys: keys)
            return Int64(r?.totalFileAllocatedSize ?? r?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in e {
                guard let r = try? f.resourceValues(forKeys: keys), r.isRegularFile == true else { continue }
                total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func children(_ u: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func sized(_ urls: [URL], note: (URL) -> String = { _ in "" }) -> [CleanItem] {
        urls.compactMap { u in
            let s = size(u)
            return s >= minItem ? CleanItem(url: u, size: s, note: note(u)) : nil
        }.sorted { $0.size > $1.size }
    }

    // MARK: Catégories

    static func caches() -> [CleanItem] {
        let dir = home.appendingPathComponent("Library/Caches")
        // les caches de dev ont leur propre catégorie ; ceux de Toolbox (compilation) aussi
        let dev: Set<String> = ["Homebrew", "pip", "org.swift.swiftpm", "com.apple.dt.Xcode", "fr.arthur.toolbox", "CloudKit", "com.apple.bird"]
        return sized(children(dir).filter { !dev.contains($0.lastPathComponent) })
    }

    static func devCaches() -> [CleanItem] {
        let paths = [
            "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/Archives",
            "Library/Developer/CoreSimulator/Caches", "Library/Caches/Homebrew", "Library/Caches/pip", "Library/Caches/org.swift.swiftpm",
            "Library/Caches/com.apple.dt.Xcode", ".npm/_cacache", ".cache/huggingface", ".gradle/caches", ".m2/repository",
            ".cargo/registry", "Library/Caches/fr.arthur.toolbox",
        ]
        return sized(paths.map { home.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }) { u in
            u.lastPathComponent == "fr.arthur.toolbox" ? "compilation de Toolbox (refaite au prochain ./build.sh)" : ""
        }
    }

    /// Dossiers à parcourir pour les projets et les fichiers de l'utilisateur.
    static var roots: [URL] {
        let skip: Set<String> = ["Library", "Applications", "Music", "Movies", "Pictures", "Public", ".Trash"]
        var list = children(home).filter { u in
            let n = u.lastPathComponent
            guard !skip.contains(n), !n.hasPrefix(".") else { return false }
            return (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        if let r = CoursesStore.shared.root, !list.contains(where: { r.path.hasPrefix($0.path + "/") || r == $0 }) { list.append(r) }
        return list
    }

    static let buildNames: Set<String> = ["node_modules", ".build", "__pycache__", ".venv", "venv", ".pytest_cache", "cmake-build-debug",
                                          "cmake-build-release", "DerivedData", ".gradle", "target", ".next", ".nuxt", "dist-newstyle"]
    static let latexExt: Set<String> = ["aux", "log", "fls", "fdb_latexmk", "synctex.gz", "out", "toc", "bbl", "blg", "bcf", "nav", "snm", "lof", "lot", "xdv"]

    /// Un seul parcours pour : dossiers de compilation, fichiers LaTeX auxiliaires, gros fichiers et PDF.
    static func walk(_ roots: [URL], _ progress: (String) -> Void) -> (builds: [URL], aux: [CleanItem], big: [CleanItem], pdfs: [(URL, Int64)]) {
        var builds: [URL] = [], aux: [CleanItem] = [], big: [CleanItem] = [], pdfs: [(URL, Int64)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        for root in roots {
            progress(root.lastPathComponent)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                if e.level > 12 { e.skipDescendants(); continue }
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
                let name = u.lastPathComponent
                if v.isDirectory == true {
                    if name == ".git" { e.skipDescendants(); continue }
                    if buildNames.contains(name) || (name == "build" && FileManager.default.fileExists(atPath: u.deletingLastPathComponent().appendingPathComponent("CMakeLists.txt").path)) {
                        builds.append(u)
                        e.skipDescendants()
                    }
                    continue
                }
                let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                let lower = name.lowercased()
                if lower.hasSuffix(".synctex.gz") || latexExt.contains(u.pathExtension.lowercased()) {
                    let base = lower.hasSuffix(".synctex.gz") ? String(name.dropLast(11)) : u.deletingPathExtension().lastPathComponent
                    if FileManager.default.fileExists(atPath: u.deletingLastPathComponent().appendingPathComponent(base + ".tex").path) {
                        aux.append(CleanItem(url: u, size: s))
                        continue
                    }
                }
                if s >= 300_000_000 { big.append(CleanItem(url: u, size: s)) }
                if u.pathExtension.lowercased() == "pdf", s > 0 { pdfs.append((u, s)) }
            }
        }
        return (builds, aux, big.sorted { $0.size > $1.size }, pdfs)
    }

    static func downloads() -> [CleanItem] {
        let dir = home.appendingPathComponent("Downloads")
        let limit = Date().addingTimeInterval(-60 * 86400)
        return sized(children(dir).filter { u in
            guard !u.lastPathComponent.hasPrefix(".") else { return false }
            let v = try? u.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            let last = max(v?.contentAccessDate ?? .distantPast, v?.contentModificationDate ?? .distantPast)
            return last < limit
        }) { u in
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return "modifié " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
        }
    }

    static func trash() -> [CleanItem] {
        let s = size(home.appendingPathComponent(".Trash"))
        return s > 0 ? [CleanItem(url: home.appendingPathComponent(".Trash"), size: s, note: "vidée définitivement")] : []
    }

    /// PDF de même taille, puis même empreinte : on propose tous sauf le plus ancien.
    static func duplicates(_ pdfs: [(URL, Int64)]) -> [CleanItem] {
        var bySize: [Int64: [URL]] = [:]
        for (u, s) in pdfs where s >= 100_000 { bySize[s, default: []].append(u) }
        var out: [CleanItem] = []
        for (s, list) in bySize where list.count > 1 {
            var byHash: [String: [URL]] = [:]
            for u in list { if let h = try? Self.hash(u) { byHash[h, default: []].append(u) } }
            for (_, same) in byHash where same.count > 1 {
                let sorted = same.sorted {
                    ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture)
                        < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture)
                }
                for u in sorted.dropFirst() { out.append(CleanItem(url: u, size: s, note: "copie de " + sorted[0].lastPathComponent)) }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func ollamaModels() -> [CleanItem] {
        guard let cli = OllamaService.cliPath, let r = try? Shell.run(cli, ["list"]), r.status == 0 else { return [] }
        // NAME  ID  SIZE  MODIFIED   (ex. « qwen2.5-coder:7b  abc123  4.7 GB  3 weeks ago »)
        return r.text.components(separatedBy: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 4, let n = Double(cols[2].replacingOccurrences(of: ",", with: ".")) else { return nil }
            let mult: Double = cols[3].uppercased().hasPrefix("GB") ? 1e9 : (cols[3].uppercased().hasPrefix("MB") ? 1e6 : 1e3)
            return CleanItem(url: URL(string: "ollama:" + cols[0]) ?? URL(fileURLWithPath: "/"), size: Int64(n * mult),
                             note: "ollama rm " + cols[0])
        }
    }
}

// MARK: - État

final class CleanupStore: ObservableObject {
    static let shared = CleanupStore()

    @Published private(set) var groups: [CleanGroup] = []
    @Published var selected: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var progress = ""
    @Published private(set) var cleaning = false
    @Published private(set) var total: Int64 = 0
    @Published private(set) var free: Int64 = 0
    @Published var status: StatusMessage?
    @Published private(set) var scannedAt: Date?

    init() { refreshDisk() }

    func refreshDisk() {
        let v = try? DiskScanner.home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        total = Int64(v?.volumeTotalCapacity ?? 0)
        free = v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    var selectedSize: Int64 {
        groups.flatMap { $0.items }.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        status = nil
        progress = "Caches…"
        let report: (String) -> Void = { p in DispatchQueue.main.async { self.progress = p } }
        let roots = DiskScanner.roots
        runInBackground({ () -> [CleanGroup] in
            var g: [CleanGroup] = []
            report("Caches des apps…")
            g.append(CleanGroup(kind: .caches, items: DiskScanner.caches()))
            report("Caches de développement…")
            g.append(CleanGroup(kind: .devCaches, items: DiskScanner.devCaches()))
            let w = DiskScanner.walk(roots) { report("Analyse de « \($0) »…") }
            g.append(CleanGroup(kind: .buildFolders, items: DiskScanner.sized(w.builds) { u in
                "dans " + u.deletingLastPathComponent().lastPathComponent }))
            g.append(CleanGroup(kind: .latexAux, items: w.aux.sorted { $0.size > $1.size }))
            report("Corbeille et téléchargements…")
            g.append(CleanGroup(kind: .trash, items: DiskScanner.trash()))
            g.append(CleanGroup(kind: .downloads, items: DiskScanner.downloads()))
            g.append(CleanGroup(kind: .bigFiles, items: w.big))
            report("Recherche des doublons…")
            g.append(CleanGroup(kind: .duplicates, items: DiskScanner.duplicates(w.pdfs)))
            report("Modèles IA…")
            g.append(CleanGroup(kind: .ollama, items: DiskScanner.ollamaModels()))
            return g.filter { !$0.items.isEmpty }
        }) { [weak self] r in
            guard let self = self else { return }
            self.scanning = false
            self.progress = ""
            self.refreshDisk()
            switch r {
            case .success(let g):
                self.groups = g.sorted { $0.total > $1.total }
                self.selected = Set(g.filter { $0.kind.preselected }.flatMap { $0.items.map { $0.id } })
                self.scannedAt = Date()
                let all = g.reduce(Int64(0)) { $0 + $1.total }
                self.status = .info("\(FileUtils.formatBytes(all)) trouvés, dont \(FileUtils.formatBytes(self.selectedSize)) sans risque (déjà cochés).")
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    func toggleGroup(_ g: CleanGroup) {
        let ids = Set(g.items.map { $0.id })
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    func clean() {
        let chosen = groups.flatMap { g in g.items.filter { selected.contains($0.id) }.map { (g.kind, $0) } }
        guard !chosen.isEmpty else { return }
        let toTrash = chosen.filter { !$0.0.regenerable && $0.0 != .trash && $0.0 != .ollama }.count
        let emptying = chosen.contains { $0.0 == .trash }
        var text = "\(chosen.count) élément\(chosen.count > 1 ? "s" : "") · \(FileUtils.formatBytes(selectedSize)).\n"
        text += "• Caches et fichiers de compilation : supprimés (ils se recréent tout seuls).\n"
        if toTrash > 0 { text += "• Tes fichiers (téléchargements, gros fichiers, doublons) : mis à la corbeille.\n" }
        if emptying { text += "• La corbeille sera vidée définitivement.\n" }
        if chosen.contains(where: { $0.0 == .ollama }) { text += "• Les modèles IA cochés seront désinstallés (ollama rm).\n" }
        guard confirmDestructive("Nettoyer \(FileUtils.formatBytes(selectedSize)) ?", text, button: "Nettoyer") else { return }
        let before = free
        cleaning = true
        status = .info("Nettoyage…")
        runInBackground({ () -> [String] in
            var errors: [String] = []
            let fm = FileManager.default
            for (kind, item) in chosen {
                do {
                    switch kind {
                    case .trash:
                        let trash = DiskScanner.home.appendingPathComponent(".Trash")
                        for u in DiskScanner.children(trash) { try? fm.removeItem(at: u) }
                    case .ollama:
                        let name = item.url.absoluteString.replacingOccurrences(of: "ollama:", with: "")
                        if let cli = OllamaService.cliPath { _ = try Shell.run(cli, ["rm", name]) }
                    case .caches, .devCaches:
                        // on vide le contenu (le dossier lui-même peut appartenir à une app ouverte)
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: item.url.path, isDirectory: &isDir), isDir.boolValue {
                            for u in DiskScanner.children(item.url) { try? fm.removeItem(at: u) }
                        } else {
                            try fm.removeItem(at: item.url)
                        }
                    case .buildFolders, .latexAux:
                        try fm.removeItem(at: item.url)
                    default:
                        try fm.trashItem(at: item.url, resultingItemURL: nil)
                    }
                } catch {
                    errors.append(item.url.lastPathComponent)
                }
            }
            return errors
        }) { [weak self] r in
            guard let self = self else { return }
            self.cleaning = false
            self.refreshDisk()
            let gained = max(0, self.free - before)
            let errors = (try? r.get()) ?? []
            let trashed = chosen.contains { !$0.0.regenerable && $0.0 != .trash && $0.0 != .ollama }
            var msg = "\(FileUtils.formatBytes(gained)) libérés · \(FileUtils.formatBytes(self.free)) disponibles"
            if trashed && !chosen.contains(where: { $0.0 == .trash }) { msg += " · vide la corbeille pour récupérer le reste" }
            if !errors.isEmpty { msg += " · \(errors.count) élément(s) protégé(s) ignoré(s)" }
            self.status = .ok(msg)
            ToastCenter.shared.show("🧹 \(FileUtils.formatBytes(gained)) libérés", cheer: gained > 1_000_000_000)
            // ce qui a été nettoyé disparaît de la liste
            let done = Set(chosen.map { $0.1.id })
            self.groups = self.groups.map { g in
                var g = g
                g.items = g.kind == .trash ? DiskScanner.trash() : g.items.filter { !done.contains($0.id) }
                return g
            }.filter { !$0.items.isEmpty }
            self.selected = []
        }
    }
}

// MARK: - Vue

struct CleanupToolView: View {
    @ObservedObject var s = CleanupStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .cleanup)
            diskBar
            if s.groups.isEmpty && !s.scanning {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("Je cherche ce qui prend de la place sur ton Mac").font(.title3.weight(.semibold))
                    Text("Caches, dossiers de compilation, fichiers LaTeX auxiliaires, corbeille, vieux téléchargements, gros fichiers, PDF en double, modèles IA. Rien n'est supprimé sans ton accord.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
                    Button { s.scan() } label: { Label("Analyser", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if s.scanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(s.progress).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) { ForEach(s.groups) { group($0) } }
                        .padding(.bottom, 10)
                }
                HStack {
                    Button { s.scan() } label: { Label("Analyser à nouveau", systemImage: "arrow.clockwise") }
                    Spacer()
                    Text("Sélection : \(FileUtils.formatBytes(s.selectedSize))").font(.callout.monospacedDigit())
                    if s.cleaning { ProgressView().controlSize(.small) }
                    Button { s.clean() } label: { Label("Nettoyer", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.cleaning || s.selected.isEmpty)
                }
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
        .onAppear { s.refreshDisk() }
    }

    private var diskBar: some View {
        let used = max(0, s.total - s.free)
        let p = s.total > 0 ? Double(used) / Double(s.total) : 0
        let low = s.free < 10_000_000_000
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Disque du Mac", systemImage: "internaldrive").font(.headline)
                Spacer()
                Text("\(FileUtils.formatBytes(s.free)) libres sur \(FileUtils.formatBytes(s.total))")
                    .font(.callout.monospacedDigit()).foregroundStyle(low ? Color.orange : Color.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: low ? [.orange, .red] : [.teal, .blue], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * p)
                    if s.selectedSize > 0, s.total > 0 {
                        Capsule().fill(Color.green.opacity(0.6))
                            .frame(width: max(4, g.size.width * Double(s.selectedSize) / Double(s.total)))
                            .offset(x: g.size.width * p - max(4, g.size.width * Double(s.selectedSize) / Double(s.total)))
                    }
                }
            }
            .frame(height: 12)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: s.selectedSize)
            if low {
                Text("Moins de 10 Go libres : macOS ralentit et les mises à jour peuvent échouer.").font(.caption).foregroundStyle(Color.orange)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
    }

    private func group(_ g: CleanGroup) -> some View {
        let ids = Set(g.items.map { $0.id })
        let all = ids.isSubset(of: s.selected)
        let partial = !ids.isDisjoint(with: s.selected)
        let open = s.expanded.contains(g.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { s.toggleGroup(g) } label: {
                    Image(systemName: all ? "checkmark.square.fill" : (partial ? "minus.square.fill" : "square"))
                        .font(.title3).foregroundStyle(all || partial ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                Image(systemName: g.kind.icon).font(.title3).foregroundStyle(g.kind.regenerable ? Color.green : Color.orange).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(g.kind.title).font(.headline)
                        Text(g.kind.regenerable ? "sans risque" : "à vérifier")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill((g.kind.regenerable ? Color.green : Color.orange).opacity(0.15)))
                            .foregroundStyle(g.kind.regenerable ? Color.green : Color.orange)
                    }
                    Text(g.kind.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(FileUtils.formatBytes(g.total)).font(.callout.weight(.semibold).monospacedDigit())
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { if open { s.expanded.remove(g.id) } else { s.expanded.insert(g.id) } }
                } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("\(g.items.count) élément\(g.items.count > 1 ? "s" : "")")
            }
            if open {
                VStack(spacing: 2) {
                    ForEach(g.items.prefix(200)) { item in row(item) }
                    if g.items.count > 200 { Text("… et \(g.items.count - 200) autres").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.leading, 34)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
    }

    private func row(_ item: CleanItem) -> some View {
        let isFile = item.url.isFileURL
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { s.selected.contains(item.id) },
                                     set: { if $0 { s.selected.insert(item.id) } else { s.selected.remove(item.id) } }))
                .labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 0) {
                Text(isFile ? item.url.lastPathComponent : item.url.absoluteString.replacingOccurrences(of: "ollama:", with: ""))
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Text(item.note.isEmpty ? (isFile ? item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "") : item.note)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(FileUtils.formatBytes(item.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if isFile {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Afficher dans le Finder")
            }
        }
        .padding(.vertical, 2)
    }
}
