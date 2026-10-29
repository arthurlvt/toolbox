import Foundation
import PDFKit

// MARK: - Export pour RAG

public enum RAGFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case jsonl = "JSONL (une ligne par page)"

    public var id: String { rawValue }
    public var fileExtension: String { self == .markdown ? "md" : "jsonl" }
}

/// Export du texte d'un PDF dans un format facile à découper et indexer :
/// chaque page garde sa source et son numéro (utile pour citer les sources).
public enum RAGExport {

    public static func cleaned(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\u{00AD}", with: "")   // tirets conditionnels
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Mots coupés en fin de ligne : « algo-\nrithme » → « algorithme »
        t = t.replacingOccurrences(of: #"(\p{L})-\n(\p{Ll})"#, with: "$1$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renvoie le nombre de pages contenant du texte.
    @discardableResult
    public static func export(_ input: URL, format: RAGFormat, to output: URL) throws -> Int {
        let doc = try PDFOps.open(input)
        let title = Metadata.info(of: doc)["title"] ?? input.deletingPathExtension().lastPathComponent
        let total = doc.pageCount
        var withText = 0
        var out = ""

        if format == .markdown {
            out += "# \(title)\n\n> Source : \(input.lastPathComponent) — \(total) pages\n"
        }
        for i in 0..<total {
            let text = cleaned(doc.page(at: i)?.string ?? "")
            if !text.isEmpty { withText += 1 }
            switch format {
            case .markdown:
                out += "\n## Page \(i + 1)\n\n\(text.isEmpty ? "_(page sans texte)_" : text)\n"
            case .jsonl:
                guard !text.isEmpty else { continue }
                let record: [String: Any] = [
                    "source": input.lastPathComponent,
                    "path": input.path,
                    "title": title,
                    "page": i + 1,
                    "pages": total,
                    "chars": text.count,
                    "text": text,
                ]
                let data = try JSONSerialization.data(withJSONObject: record,
                                                      options: [.sortedKeys, .withoutEscapingSlashes])
                out += String(decoding: data, as: UTF8.self) + "\n"
            }
        }
        do {
            try out.write(to: output, atomically: true, encoding: .utf8)
        } catch {
            throw PDFToolError.cannotWrite(output)
        }
        return withText
    }
}

// MARK: - Traitement par lots

public struct BatchOptions {
    public var ocr = false
    public var stamp = StampOptions()
    public var compression: CompressionLevel?
    public var metadata: PDFMetadata?
    /// {nom} = nom d'origine, {n} = numéro dans le lot, {date} = date du jour (AAAA-MM-JJ).
    public var renamePattern = "{nom}"

    public init() {}

    public var stepCount: Int {
        (ocr ? 1 : 0) + (stamp.isEmpty ? 0 : 1) + (compression == nil ? 0 : 1) + (metadata == nil ? 0 : 1)
    }
}

public struct BatchItemResult {
    public let input: URL
    public let output: URL?
    public let error: String?
}

public enum Batch {

    public static func outputName(for input: URL, pattern: String, index: Int, total: Int) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let width = max(2, String(total).count)
        let n = String(index)
        let padded = String(repeating: "0", count: max(0, width - n.count)) + n
        var name = (pattern.isEmpty ? "{nom}" : pattern)
            .replacingOccurrences(of: "{nom}", with: input.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "{n}", with: padded)
            .replacingOccurrences(of: "{date}", with: df.string(from: Date()))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return name.hasSuffix(".pdf") ? name : name + ".pdf"
    }

    /// Applique dans l'ordre : OCR → numérotation/filigrane → métadonnées → compression.
    /// Les originaux ne sont jamais modifiés ; les résultats vont dans `folder`.
    public static func run(_ inputs: [URL], options: BatchOptions, into folder: URL,
                           progress: ((Int, Int, String) -> Void)? = nil) -> [BatchItemResult] {
        var results: [BatchItemResult] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return inputs.map { BatchItemResult(input: $0, output: nil, error: "Dossier de sortie impossible à créer.") }
        }

        for (i, input) in inputs.enumerated() {
            progress?(i + 1, inputs.count, input.lastPathComponent)
            let out = FileUtils.unique(folder.appendingPathComponent(
                outputName(for: input, pattern: options.renamePattern, index: i + 1, total: inputs.count)))
            var current = input
            var temps: [URL] = []

            func step(_ work: (URL, URL) throws -> Void) throws {
                let next = FileUtils.temporarySibling(of: out)
                try work(current, next)
                temps.append(next)
                current = next
            }

            do {
                if options.ocr {
                    try step { _ = try OCR.makeSearchable($0, to: $1) }
                }
                if !options.stamp.isEmpty {
                    let s = options.stamp
                    try step { _ = try Stamper.stamp($0, options: s, to: $1) }
                }
                if let m = options.metadata {
                    try step { (src: URL, dst: URL) in
                        // On complète les infos existantes au lieu de les écraser.
                        var merged = (try? Metadata.read(src)) ?? PDFMetadata()
                        if !m.title.isEmpty { merged.title = m.title }
                        if !m.author.isEmpty { merged.author = m.author }
                        if !m.subject.isEmpty { merged.subject = m.subject }
                        if !m.keywords.isEmpty { merged.keywords = m.keywords }
                        try Metadata.write(merged, src, to: dst)
                    }
                }
                if let level = options.compression {
                    try step { _ = try Compressor.compress($0, level: level, to: $1) }
                }
                if current == input {
                    try FileManager.default.copyItem(at: input, to: out)
                } else {
                    try FileManager.default.moveItem(at: current, to: out)
                    temps.removeAll { $0 == current }
                }
                results.append(BatchItemResult(input: input, output: out, error: nil))
            } catch {
                results.append(BatchItemResult(input: input, output: nil, error: error.localizedDescription))
            }
            for t in temps { try? FileManager.default.removeItem(at: t) }
        }
        return results
    }
}
