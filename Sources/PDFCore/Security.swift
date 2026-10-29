import Foundation
import PDFKit

// MARK: - Mot de passe

public enum Security {

    /// Chiffre le PDF : `password` est demandé à l'ouverture.
    public static func protect(_ input: URL, password: String, to output: URL) throws {
        guard !password.isEmpty else { throw PDFToolError.wrongPassword }
        let doc = try PDFOps.open(input)
        let tmp = FileUtils.temporarySibling(of: output)
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: password,
        ]
        guard doc.write(to: tmp, withOptions: options) else {
            try? FileManager.default.removeItem(at: tmp)
            throw PDFToolError.cannotWrite(output)
        }
        try FileUtils.replace(output, with: tmp)
    }

    /// Enlève le mot de passe (il faut le connaître).
    public static func unlock(_ input: URL, password: String, to output: URL) throws {
        guard let doc = PDFDocument(url: input) else { throw PDFToolError.cannotOpen(input) }
        if doc.isLocked && !doc.unlock(withPassword: password) {
            throw PDFToolError.wrongPassword
        }
        // Recopier les pages dans un document neuf = plus aucun chiffrement.
        let clean = PDFOps.makeDocument(from: PDFOps.pages(of: doc))
        clean.documentAttributes = doc.documentAttributes
        try PDFOps.save(clean, to: output)
    }

    public static func isEncrypted(_ url: URL) -> Bool {
        PDFDocument(url: url)?.isEncrypted ?? false
    }
}

// MARK: - Métadonnées

public struct PDFMetadata: Equatable {
    public var title = ""
    public var author = ""
    public var subject = ""
    public var keywords = ""
    public init() {}
}

public enum Metadata {

    public static func read(_ url: URL) throws -> PDFMetadata {
        let doc = try PDFOps.open(url)
        let attrs = doc.documentAttributes ?? [:]
        var m = PDFMetadata()
        m.title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        m.author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""
        m.subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        if let list = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            m.keywords = list.joined(separator: ", ")
        } else {
            m.keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? String ?? ""
        }
        return m
    }

    public static func write(_ m: PDFMetadata, _ input: URL, to output: URL) throws {
        let doc = try PDFOps.open(input)
        var attrs = doc.documentAttributes ?? [:]
        func set(_ key: PDFDocumentAttribute, _ value: Any?) {
            attrs[AnyHashable(key)] = value
        }
        let clean = { (s: String) -> String? in
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        set(.titleAttribute, clean(m.title))
        set(.authorAttribute, clean(m.author))
        set(.subjectAttribute, clean(m.subject))
        let keywords = m.keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        set(.keywordsAttribute, keywords.isEmpty ? nil : keywords)
        doc.documentAttributes = attrs
        try PDFOps.save(doc, to: output)
    }

    /// Métadonnées sous forme simple, pour les PDF réécrits avec CoreGraphics.
    public static func info(of doc: PDFDocument) -> [String: String] {
        let attrs = doc.documentAttributes ?? [:]
        var info: [String: String] = [:]
        if let v = attrs[PDFDocumentAttribute.titleAttribute] as? String { info["title"] = v }
        if let v = attrs[PDFDocumentAttribute.authorAttribute] as? String { info["author"] = v }
        if let v = attrs[PDFDocumentAttribute.subjectAttribute] as? String { info["subject"] = v }
        if let v = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] { info["keywords"] = v.joined(separator: ", ") }
        return info
    }
}
