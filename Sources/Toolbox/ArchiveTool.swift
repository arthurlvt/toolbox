import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFCore

// MARK: - Archives : créer (zip, tar.gz, tar.bz2, tar.xz, 7z) et extraire

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip, tarGz, tarBz2, tarXz, sevenZ
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zip: return ".zip"
        case .tarGz: return ".tar.gz"
        case .tarBz2: return ".tar.bz2"
        case .tarXz: return ".tar.xz"
        case .sevenZ: return ".7z"
        }
    }
    var ext: String { title }
    var hint: String {
        switch self {
        case .zip: return "S'ouvre partout (Windows, Mac, Moodle)"
        case .tarGz: return "Le classique Linux / Unix"
        case .tarBz2: return "Un peu plus petit que .tar.gz, plus lent"
        case .tarXz: return "Le plus petit des tar, le plus lent"
        case .sevenZ: return "Très compact, chiffrement AES (installe sevenzip)"
        }
    }
    var supportsPassword: Bool { self == .zip || self == .sevenZ }
}

enum ArchiveLevel: String, CaseIterable, Identifiable {
    case fast, normal, max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return "Rapide"
        case .normal: return "Normal"
        case .max: return "Maximum"
        }
    }
    var number: Int { self == .fast ? 1 : (self == .normal ? 6 : 9) }
}

enum ArchiveTool {
    static let junk = [".DS_Store", "__MACOSX", "._*", "Thumbs.db", "desktop.ini"]
    static let latexJunk = ["*.aux", "*.log", "*.out", "*.toc", "*.fls", "*.fdb_latexmk", "*.synctex.gz", "*.bbl", "*.blg",
                            "*.bcf", "*.run.xml", "*.nav", "*.snm", "*.lof", "*.lot"]
    /// Pour rendre un TP : pas de binaires, de caches ni de dossiers d'éditeur.
    static let tpJunk = [".git", ".vscode", ".idea", "__pycache__", "*.pyc", "*.o", "*.obj", "*.class", "a.out", "*.exe",
                         "*.dSYM", "build", "cmake-build-debug", "cmake-build-release", "node_modules", ".venv", "venv", ".pytest_cache"]

    static var sevenZip: String? { Shell.which("7zz") ?? Shell.which("7z") }

