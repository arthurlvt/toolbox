import Foundation
import PDFKit
import Vision

public struct OCROptions {
    /// Langues reconnues, par ordre de priorité.
    public var languages = ["fr-FR", "en-US"]
    /// Ne pas refaire l'OCR des pages qui contiennent déjà du texte.
    public var skipPagesWithText = true
    /// Résolution de l'analyse (300 dpi = bon compromis).
    public var dpi = 300.0

    public init() {}
}

public struct OCRResult {
    public let pages: Int
    public let recognizedPages: Int
    public let characters: Int
}

/// OCR 100 % local avec le framework Vision d'Apple.
/// Le résultat garde l'aspect exact de l'original et ajoute une couche de texte
/// invisible : le PDF devient cherchable et le texte copiable.
public enum OCR {

    public static func recognize(_ image: CGImage, languages: [String]) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    @discardableResult
    public static func makeSearchable(_ input: URL, options: OCROptions = OCROptions(), to output: URL,
                                      progress: ((Int, Int) -> Void)? = nil) throws -> OCRResult {
        let doc = try PDFOps.open(input)
        let count = doc.pageCount
        var recognizedPages = 0
        var characters = 0

        try PageDrawing.rewrite(to: output, info: Metadata.info(of: doc)) { writer in
            for i in 0..<count {
                guard let page = doc.page(at: i) else { continue }
                progress?(i + 1, count)
                let size = PageDrawing.displaySize(page)

                var lines: [(text: String, rect: CGRect)] = []
                let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let needsOCR = !(options.skipPagesWithText && existing.count > 30)
                if needsOCR, let image = Converter.render(page, dpi: options.dpi) {
                    for obs in try recognize(image, languages: options.languages) {
                        guard let candidate = obs.topCandidates(1).first else { continue }
                        let b = obs.boundingBox // normalisé, origine en bas à gauche
                        let rect = CGRect(x: b.minX * size.width, y: b.minY * size.height,
                                          width: b.width * size.width, height: b.height * size.height)
                        lines.append((candidate.string, rect))
                        characters += candidate.string.count
                    }
                    if !lines.isEmpty { recognizedPages += 1 }
                }

                writer.page(size: size) { ctx in
                    PageDrawing.drawUpright(page, in: ctx)
                    for line in lines {
                        PageDrawing.drawInvisibleText(line.text, in: ctx, rect: line.rect)
                    }
                }
            }
        }
        return OCRResult(pages: count, recognizedPages: recognizedPages, characters: characters)
    }

    /// Texte brut d'une image ou d'un scan (sans créer de PDF).
    public static func text(of image: CGImage, languages: [String] = ["fr-FR", "en-US"]) throws -> String {
        try recognize(image, languages: languages)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
