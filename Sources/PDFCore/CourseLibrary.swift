import Foundation

/// Type d'un document de cours, déduit du dossier (cours/, TDs/, TPs/, CCs/) ou du nom du fichier.
public enum CourseKind: String, CaseIterable, Codable, Identifiable {
    case cours, td, tp, cc, notes, autre

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cours: return "Cours"
        case .td: return "TD"
        case .tp: return "TP"
        case .cc: return "CC & annales"
        case .notes: return "Notes & photos"
        case .autre: return "Autres"
        }
    }

    /// Préfixe d'une séance : « TD 3 », « TP 2 », « Chapitre 4 »…
    public var sessionPrefix: String {
        switch self {
        case .cours: return "Chapitre"
        case .td: return "TD"
        case .tp: return "TP"
        case .cc: return "CC"
        case .notes, .autre: return ""
        }
    }

    /// Nom du dossier à créer s'il n'existe pas encore dans la matière.
    public var folderName: String {
        switch self {
        case .cours: return "cours"
        case .td: return "TDs"
        case .tp: return "TPs"
        case .cc: return "CCs"
        case .notes: return "notes"
        case .autre: return "divers"
        }
    }

    public static func from(folder name: String) -> CourseKind? {
        switch CourseLibrary.fold(name) {
        case "cours", "cm", "cms", "chapitres", "slides": return .cours
        case "td", "tds": return .td
        case "tp", "tps": return .tp
        case "cc", "ccs", "examens", "exams", "partiels", "annales", "ds": return .cc
        case "notes", "photos", "prises de notes": return .notes
        default: return nil
        }
    }

    /// D'après le nom d'un fichier posé directement dans la matière.
    public static func guess(fileName: String) -> CourseKind {
        let n = CourseLibrary.fold(fileName)
        if n.range(of: #"(^|[^a-z])(cc|ds|partiel|exam|examen|annale)s?([^a-z]|$)"#, options: .regularExpression) != nil { return .cc }
        if n.range(of: #"(^|[^a-z])tps?([^a-z]|$)"#, options: .regularExpression) != nil { return .tp }
        if n.range(of: #"(^|[^a-z])tds?([^a-z]|$)"#, options: .regularExpression) != nil { return .td }
        if n.contains("cours") || n.contains("chap") || n.contains("poly") { return .cours }
        return .autre
    }
}

/// Un fichier ou un dossier de travail (ex. TPs/TP3/) dans une matière.
public struct CourseItem: Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let kind: CourseKind
    public let number: Int?
    public let title: String
    public let isFolder: Bool
    public let modified: Date
    public let childCount: Int          // pour un dossier : nombre de fichiers utiles dedans
    public let previewFile: URL?        // pour un dossier : le PDF du sujet s'il y en a un
    public var group: String? = nil     // sous-dossier de documents d'où vient le fichier (ex. « 2026 »)

    public var ext: String { url.pathExtension.lowercased() }

    /// Corrigé d'un TD / d'un sujet : masqué par défaut pour ne pas tomber dessus trop tôt.
    public var isCorrection: Bool {
        CourseLibrary.fold(url.deletingPathExtension().lastPathComponent)
            .range(of: #"(^|[^a-z])(corr|correction|corrections|corrige|corriges|solution|solutions|soluce)([^a-z]|$)"#,
                   options: .regularExpression) != nil
    }

    public var isImage: Bool { ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff"].contains(ext) }
}

/// Une séance : tous les fichiers « TD 2 » (sujet PDF, TD2.py…) réunis.
public struct CourseSession: Identifiable, Hashable {
    public var id: String { kind.rawValue + "-" + (number.map(String.init) ?? items[0].id) }
    public let kind: CourseKind
    public let number: Int?
    public let items: [CourseItem]

    public var title: String {
        if let n = number { return "\(kind.sessionPrefix) \(n)" }
        if let g = items[0].group { return g }
        return items[0].title
    }

    /// Sous-titre parlant : « Codage », « Limites et continuite », « 6 documents »…
    public var subtitle: String {
        if number == nil, items[0].group != nil { return "\(items.count) document\(items.count > 1 ? "s" : "")" }
        guard number != nil else { return "" }
        return items.lazy.map { $0.title }.first { !$0.isEmpty } ?? ""
    }

    public var modified: Date { items.map { $0.modified }.max() ?? .distantPast }
}

public struct Course: Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let folderName: String
    public let domain: String           // « Maths », « Programmation »…
    public var name: String             // nom affiché (modifiable)
    public let sessions: [CourseSession]

    public func sessions(_ kind: CourseKind) -> [CourseSession] { sessions.filter { $0.kind == kind } }
    public var itemCount: Int { sessions.reduce(0) { $0 + $1.items.count } }
    public var lastModified: Date { sessions.map { $0.modified }.max() ?? .distantPast }

    /// Prochain numéro libre pour un nouveau TD/TP.
    public func nextNumber(_ kind: CourseKind) -> Int {
        (sessions(kind).compactMap { $0.number }.max() ?? 0) + 1
    }

    /// Dossier existant pour ce type (TDs/, TPs/…) ou celui à créer.
    public func folder(for kind: CourseKind) -> URL {
        let fm = FileManager.default
        if let list = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]),
           let existing = list.first(where: { CourseKind.from(folder: $0.lastPathComponent) == kind }) {
            return existing
        }
        return url.appendingPathComponent(kind.folderName, isDirectory: true)
    }
}

