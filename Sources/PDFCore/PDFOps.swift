import Foundation
import PDFKit

/// Opérations de base sur les pages : ouvrir, enregistrer, fusionner, diviser,
/// extraire, supprimer, pivoter.
public enum PDFOps {

    // MARK: Ouverture / enregistrement

    public static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PDFToolError.cannotOpen(url) }
        if doc.isLocked { throw PDFToolError.locked(url) }
        return doc
    }

    /// Écrit dans un fichier temporaire puis remplace : on peut donc écraser
    /// le fichier source sans risque de le corrompre.
    public static func save(_ doc: PDFDocument, to url: URL) throws {
        let tmp = FileUtils.temporarySibling(of: url)
        guard doc.write(to: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            throw PDFToolError.cannotWrite(url)
        }
        try FileUtils.replace(url, with: tmp)
    }

    public static func pages(of doc: PDFDocument) -> [PDFPage] {
        (0..<doc.pageCount).compactMap { doc.page(at: $0) }
    }

    /// Copie indépendante d'une page (rotation comprise), insérable dans un autre document.
    public static func copy(_ page: PDFPage) -> PDFPage {
        let c = (page.copy() as? PDFPage) ?? page
        c.rotation = page.rotation
        return c
    }

    public static func makeDocument(from pages: [PDFPage]) -> PDFDocument {
        let out = PDFDocument()
        for p in pages { out.insert(copy(p), at: out.pageCount) }
        return out
    }

    // MARK: Fusionner

    @discardableResult
    public static func merge(_ inputs: [URL], into output: URL) throws -> Int {
        guard !inputs.isEmpty else { throw PDFToolError.noInput }
        let docs = try inputs.map { try PDFOps.open($0) }
        let out = withExtendedLifetime(docs) {
            makeDocument(from: docs.flatMap(pages(of:)))
        }
        try save(out, to: output)
        return out.pageCount
    }

    // MARK: Diviser

    public enum SplitMode {
        case everyPage
        case every(Int)
        case ranges(String)
    }

    public static func groups(for mode: SplitMode, pageCount n: Int) throws -> [ClosedRange<Int>] {
        switch mode {
        case .everyPage:
            return (0..<n).map { $0...$0 }
        case .every(let k):
            guard k >= 1 else { throw PDFToolError.invalidRange("\(k)") }
            return stride(from: 0, to: n, by: k).map { $0...min($0 + k - 1, n - 1) }
        case .ranges(let text):
            return try PageRanges.parse(text, pageCount: n)
        }
    }

    /// Crée un PDF par groupe de pages dans `folder`. Renvoie les fichiers créés.
    public static func split(_ input: URL, mode: SplitMode, into folder: URL) throws -> [URL] {
        let doc = try open(input)
        let groups = try groups(for: mode, pageCount: doc.pageCount)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = input.deletingPathExtension().lastPathComponent
        let width = String(doc.pageCount).count
        func pad(_ i: Int) -> String {
            let s = String(i)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        var outputs: [URL] = []
        for g in groups {
            let label = g.count == 1
                ? "p\(pad(g.lowerBound + 1))"
                : "p\(pad(g.lowerBound + 1))-\(pad(g.upperBound + 1))"
            let url = FileUtils.unique(folder.appendingPathComponent("\(base)_\(label).pdf"))
            try save(makeDocument(from: g.compactMap { doc.page(at: $0) }), to: url)
            outputs.append(url)
        }
        return outputs
    }

    // MARK: Extraire / supprimer / pivoter

    /// Garde uniquement les pages indiquées (dans l'ordre donné, ex. "3,1,2" réordonne).
    @discardableResult
    public static func extract(_ input: URL, pages text: String, to output: URL) throws -> Int {
        let doc = try open(input)
        let idx = try PageRanges.indices(text, pageCount: doc.pageCount)
        let out = makeDocument(from: idx.compactMap { doc.page(at: $0) })
        try save(out, to: output)
        return out.pageCount
    }

    @discardableResult
    public static func delete(_ input: URL, pages text: String, to output: URL) throws -> Int {
        let doc = try open(input)
        let remove = Set(try PageRanges.indices(text, pageCount: doc.pageCount))
        let keep = (0..<doc.pageCount).filter { !remove.contains($0) }
        let out = makeDocument(from: keep.compactMap { doc.page(at: $0) })
        try save(out, to: output)
        return out.pageCount
    }

    public static func rotate(_ input: URL, degrees: Int, pages text: String?, to output: URL) throws {
        let doc = try open(input)
        let targets: [Int]
        if let text = text, !text.isEmpty {
            targets = try PageRanges.indices(text, pageCount: doc.pageCount)
        } else {
            targets = Array(0..<doc.pageCount)
        }
        for i in Set(targets) {
            guard let p = doc.page(at: i) else { continue }
            p.rotation = ((p.rotation + degrees) % 360 + 360) % 360
        }
        try save(doc, to: output)
    }

    // MARK: Infos

    public static func info(_ url: URL) throws -> [(String, String)] {
        guard let doc = PDFDocument(url: url) else { throw PDFToolError.cannotOpen(url) }
        let attrs = doc.documentAttributes ?? [:]
        func attr(_ key: PDFDocumentAttribute) -> String {
            (attrs[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        }
        var rows: [(String, String)] = [
            ("Fichier", url.lastPathComponent),
            ("Taille", FileUtils.formatBytes(FileUtils.size(url))),
            ("Pages", doc.isLocked ? "? (verrouillé)" : "\(doc.pageCount)"),
            ("Version PDF", "\(doc.majorVersion).\(doc.minorVersion)"),
            ("Chiffré", doc.isEncrypted ? "oui" : "non"),
            ("Titre", attr(.titleAttribute)),
            ("Auteur", attr(.authorAttribute)),
            ("Créateur", attr(.creatorAttribute)),
            ("Producteur", attr(.producerAttribute)),
        ]
        if let first = doc.page(at: 0) {
            let b = first.bounds(for: .mediaBox)
            let mm = { (pt: CGFloat) in Int((pt / 72 * 25.4).rounded()) }
            rows.append(("Format page 1", "\(mm(b.width)) × \(mm(b.height)) mm"))
        }
        return rows
    }
}
