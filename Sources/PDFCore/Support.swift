import Foundation

// MARK: - Erreurs

public enum PDFToolError: LocalizedError {
    case cannotOpen(URL)
    case locked(URL)
    case cannotWrite(URL)
    case invalidRange(String)
    case imageUnreadable(URL)
    case toolMissing(String)
    case commandFailed(String)
    case noInput
    case wrongPassword

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let u): return "Impossible d'ouvrir « \(u.lastPathComponent) » (fichier PDF invalide ?)."
        case .locked(let u): return "« \(u.lastPathComponent) » est protégé par un mot de passe."
        case .cannotWrite(let u): return "Impossible d'écrire « \(u.lastPathComponent) »."
        case .invalidRange(let s): return "Plage de pages invalide : « \(s) ». Exemple attendu : 1-3, 5, 8-"
        case .imageUnreadable(let u): return "Image illisible : « \(u.lastPathComponent) »."
        case .toolMissing(let s): return "Outil introuvable : \(s)"
        case .commandFailed(let s): return "La commande a échoué : \(s)"
        case .noInput: return "Aucun fichier en entrée."
        case .wrongPassword: return "Mot de passe vide ou incorrect."
        }
    }
}

// MARK: - Fichiers

public enum FileUtils {
    public static func size(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }

    public static func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Renvoie une URL libre : « nom.pdf », sinon « nom 2.pdf », « nom 3.pdf »…
    public static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(i)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    /// Fichier voisin : /dossier/rapport.pdf → /dossier/rapport_compressé.pdf
    public static func sibling(of url: URL, suffix: String, ext: String? = nil) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        return unique(dir.appendingPathComponent(base + suffix).appendingPathExtension(ext ?? url.pathExtension))
    }

    /// Fichier temporaire caché dans le même dossier que `url` (même volume → remplacement atomique).
    public static func temporarySibling(of url: URL, ext: String = "pdf") -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".pdftoolbox-\(UUID().uuidString).\(ext)")
    }

    /// Remplace `dest` par `src` (déplace `src`).
    public static func replace(_ dest: URL, with src: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: src)
        } else {
            try fm.moveItem(at: src, to: dest)
        }
    }
}

// MARK: - Plages de pages

public enum PageRanges {
    /// "1-3, 5, 8-" → [0...2, 4...4, 7...n-1] (indices à partir de 0).
    /// "-3" = du début à 3, "8-" = de 8 à la fin.
    public static func parse(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for raw in text.split(separator: ",") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            var lo: Int
            var hi: Int
            if let dash = part.firstIndex(of: "-") {
                let a = part[..<dash].trimmingCharacters(in: .whitespaces)
                let b = part[part.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                guard let l = (a.isEmpty ? 1 : Int(a)),
                      let h = (b.isEmpty ? pageCount : Int(b)) else {
                    throw PDFToolError.invalidRange(part)
                }
                lo = l
                hi = h
            } else {
                guard let n = Int(part) else { throw PDFToolError.invalidRange(part) }
                lo = n
                hi = n
            }
            guard lo >= 1, hi <= pageCount, lo <= hi else { throw PDFToolError.invalidRange(part) }
            result.append((lo - 1)...(hi - 1))
        }
        if result.isEmpty { throw PDFToolError.invalidRange(text) }
        return result
    }

    /// Liste à plat des indices, dans l'ordre donné.
    public static func indices(_ text: String, pageCount: Int) throws -> [Int] {
        try parse(text, pageCount: pageCount).flatMap { Array($0) }
    }
}