/// Lecture du dossier de cours : matières, séances, fichiers utiles (sans rien déplacer).
public enum CourseLibrary {
    /// Dossiers à ignorer (caches, compilation, dépôts…).
    static let ignoredDirs: Set<String> = ["__pycache__", "node_modules", ".git", "obj", "build", "dist", "venv", ".venv",
                                           "cmake-build-debug", "cmake-build-release", ".idea", ".vscode", "deriveddata"]
    /// Fichiers sans intérêt dans la liste (compilation, binaires…).
    static let ignoredExts: Set<String> = ["o", "d", "dtb", "dtbo", "elf", "pyc", "class", "aux", "log", "out", "toc",
                                           "fls", "fdb_latexmk", "synctex", "gz", "ds_store", "tmp", "bak", "lock"]

    public static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    static func visible(_ u: URL) -> Bool {
        let n = u.lastPathComponent
        if n.hasPrefix(".") || n.hasPrefix("~$") { return false }
        if ignoredDirs.contains(n.lowercased()) || n.lowercased().hasPrefix("cmake-build") { return false }
        if ignoredExts.contains(u.pathExtension.lowercased()) { return false }
        return true
    }

    /// Documents qu'on lit (par opposition au code) : un dossier qui n'a que ça est « déplié ».
    static let documentExts: Set<String> = ["pdf", "pptx", "ppt", "key", "docx", "doc", "odt", "odp", "png", "jpg", "jpeg",
                                            "heic", "gif", "md", "txt", "tex", "xlsx", "csv", "epub", "rtf"]

    static func isDocumentFolder(_ dir: URL) -> Bool {
        let list = children(dir)
        return !list.isEmpty && list.allSatisfy { !isDir($0) && documentExts.contains($0.pathExtension.lowercased()) }
    }

