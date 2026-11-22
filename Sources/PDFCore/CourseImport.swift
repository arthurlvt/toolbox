import Foundation

// MARK: - Importer / exporter des cours (.zip ou dossier)
//
// Import : n'importe quelle archive (export Toolbox, dossier d'un ami, téléchargement Moodle, zip d'un prof…)
// est ouverte, ses matières repérées, chaque fichier classé (cours / TD / TP / CC / notes) puis copié dans le
// dossier de cours, en rejoignant les matières qui existent déjà. Rien n'est déplacé ni écrasé.
// Export : un .zip propre (sans fichiers de compilation, avec ou sans notes perso et corrigés) + un manifeste
// qui garde les noms affichés et les autres noms des matières.

public struct ImportError: LocalizedError {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var errorDescription: String? { text }
}

public enum CourseImport {

    /// Manifeste écrit à la racine d'un export Toolbox.
    public static let manifestName = "toolbox-cours.json"

    public struct ManifestEntry: Codable, Equatable {
        public var path: String          // chemin de la matière dans l'archive (« Maths/Analyse 1 »)
        public var name: String          // nom affiché
        public var aliases: String
        public init(path: String, name: String, aliases: String) { self.path = path; self.name = name; self.aliases = aliases }
    }

    public struct Manifest: Codable {
        public var version = 1
        public var created: Date
        public var subjects: [ManifestEntry]
        public init(created: Date, subjects: [ManifestEntry]) { self.created = created; self.subjects = subjects }
    }

    /// Un fichier à copier, et où il ira dans sa matière.
    public struct File: Hashable {
        public let source: URL
        public var kind: CourseKind
        public var relative: String      // chemin sous le dossier du type (« TP3/main.c », « td2.pdf »)
        public init(source: URL, kind: CourseKind, relative: String) {
            self.source = source; self.kind = kind; self.relative = relative
        }
    }

    /// Une matière de l'archive.
    public struct Group: Identifiable {
        public let id = UUID()
        public var name: String                  // nom lu (dossier, manifeste, archive)
        public var domain: String                // « Maths » si l'archive range les matières par domaine, sinon ""
        public var aliases: String
        public var files: [File]
        /// Matière existante qui correspond (dossier), sinon nil = nouvelle matière.
        public var target: URL?

        public func count(_ k: CourseKind) -> Int { files.filter { $0.kind == k }.count }

        public init(name: String, domain: String, aliases: String, files: [File], target: URL?) {
            self.name = name; self.domain = domain; self.aliases = aliases; self.files = files; self.target = target
        }
    }

    public struct Plan {
        public var groups: [Group]
        public var workDir: URL?                 // dossier temporaire (archive extraite) à supprimer à la fin
        public var fromToolbox: Bool
        public var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }

