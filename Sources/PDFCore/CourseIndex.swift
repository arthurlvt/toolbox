import Foundation
import PDFKit
import ImageIO

/// Un passage trouvé dans le contenu d'un document.
public struct ContentHit: Identifiable, Hashable {
    public let id = UUID()
    public let url: URL
    public let page: Int?          // page (0…) pour un PDF
    public let snippet: String
}

/// Index plein texte local des cours : texte des PDF, fichiers texte / code, photos lues par OCR.
/// Gardé dans ~/Library/Application Support/Toolbox/IndexCours.json et mis à jour au fil des changements.
public final class CourseIndex {
    public static let shared = CourseIndex()

    struct Entry: Codable {
        var mtime: Double
        var pages: [String]
    }

    private var entries: [String: Entry] = [:]
    private var folded: [String: [String]] = [:]
    private let lock = NSLock()
    private var loaded = false

    static let textExts: Set<String> = ["txt", "md", "tex", "py", "c", "h", "cpp", "hpp", "java", "sh", "js", "ts", "php",
                                        "html", "css", "csv", "ml", "sql", "ino", "json"]
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff"]

    public static func indexable(_ u: URL) -> Bool {
        let e = u.pathExtension.lowercased()
        return e == "pdf" || textExts.contains(e) || imageExts.contains(e)
    }

    var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/IndexCours.json")
    }

    private func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = e
            folded = e.mapValues { $0.pages.map(CourseLibrary.fold) }
        }
    }

    private func save() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
    }

    /// Indexe ce qui est nouveau ou modifié, oublie ce qui a disparu. À appeler hors du thread principal.
    public func update(files: [URL], progress: ((Int, Int) -> Void)? = nil) {
        loadIfNeeded()
        let wanted = Set(files.map { $0.path })
        lock.lock()
        for k in entries.keys where !wanted.contains(k) { entries[k] = nil; folded[k] = nil }
        let known = entries.mapValues { $0.mtime }
        lock.unlock()

        let todo = files.filter { u in
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return known[u.path] != m
        }
        for (i, u) in todo.enumerated() {
            progress?(i, todo.count)
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            let pages = Self.extract(u)
            lock.lock()
            entries[u.path] = Entry(mtime: m, pages: pages)
            folded[u.path] = pages.map(CourseLibrary.fold)
            lock.unlock()
            if i % 25 == 24 { save() }
        }
        progress?(todo.count, todo.count)
        save()
    }

    static func extract(_ u: URL) -> [String] {
        let e = u.pathExtension.lowercased()
        if e == "pdf" {
            guard let doc = PDFDocument(url: u), !doc.isLocked else { return [] }
            return (0..<min(doc.pageCount, 400)).map { doc.page(at: $0)?.string ?? "" }
        }
        if textExts.contains(e) {
            guard let data = try? Data(contentsOf: u, options: .mappedIfSafe) else { return [] }
            let text = String(decoding: data.prefix(300_000), as: UTF8.self)
            return [text]
        }
        if imageExts.contains(e) {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let text = try? OCR.text(of: image) else { return [] }
            return [text]
        }
        return []
    }

    /// Texte connu d'un fichier (pour une photo : le texte lu par OCR).
    public func text(of url: URL) -> String? {
        loadIfNeeded()
        lock.lock(); defer { lock.unlock() }
        return entries[url.path]?.pages.joined(separator: "\n\n")
    }

    public var count: Int {
        loadIfNeeded()
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Passages contenant tous les mots cherchés (accents et majuscules ignorés).
    public func search(_ query: String, limit: Int = 40) -> [ContentHit] {
        let words = CourseLibrary.fold(query).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty, words.joined().count >= 3 else { return [] }
        loadIfNeeded()
        lock.lock()
        let f = folded, e = entries
        lock.unlock()
        var hits: [ContentHit] = []
        for (path, pages) in f.sorted(by: { $0.key < $1.key }) {
            for (i, page) in pages.enumerated() where words.allSatisfy({ page.contains($0) }) {
                let original = e[path]?.pages[safe: i] ?? page
                let url = URL(fileURLWithPath: path)
                hits.append(ContentHit(url: url, page: url.pathExtension.lowercased() == "pdf" ? i : nil,
                                       snippet: Self.snippet(original, folded: page, word: words[0])))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Une soixantaine de caractères autour du premier mot trouvé.
    static func snippet(_ original: String, folded: String, word: String) -> String {
        let o = Array(original), f = Array(folded)
        let source = o.count == f.count ? o : f
        guard let r = folded.range(of: word) else { return String(source.prefix(120)) }
        let pos = folded.distance(from: folded.startIndex, to: r.lowerBound)
        let start = max(0, pos - 60), end = min(source.count, pos + word.count + 80)
        var s = String(source[start..<end]).replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + s + (end < source.count ? "…" : "")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