    /// Contenu d'un dossier tel qu'affiché (sans fichiers cachés ni fichiers de compilation), dossiers d'abord.
    public static func listing(_ dir: URL) -> [URL] {
        children(dir).sorted { a, b in
            let da = isDir(a), db = isDir(b)
            return da != db ? da : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    static func children(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        let list = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return list.filter(visible)
    }

    static func isDir(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// « analyse1 » → « Analyse 1 », « S2_structureOrdi » → « Structure ordi (S2) », « base_maths » → « Base maths ».
    public static func prettify(_ raw: String) -> String {
        var s = raw
        var semester = ""
        if let r = s.range(of: #"^[Ss]([1-6])[_\- ]+"#, options: .regularExpression) {
            semester = "S" + s[r].filter { $0.isNumber }
            s.removeSubrange(r)
        }
        s = s.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([A-Za-z])(\d)"#, with: "$1 $2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[_\-]+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let f = s.first { s = f.uppercased() + s.dropFirst() }
        return semester.isEmpty ? s : "\(s) (\(semester))"
    }

    /// Numéro de séance : TD3, TP_2, chap4, CC1, T3, « 5-Logique… », « 2- les listes »…
    static func number(in name: String) -> Int? {
        let base = (name as NSString).deletingPathExtension
        let patterns = [#"(?i)(?:^|[^a-z])(?:td|tp|cc|ds|cm|chap(?:itre)?|t|s[ée]ance|seance|exo)\s*[_\- ]?\s*(\d{1,2})(?!\d)"#,
                        #"^(\d{1,2})(?:\s*[\-_. ]|$)"#]
        for p in patterns {
            if let rx = try? NSRegularExpression(pattern: p),
               let m = rx.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
               let r = Range(m.range(at: 1), in: base), let n = Int(base[r]) {
                return n
            }
        }
        return nil
    }

    /// Titre lisible sans le préfixe TDx / chapx : « TD2-Codage » → « Codage ».
    static func title(of name: String) -> String {
        var s = (name as NSString).deletingPathExtension
        s = s.replacingOccurrences(of: #"(?i)^(td|tp|cc|ds|cm|chap(itre)?|t|exo)\s*[_\- ]?\s*\d{1,2}(?!\d)"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\d{1,2}\s*[\-_. ]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[_\-]+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        if let f = s.first { s = f.uppercased() + s.dropFirst() }
        return s
    }

    static func item(_ u: URL, kind: CourseKind) -> CourseItem {
        let folder = isDir(u)
        var count = 0
        var preview: URL?
        if folder, let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                if !visible(f) {
                    if isDir(f) { e.skipDescendants() }
                    continue
                }
                if isDir(f) { continue }
                count += 1
                if preview == nil || (f.pathExtension.lowercased() == "pdf" && preview?.pathExtension.lowercased() != "pdf") {
                    if ["pdf", "md", "txt", "png", "jpg"].contains(f.pathExtension.lowercased()) { preview = f }
                }
                if count > 2000 { break }
            }
        }
        let name = u.lastPathComponent
        return CourseItem(url: u, kind: kind, number: number(in: name), title: title(of: name), isFolder: folder,
                          modified: modified(u), childCount: count, previewFile: preview)
    }

    /// Une matière : ses sous-dossiers de type + les fichiers posés à sa racine.
    static func course(at dir: URL, domain: String) -> Course {
        var items: [CourseItem] = []
        for c in children(dir) {
            if isDir(c), let kind = CourseKind.from(folder: c.lastPathComponent) {
                // Dossiers d'années (cours/2026, cours/2027) : seule la plus récente compte,
                // sauf pour les CC et annales où les anciens sujets servent à réviser.
                let years = children(c).filter { isDir($0) && $0.lastPathComponent.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil }
                let latest = years.map { $0.lastPathComponent }.max()
                for f in children(c) {
                    if kind != .cc, years.count > 1, years.contains(f), f.lastPathComponent != latest { continue }
                    if isDir(f) && isDocumentFolder(f) {
                        // Sous-dossier de documents (cours/2026/, CCs/CC1/…) : ses fichiers, regroupés.
                        let folderNumber = number(in: f.lastPathComponent)
                        let label = folderNumber == nil ? prettify(f.lastPathComponent) : f.lastPathComponent
                        for g in children(f) {
                            let base = item(g, kind: kind)
                            items.append(CourseItem(url: base.url, kind: kind, number: folderNumber, title: base.title,
                                                    isFolder: false, modified: base.modified, childCount: 0,
                                                    previewFile: nil, group: label))
                        }
                    } else {
                        items.append(item(f, kind: kind))
                    }
                }
            } else if isDir(c) {
                items.append(item(c, kind: .autre))
            } else {
                items.append(item(c, kind: CourseKind.guess(fileName: c.lastPathComponent)))
            }
        }
        // Séances : même type + même numéro ; sans numéro, chaque document est seul.
        var groups: [String: [CourseItem]] = [:]
        var order: [String] = []
        for it in items {
            let key = it.number.map { "\(it.kind.rawValue)#\($0)" }
                ?? it.group.map { "\(it.kind.rawValue)@\(it.url.deletingLastPathComponent().path)/\($0)" }
                ?? "\(it.kind.rawValue)@\(it.url.path)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(it)
        }
        let sessions = order.compactMap { key -> CourseSession? in
            guard let list = groups[key], let first = list.first else { return nil }
            // le PDF du sujet d'abord, puis les dossiers, puis le reste
            let sorted = list.sorted { a, b in
                func rank(_ i: CourseItem) -> Int { i.ext == "pdf" ? 0 : (i.isFolder ? 1 : 2) }
                if a.group != nil && a.group == b.group {   // 1-…, 2-…, 10-… dans l'ordre naturel
                    return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
                }
                return rank(a) != rank(b) ? rank(a) < rank(b)
                    : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
            return CourseSession(kind: first.kind, number: first.number, items: sorted)
        }
        .sorted { a, b in
            if a.kind != b.kind { return CourseKind.allCases.firstIndex(of: a.kind)! < CourseKind.allCases.firstIndex(of: b.kind)! }
            switch (a.number, b.number) {
            case let (x?, y?): return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
        return Course(url: dir, folderName: dir.lastPathComponent, domain: domain,
                      name: prettify(dir.lastPathComponent), sessions: sessions)
    }

    /// Repère les matières : un dossier qui contient cours/, TDs/, TPs/ ou CCs/ ; et ses dossiers « frères »
    /// (ex. programmation/POO à côté de programmation/Python). Profondeur max 3.
    public static func scan(root: URL) -> [Course] {
        var matieres: [URL] = []
        func isCourseDir(_ d: URL) -> Bool {
            children(d).contains { isDir($0) && CourseKind.from(folder: $0.lastPathComponent) != nil }
        }
        func walk(_ d: URL, depth: Int) {
            guard depth <= 3 else { return }
            for c in children(d) where isDir(c) {
                if isCourseDir(c) { matieres.append(c) } else { walk(c, depth: depth + 1) }
            }
        }
        walk(root, depth: 1)
        // Frères des matières trouvées (même domaine), s'ils ont des documents.
        let parents = Set(matieres.map { $0.deletingLastPathComponent().path })
        for p in parents where p != root.path {
            for c in children(URL(fileURLWithPath: p)) where isDir(c) && !matieres.contains(c) {
                // un dossier qui contient déjà des matières (ex. POO/ avec c/ et cpp/) n'en est pas une
                if matieres.contains(where: { $0.path.hasPrefix(c.path + "/") }) { continue }
                let docs = children(c).contains { ["pdf", "tex", "md", "py", "c", "cpp", "java", "sh", "html", "php"].contains($0.pathExtension.lowercased()) || isDir($0) }
                if docs { matieres.append(c) }
            }
        }
        let rootParts = root.standardizedFileURL.pathComponents.count
        return matieres.map { m in
            let parts = m.standardizedFileURL.pathComponents
            let between = parts.dropFirst(rootParts).dropLast()
            let domain = between.isEmpty ? "Général" : between.map(prettify).joined(separator: " › ")
            return course(at: m, domain: domain)
        }
        .sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
    }
}