        public init(groups: [Group], workDir: URL?, fromToolbox: Bool) {
            self.groups = groups; self.workDir = workDir; self.fromToolbox = fromToolbox
        }
    }

    public struct Result {
        public var copied: [URL] = []
        public var skipped = 0                   // déjà là, identiques
        public var newSubjects: [URL] = []
    }

    // MARK: Ouvrir l'archive

    static let junk: Set<String> = ["__macosx", ".ds_store", "thumbs.db", "desktop.ini", ".git", ".svn", ".idea", ".vscode",
                                    "__pycache__", "node_modules", ".venv", "venv", toolboxLower]
    static var toolboxLower: String { manifestName.lowercased() }

    /// Extrait l'archive (zip, tar, tar.gz, tar.bz2, tar.xz, 7z) dans un dossier temporaire, ou prend le dossier tel quel.
    public static func open(_ url: URL) throws -> (dir: URL, temporary: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError("Fichier introuvable : \(url.lastPathComponent)")
        }
        if isDir.boolValue { return (url, false) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let name = url.lastPathComponent.lowercased()
        let r: Shell.Output
        if name.hasSuffix(".zip") {
            r = try Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, tmp.path])
        } else if name.hasSuffix(".7z") || name.hasSuffix(".rar") {
            guard let z = Shell.which("7zz") ?? Shell.which("7z") else {
                throw ImportError("Il faut 7-Zip pour ouvrir ce fichier (brew install sevenzip).")
            }
            r = try Shell.run(z, ["x", "-y", "-o" + tmp.path, url.path])
        } else if [".tar", ".tgz", ".tar.gz", ".tbz2", ".tar.bz2", ".txz", ".tar.xz"].contains(where: { name.hasSuffix($0) }) {
            r = try Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", tmp.path])
        } else {
            throw ImportError("Format non pris en charge : choisis un .zip, un .tar.gz, un .7z ou un dossier.")
        }
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ImportError("Impossible d'ouvrir l'archive : \(r.text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
        }
        return (tmp, true)
    }

    static func entries(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !junk.contains($0.lastPathComponent.lowercased()) && !$0.lastPathComponent.hasPrefix("._") }
    }

    static func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    /// Descend tant que l'archive ne contient qu'un dossier (« MonZip/MonZip/… »).
    static func unwrap(_ dir: URL) -> URL {
        var d = dir
        for _ in 0..<4 {
            let e = entries(d)
            if e.count == 1, isDir(e[0]), FileManager.default.fileExists(atPath: e[0].path),
               !e.contains(where: { $0.lastPathComponent == manifestName }) {
                // on s'arrête si ce dossier unique est lui-même une matière (cours/, TDs/… dedans)
                if entries(e[0]).contains(where: { isDir($0) && kindFromFolder($0.lastPathComponent) != nil }) { break }
                d = e[0]
            } else { break }
        }
        return d
    }

    /// Tous les fichiers utiles sous `dir` (sans compilation, caches, fichiers cachés).
    static func files(under dir: URL) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in e {
            let n = u.lastPathComponent.lowercased()
            if isDir(u) {
                if junk.contains(n) || CourseLibrary.ignoredDirs.contains(n) { e.skipDescendants() }
                continue
            }
            if junk.contains(n) || n.hasPrefix("._") || CourseLibrary.ignoredExts.contains(u.pathExtension.lowercased()) { continue }
            out.append(u)
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: Classer

    /// Type d'après un nom de dossier : ceux de Toolbox (cours, TDs…) et ceux qu'on croise sur Moodle.
    public static func kindFromFolder(_ name: String) -> CourseKind? {
        if let k = CourseKind.from(folder: name) { return k }
        let n = CourseLibrary.fold(name)
        if n.contains("travaux diriges") || n.range(of: #"(^|[^a-z])tds?([^a-z]|$)"#, options: .regularExpression) != nil { return .td }
        if n.contains("travaux pratiques") || n.range(of: #"(^|[^a-z])tps?([^a-z]|$)"#, options: .regularExpression) != nil { return .tp }
        if ["examen", "annale", "partiel", "controle", "evaluation"].contains(where: { n.contains($0) })
            || n.range(of: #"(^|[^a-z])(cc|ds)s?([^a-z]|$)"#, options: .regularExpression) != nil { return .cc }
        if ["cours magistr", "chapitre", "diaporama", "slides", "transparents", "polycop"].contains(where: { n.contains($0) })
            || n.range(of: #"(^|[^a-z])cms?([^a-z]|$)"#, options: .regularExpression) != nil { return .cours }
        if n == "notes" || n.hasPrefix("photos") { return .notes }
        return nil
    }

    /// Classe un fichier d'après son chemin dans la matière : le premier dossier qui dit son type,
    /// sinon son nom ; un document sans indice va dans « cours ».
    public static func classify(_ components: [String]) -> (CourseKind, String) {
        let dirs = Array(components.dropLast())
        let fileName = components.last ?? ""
        // le dossier le plus haut qui dit son type : « TPs/TP3/main.c » garde son dossier TP3
        for i in dirs.indices {
            if let k = kindFromFolder(dirs[i]) {
                let rest = components[(i + 1)...].joined(separator: "/")
                return (k, rest)
            }
        }
        let g = CourseKind.guess(fileName: fileName)
        if g != .autre { return (g, fileName) }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let images: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]
        if images.contains(ext) { return (.notes, fileName) }
        // code sans indice : garde son dossier (projet), rangé avec les TP
        let code: Set<String> = ["c", "h", "cpp", "hpp", "py", "java", "js", "ts", "sh", "sql", "php", "html", "css", "rs", "go", "ml", "hs"]
        if code.contains(ext) { return (.tp, components.suffix(2).joined(separator: "/")) }
        return (.cours, fileName)
    }

    // MARK: Plan

    /// Lit l'archive et prépare l'import ; `existing` : matières déjà là, avec leurs noms affichés et autres noms.
    public static func plan(_ url: URL, existing: [(course: Course, name: String, aliases: String)]) throws -> Plan {
        let opened = try open(url)
        let base = unwrap(opened.dir)
        let manifest: Manifest? = {
            let m = base.appendingPathComponent(manifestName)
            guard let d = try? Data(contentsOf: m) else { return nil }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return try? dec.decode(Manifest.self, from: d)
        }()

        var groups: [Group] = []
        var used = Set<String>()                      // fichiers déjà rattachés à une matière

        func add(subjectDir: URL, name: String, domain: String, aliases: String) {
            let all = files(under: subjectDir)
            guard !all.isEmpty else { return }
            let prefix = subjectDir.standardizedFileURL.pathComponents.count
            var g = Group(name: name, domain: domain, aliases: aliases, files: [], target: nil)
            for f in all {
                let comps = Array(f.standardizedFileURL.pathComponents.dropFirst(prefix))
                let (k, rel) = classify(comps)
                g.files.append(File(source: f, kind: k, relative: rel))
                used.insert(f.standardizedFileURL.path)
            }
            groups.append(g)
        }

        // 1. Matières repérées comme dans « Mes cours » (dossiers avec cours/, TDs/, TPs/, CCs/…)
        let found = CourseLibrary.scan(root: base)
        let rootParts = base.standardizedFileURL.pathComponents.count
        for c in found {
            let parts = c.url.standardizedFileURL.pathComponents
            let rel = parts.dropFirst(rootParts).joined(separator: "/")
            let m = manifest?.subjects.first { $0.path == rel }
            let domainParts = parts.dropFirst(rootParts).dropLast()
            add(subjectDir: c.url, name: m?.name ?? c.name, domain: domainParts.map(CourseLibrary.prettify).joined(separator: " › "),
                aliases: m?.aliases ?? "")
        }

        // 2. Le reste : un dossier de premier niveau = une matière (Moodle : « Analyse 1/Section TD/… »),
        //    les fichiers posés à la racine = une matière au nom de l'archive.
        let leftovers = files(under: base).filter { !used.contains($0.standardizedFileURL.path) }
        if !leftovers.isEmpty {
            let topDirs = entries(base).filter { d in
                isDir(d) && leftovers.contains { $0.standardizedFileURL.path.hasPrefix(d.standardizedFileURL.path + "/") }
            }
            for d in topDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let mine = leftovers.filter { $0.standardizedFileURL.path.hasPrefix(d.standardizedFileURL.path + "/") }
                guard !mine.isEmpty else { continue }
                // le dossier de premier niveau est-il lui-même un type (« TD », « Cours ») ? alors tout est une seule matière
                if kindFromFolder(d.lastPathComponent) != nil { continue }
                var g = Group(name: CourseLibrary.prettify(d.lastPathComponent), domain: "", aliases: "", files: [], target: nil)
                let prefix = d.standardizedFileURL.pathComponents.count
                for f in mine {
                    let (k, rel) = classify(Array(f.standardizedFileURL.pathComponents.dropFirst(prefix)))
                    g.files.append(File(source: f, kind: k, relative: rel))
                    used.insert(f.standardizedFileURL.path)
                }
                groups.append(g)
            }
            let rest = leftovers.filter { !used.contains($0.standardizedFileURL.path) }
            if !rest.isEmpty {
                let archiveName = CourseLibrary.prettify(url.deletingPathExtension().deletingPathExtension().lastPathComponent)
                var g = Group(name: archiveName, domain: "", aliases: "", files: [], target: nil)
                let prefix = base.standardizedFileURL.pathComponents.count
                for f in rest {
                    let (k, rel) = classify(Array(f.standardizedFileURL.pathComponents.dropFirst(prefix)))
                    g.files.append(File(source: f, kind: k, relative: rel))
                }
                groups.append(g)
            }
        }

        // 3. Rattacher aux matières existantes
        for i in groups.indices {
            groups[i].target = match(groups[i], in: existing)?.url
        }
        return Plan(groups: groups, workDir: opened.temporary ? opened.dir : nil, fromToolbox: manifest != nil)
    }

    /// Matière existante qui correspond : même nom (sans accents ni casse), un autre nom commun, ou l'un contient l'autre.
    public static func match(_ g: Group, in existing: [(course: Course, name: String, aliases: String)]) -> Course? {
        func keys(_ name: String, _ folder: String, _ aliases: String) -> [String] {
            ([name, folder, CourseLibrary.prettify(folder)] + aliases.split(separator: ",").map(String.init))
                .map { CourseLibrary.fold($0).trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 3 }
        }
        let mine = keys(g.name, g.name, g.aliases)
        // égalité d'abord
        if let e = existing.first(where: { ex in
            let theirs = keys(ex.name, ex.course.folderName, ex.aliases)
            return mine.contains { theirs.contains($0) }
        }) { return e.course }
        // puis inclusion (« Analyse 1 » ↔ « Analyse 1 - Guillaume Sophie »), sur des noms assez longs
        if let e = existing.first(where: { ex in
            let theirs = keys(ex.name, ex.course.folderName, ex.aliases)
            return mine.contains { m in m.count >= 5 && theirs.contains { t in t.count >= 5 && (m.contains(t) || t.contains(m)) } }
        }) { return e.course }
        return nil
    }

    // MARK: Copier

    /// Copie le plan dans `root`. Les fichiers identiques déjà présents sont sautés, les autres jamais écrasés.
    public static func apply(_ plan: Plan, root: URL) throws -> Result {
        let fm = FileManager.default
        var res = Result()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for g in plan.groups where !g.files.isEmpty {
            let subject: URL
            var existingCourse: Course?
            if let t = g.target {
                subject = t
                existingCourse = CourseLibrary.course(at: t, domain: "")
            } else {
                var dir = root
                for part in g.domain.components(separatedBy: " › ") where !part.isEmpty { dir.appendPathComponent(safe(part), isDirectory: true) }
                subject = FileUtils.unique(dir.appendingPathComponent(safe(g.name), isDirectory: true))
                try fm.createDirectory(at: subject, withIntermediateDirectories: true)
                res.newSubjects.append(subject)
            }
            for f in g.files {
                let kindDir = existingCourse?.folder(for: f.kind) ?? subject.appendingPathComponent(f.kind.folderName, isDirectory: true)
                var dest = kindDir
                for part in f.relative.split(separator: "/") { dest.appendPathComponent(safe(String(part))) }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    if fm.contentsEqual(atPath: dest.path, andPath: f.source.path) { res.skipped += 1; continue }
                    dest = FileUtils.unique(dest)
                }
                try fm.copyItem(at: f.source, to: dest)
                res.copied.append(dest)
            }
        }
        return res
    }

    public static func safeName(_ s: String) -> String { safe(s) }

    static func safe(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Sans nom" : t
    }

    public static func cleanup(_ plan: Plan) {
        if let w = plan.workDir { try? FileManager.default.removeItem(at: w) }
    }

    // MARK: Exporter

    public struct ExportOptions {
        public var includeNotes = false          // notes/ et photos du tableau : perso
        public var includeCorrections = true
        public init(includeNotes: Bool = false, includeCorrections: Bool = true) {
            self.includeNotes = includeNotes; self.includeCorrections = includeCorrections
        }
    }

    /// Exporte les matières (dossier, nom affiché, autres noms) dans un .zip relisible par `plan`.
    @discardableResult
    public static func export(_ subjects: [(course: Course, name: String, aliases: String)], root: URL, to zip: URL,
                              options: ExportOptions) throws -> Int {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("toolbox-export-\(UUID().uuidString)", isDirectory: true)
        let top = stage.appendingPathComponent(safe(zip.deletingPathExtension().lastPathComponent), isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        var entries: [ManifestEntry] = []
        var count = 0
        let rootParts = root.standardizedFileURL.pathComponents.count
        for s in subjects {
            let parts = s.course.url.standardizedFileURL.pathComponents
            let rel = parts.count > rootParts ? parts.dropFirst(rootParts).joined(separator: "/") : s.course.folderName
            let dest = top.appendingPathComponent(rel, isDirectory: true)
            let prefix = s.course.url.standardizedFileURL.pathComponents.count
            for f in files(under: s.course.url) {
                let comps = Array(f.standardizedFileURL.pathComponents.dropFirst(prefix))
                if !options.includeNotes, let first = comps.first, CourseKind.from(folder: first) == .notes { continue }
                if !options.includeCorrections,
                   CourseLibrary.fold(f.deletingPathExtension().lastPathComponent)
                    .range(of: #"(^|[^a-z])(corr|correction|corrections|corrige|corriges|solution|solutions|soluce)([^a-z]|$)"#,
                           options: .regularExpression) != nil { continue }
                var out = dest
                for c in comps { out.appendPathComponent(c) }
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: f, to: out)
                count += 1
            }
            entries.append(ManifestEntry(path: rel, name: s.name, aliases: s.aliases))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(Manifest(created: Date(), subjects: entries)).write(to: top.appendingPathComponent(manifestName))
        if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
        let r = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", top.path, zip.path])
        guard r.status == 0 else { throw ImportError("Échec de la création du .zip.") }
        return count
    }
}