    static let archiveExtensions = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "jar"]

    static func isArchive(_ u: URL) -> Bool {
        archiveExtensions.contains(u.pathExtension.lowercased())
    }

    /// « TP3.tar.gz » → « TP3 »
    static func baseName(_ u: URL) -> String {
        var name = u.lastPathComponent
        for e in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz", ".tar", ".zip", ".7z", ".rar", ".gz", ".bz2", ".xz", ".jar"]
            where name.lowercased().hasSuffix(e) {
            name.removeLast(e.count)
            break
        }
        return name
    }

    /// Motifs d'exclusion pour zip (chemins complets) : fichier ou dossier, à n'importe quel niveau.
    static func zipPatterns(_ names: [String]) -> [String] {
        names.flatMap { n in [n, "*/" + n, n + "/*", "*/" + n + "/*"] }
    }

    static func folderSize(_ u: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else { return FileUtils.size(u) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    // MARK: Créer

    struct CreateOptions {
        var format: ArchiveFormat
        var level: ArchiveLevel
        var excludes: [String]
        var password: String
    }

    static func create(items: [URL], to out: URL, options o: CreateOptions) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        // regroupés par dossier parent : les chemins dans l'archive restent courts (« TP3/main.c »)
        var groups: [(URL, [String])] = []
        for u in items {
            let parent = u.deletingLastPathComponent()
            if let i = groups.firstIndex(where: { $0.0.path == parent.path }) { groups[i].1.append(u.lastPathComponent) }
            else { groups.append((parent, [u.lastPathComponent])) }
        }
        let noMeta = ["COPYFILE_DISABLE": "1"]
        switch o.format {
        case .zip:
            for (dir, names) in groups {
                var args = ["-r", "-X", "-q", "-\(o.level.number)"]
                if !o.password.isEmpty { args += ["-P", o.password] }
                args += [out.path] + names
                if !o.excludes.isEmpty { args += ["-x"] + zipPatterns(o.excludes) }
                let r = try Shell.run("/usr/bin/zip", args, in: dir, extraEnvironment: noMeta)
                // 12 = « rien à faire » (tout exclu) : pas une erreur grave
                guard r.status == 0 || r.status == 12 else { throw PDFToolError.commandFailed("zip : " + r.text.suffix(400)) }
            }
        case .tarGz, .tarBz2, .tarXz:
            let (flag, filter) = o.format == .tarGz ? ("-z", "gzip") : (o.format == .tarBz2 ? ("-j", "bzip2") : ("-J", "xz"))
            var args = ["-c", flag, "-f", out.path, "--no-mac-metadata", "--options", "\(filter):compression-level=\(o.level.number)"]
            for e in o.excludes { args += ["--exclude", e] }
            for (dir, names) in groups { args += ["-C", dir.path] + names }
            let r = try Shell.run("/usr/bin/tar", args, extraEnvironment: noMeta)
            guard r.status == 0 else { throw PDFToolError.commandFailed("tar : " + r.text.suffix(400)) }
        case .sevenZ:
            guard let seven = sevenZip else { throw PDFToolError.commandFailed("7-Zip n'est pas installé : brew install sevenzip") }
            for (dir, names) in groups {
                var args = ["a", "-t7z", "-mx=\(o.level.number)", "-bd", "-y"]
                if !o.password.isEmpty { args += ["-p" + o.password, "-mhe=on"] }
                args += o.excludes.map { "-xr!" + $0 }
                args += [out.path] + names
                let r = try Shell.run(seven, args, in: dir)
                guard r.status == 0 else { throw PDFToolError.commandFailed("7z : " + r.text.suffix(400)) }
            }
        }
    }

    // MARK: Lire / extraire

    static func list(_ archive: URL) throws -> [String] {
        let ext = archive.pathExtension.lowercased()
        if ext == "7z" || ext == "rar", let seven = sevenZip {
            let r = try Shell.run(seven, ["l", "-ba", "-slt", archive.path])
            if r.status == 0 {
                return r.text.components(separatedBy: "\n").compactMap { line in
                    line.hasPrefix("Path = ") ? String(line.dropFirst(7)) : nil
                }
            }
        }
        let r = try Shell.run("/usr/bin/tar", ["-tf", archive.path])
        guard r.status == 0 else { throw PDFToolError.commandFailed("Archive illisible : " + r.text.suffix(300)) }
        return r.text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static func isEncryptedZip(_ archive: URL) -> Bool {
        guard archive.pathExtension.lowercased() == "zip",
              let r = try? Shell.run("/usr/bin/unzip", ["-Z", "-v", archive.path]) else { return false }
        return r.text.range(of: #"file security status:\s+encrypted"#, options: .regularExpression) != nil
    }

    /// Extrait tout (ou `only`) dans un nouveau dossier à côté de l'archive ; renvoie ce dossier.
    static func extract(_ archive: URL, only: [String], password: String) throws -> URL {
        let dest = FileUtils.unique(archive.deletingLastPathComponent().appendingPathComponent(baseName(archive), isDirectory: true))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let ext = archive.pathExtension.lowercased()
        let r: Shell.Output
        if ext == "zip", !password.isEmpty {
            r = try Shell.run("/usr/bin/unzip", ["-q", "-o", "-P", password, archive.path] + only + ["-d", dest.path])
        } else if ext == "7z" || ext == "rar", let seven = sevenZip {
            var args = ["x", "-y", "-bd", "-o" + dest.path]
            if !password.isEmpty { args.append("-p" + password) }
            r = try Shell.run(seven, args + [archive.path] + only)
        } else {
            r = try Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", dest.path] + only)
        }
        guard r.status == 0 else {
            let t = r.text.lowercased()
            if t.contains("password") || t.contains("passphrase") || t.contains("incorrect") || t.contains("encrypt") {
                throw PDFToolError.commandFailed("Mot de passe manquant ou incorrect.")
            }
            throw PDFToolError.commandFailed("Extraction impossible : " + r.text.suffix(300))
        }
        // une archive qui contient un seul dossier : on évite « TP3/TP3/… »
        let content = (try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        if content.count == 1, (try? content[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           content[0].lastPathComponent == dest.lastPathComponent {
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".toolbox-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: content[0], to: tmp)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: tmp, to: dest)
        }
        return dest
    }
}

// MARK: - État

final class ArchiveStore: ObservableObject {
    static let shared = ArchiveStore()
    private let d = UserDefaults.standard

    enum Tab: String, CaseIterable, Identifiable {
        case pdf = "Compresser des PDF", create = "Créer une archive", extract = "Extraire"
        var id: String { rawValue }
    }

    @Published var tab = Tab.pdf
    // créer
    @Published var items: [URL] = [] { didSet { if items != oldValue { suggestName(); measure() } } }
    @Published var format = ArchiveFormat(rawValue: UserDefaults.standard.string(forKey: "archive.format") ?? "") ?? .zip {
        didSet { d.set(format.rawValue, forKey: "archive.format") }
    }
    @Published var level = ArchiveLevel.normal
    @Published var name = ""
    @Published var excludeJunk = true
    @Published var excludeLatex = false
    @Published var forTP = false
    @Published var password = ""
    @Published private(set) var inputSize: Int64 = 0
    // extraire
    @Published var archive: URL?
    @Published private(set) var entries: [String] = []
    @Published var selected: Set<String> = []
    @Published var extractPassword = ""
    @Published private(set) var encrypted = false
    // commun
    @Published var working = false
    @Published var status: StatusMessage?

    var excludes: [String] {
        (excludeJunk ? ArchiveTool.junk : []) + (excludeLatex ? ArchiveTool.latexJunk : []) + (forTP ? ArchiveTool.tpJunk : [])
    }

    func add(_ urls: [URL]) {
        let new = urls.filter { u in !items.contains(u) }
        items += new
    }

    private func suggestName() {
        if items.count == 1 {
            let u = items[0]
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            name = isDir.boolValue ? u.lastPathComponent : u.deletingPathExtension().lastPathComponent
        } else if name.isEmpty || items.isEmpty {
            name = items.isEmpty ? "" : "Archive"
        }
    }

    private func measure() {
        let list = items
        runInBackground({ list.reduce(Int64(0)) { $0 + ArchiveTool.folderSize($1) } }) { [weak self] r in
            if case .success(let n) = r { self?.inputSize = n }
        }
    }

    var output: URL? {
        guard let first = items.first else { return nil }
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Archive" : name.replacingOccurrences(of: "/", with: "-")
        return first.deletingLastPathComponent().appendingPathComponent(base + format.ext)
    }

    func create() {
        guard let target = output, !items.isEmpty else { return }
        if format == .sevenZ, ArchiveTool.sevenZip == nil {
            status = .err("7-Zip n'est pas installé. Dans le Terminal : brew install sevenzip")
            return
        }
        let out = FileUtils.unique(target)
        let opts = ArchiveTool.CreateOptions(format: format, level: level, excludes: excludes,
                                             password: format.supportsPassword ? password : "")
        let list = items, before = inputSize
        working = true
        status = .info("Création de \(out.lastPathComponent)…")
        runInBackground({ try ArchiveTool.create(items: list, to: out, options: opts) }) { [weak self] r in
            guard let self = self else { return }
            self.working = false
            switch r {
            case .success:
                let after = FileUtils.size(out)
                let ratio = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
                self.status = .ok("\(out.lastPathComponent) : \(FileUtils.formatBytes(before)) → \(FileUtils.formatBytes(after))"
                                  + (ratio > 0 ? " (−\(ratio) %)" : ""), files: [out])
                ToastCenter.shared.show("Archive créée ✓")
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    // MARK: Extraire

    func open(_ u: URL) {
        archive = u
        entries = []
        selected = []
        extractPassword = ""
        status = .info("Lecture de \(u.lastPathComponent)…")
        runInBackground({ (try ArchiveTool.list(u), ArchiveTool.isEncryptedZip(u)) }) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let (list, enc)):
                self.entries = list
                self.encrypted = enc
                let files = list.filter { !$0.hasSuffix("/") }.count
                self.status = .info("\(files) fichier\(files > 1 ? "s" : "") dans l'archive" + (enc ? " · protégée par mot de passe" : ""))
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    func extract() {
        guard let a = archive else { return }
        let only = Array(selected).sorted(), pw = extractPassword
        working = true
        status = .info("Extraction…")
        runInBackground({ try ArchiveTool.extract(a, only: only, password: pw) }) { [weak self] r in
            guard let self = self else { return }
            self.working = false
            switch r {
            case .success(let dest):
                self.status = .ok("Extrait dans « \(dest.lastPathComponent) »", files: [dest])
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }
}

// MARK: - Vues

struct ArchiveCreateView: View {
    @ObservedObject var s = ArchiveStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if s.items.isEmpty {
                drop
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        List {
                            ForEach(s.items, id: \.self) { u in
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 22, height: 22)
                                    Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button { s.items.removeAll { $0 == u } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            FileDrop.load(providers) { s.add($0) }
                            return true
                        }
                        HStack {
                            Button { s.add(pick()) } label: { Label("Ajouter", systemImage: "plus") }
                            Button("Tout vider") { s.items = []; s.status = nil }
                            Spacer()
                            Text("Avant : \(FileUtils.formatBytes(s.inputSize))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    options.frame(width: 330)
                }
            }
            StatusBanner(message: s.status)
        }
    }

    private var drop: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("Dépose des fichiers ou des dossiers à archiver").font(.title3.weight(.semibold))
            Text("zip, tar.gz, tar.bz2, tar.xz ou 7z · l'archive est créée à côté, les originaux ne bougent pas")
                .foregroundStyle(.secondary)
            Button("Choisir…") { s.add(pick()) }.controlSize(.large)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FileDrop.load(providers) { s.add($0) }
            return true
        }
    }

    private func pick() -> [URL] {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Ajouter"
        return p.runModal() == .OK ? p.urls : []
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Format", selection: $s.format) {
                ForEach(ArchiveFormat.allCases) { f in
                    Text(f.title + (f == .sevenZ && ArchiveTool.sevenZip == nil ? " (à installer)" : "")).tag(f)
                }
            }
            Text(s.format.hint).font(.caption).foregroundStyle(.secondary)
            Picker("Compression", selection: $s.level) {
                ForEach(ArchiveLevel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("Nom", text: $s.name).textFieldStyle(.roundedBorder)
                Text(s.format.ext).foregroundStyle(.secondary)
            }
            Toggle("Sans fichiers parasites (.DS_Store, __MACOSX…)", isOn: $s.excludeJunk)
            Toggle("Sans fichiers de compilation LaTeX (.aux, .log…)", isOn: $s.excludeLatex)
            Toggle(isOn: $s.forTP) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Prêt à rendre (TP)")
                    Text("Sans .git, .vscode, binaires (.o, a.out), build, __pycache__, node_modules")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if s.format.supportsPassword {
                SecureField("Mot de passe (facultatif)", text: $s.password).textFieldStyle(.roundedBorder)
                if s.format == .zip && !s.password.isEmpty {
                    Text("Chiffrement zip classique (faible) : pour du vrai chiffrement, choisis .7z (AES-256).")
                        .font(.caption).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if s.working { ProgressView().controlSize(.small) }
                Spacer()
                Button { s.create() } label: { Label("Créer l'archive", systemImage: "archivebox.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.working || s.items.isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
    }
}

struct ArchiveExtractView: View {
    @ObservedObject var s = ArchiveStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let a = s.archive {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.lastPathComponent).font(.headline)
                        Text(FileUtils.formatBytes(FileUtils.size(a))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Autre archive…") { if let u = pick() { s.open(u) } }
                }
                List {
                    ForEach(s.entries, id: \.self) { e in
                        let isDir = e.hasSuffix("/")
                        HStack(spacing: 8) {
                            if !isDir {
                                Toggle("", isOn: Binding(get: { s.selected.contains(e) },
                                                         set: { if $0 { s.selected.insert(e) } else { s.selected.remove(e) } }))
                                    .labelsHidden().toggleStyle(.checkbox)
                            }
                            Image(systemName: isDir ? "folder" : "doc").foregroundStyle(isDir ? Color.blue : Color.secondary)
                            Text(e).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                HStack(spacing: 10) {
                    if s.encrypted || a.pathExtension.lowercased() == "7z" {
                        SecureField("Mot de passe", text: $s.extractPassword).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                    Text(s.selected.isEmpty ? "Tout sera extrait" : "\(s.selected.count) fichier\(s.selected.count > 1 ? "s" : "") coché\(s.selected.count > 1 ? "s" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if !s.selected.isEmpty { Button("Tout décocher") { s.selected = [] }.buttonStyle(.borderless).font(.caption) }
                    Spacer()
                    if s.working { ProgressView().controlSize(.small) }
                    Button { s.extract() } label: { Label(s.selected.isEmpty ? "Tout extraire" : "Extraire la sélection", systemImage: "arrow.up.bin") }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.working || s.entries.isEmpty)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.bin").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("Dépose une archive à ouvrir").font(.title3.weight(.semibold))
                    Text(".zip, .tar, .tar.gz, .tgz, .tar.bz2, .tar.xz, .7z, .rar · tu vois le contenu avant d'extraire")
                        .foregroundStyle(.secondary)
                    Button("Choisir…") { if let u = pick() { s.open(u) } }.controlSize(.large)
                }
                .padding(30)
                .frame(maxWidth: .infinity, minHeight: 240)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
                Spacer()
            }
            StatusBanner(message: s.status)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FileDrop.load(providers) { urls in if let u = urls.first(where: ArchiveTool.isArchive) { s.open(u) } }
            return true
        }
    }

    private func pick() -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.prompt = "Ouvrir"
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return u
    }
}
