import Foundation
import AppKit
import PDFKit
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Phase 1 — Lecture : texte de chaque page, confiance et pages douteuses.
/// Équivalent de annalyse/extraction.py, avec le moteur Vision d'Apple à la place de Tesseract.
public struct TextExtraction: Codable {
    public var pages: [String]
    public var confiance: Double                 // 100 = texte natif
    public var pagesDouteuses: [Int] = []        // numéros à partir de 1
    /// Pages dont le texte vient du fichier lui-même (pas de l'OCR).
    public var pagesNatives: [Bool] = []
    /// Toutes les pages sont des images (scan, éventuellement déjà passé à l'OCR).
    public var toutesPagesImages = false

    public var texte: String { pages.joined(separator: "\n\u{0C}\n") }
    public var aVerifier: Bool { !pagesDouteuses.isEmpty }
}

public enum DepositKind: String, Codable {
    case pdf, image, document

    public static func of(_ url: URL) -> DepositKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if AnnalesExtractor.imageExtensions.contains(ext) { return .image }
        if AnnalesExtractor.documentExtensions.contains(ext) { return .document }
        return nil
    }
}

public enum AnnalesExtractor {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "bmp", "heic", "heif", "webp", "gif"]
    public static let documentExtensions: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd", "txt", "md", "tex", "html", "htm"]
    public static var supportedExtensions: Set<String> { imageExtensions.union(documentExtensions).union(["pdf"]) }

    static let seuilPageScannee = 50      // moins de 50 caractères lisibles = page scannée
    static let seuilConfiance = 60.0      // en dessous : page à vérifier
    static let versionCache = 2

    // MARK: Point d'entrée

    /// Extrait le texte d'un dépôt (avec cache par empreinte).
    public static func extract(_ url: URL, sha: String, languages: [String] = ["fr-FR", "en-US"],
                               useCache: Bool = true) throws -> TextExtraction {
        let cache = cacheURL(sha)
        if useCache, let data = try? Data(contentsOf: cache),
           let cached = try? JSONDecoder().decode(TextExtraction.self, from: data) {
            return cached
        }
        let result: TextExtraction
        switch DepositKind.of(url) {
        case .pdf: result = try extractPDF(url, languages: languages)
        case .image: result = try extractImage(url, languages: languages)
        case .document: result = try extractDocument(url)
        case .none: throw PDFToolError.commandFailed("format non pris en charge : .\(url.pathExtension)")
        }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: cache) }
        return result
    }

    static func cacheURL(_ sha: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("fr.arthur.toolbox/annales/\(sha).v\(versionCache).json")
    }

    // MARK: PDF

    static func extractPDF(_ url: URL, languages: [String]) throws -> TextExtraction {
        let doc = try PDFOps.open(url)
        var pages: [String] = []
        var confiances: [Double] = []
        var douteuses: [Int] = []
        var natives: [Bool] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let natif = AnnalesText.nettoyer(page.string ?? "")
            if natif.trimmingCharacters(in: .whitespacesAndNewlines).count >= seuilPageScannee {
                pages.append(natif)
                confiances.append(100)
                natives.append(true)
            } else if let image = Converter.render(page, dpi: 300) {
                // Un scanner rend des pages droites : on n'essaie les 4 sens que si la lecture est vide.
                let (texte, conf) = ocrPage(image, numero: i + 1, douteuses: &douteuses,
                                            languages: languages, essayerRotations: false)
                pages.append(texte)
                confiances.append(conf)
                natives.append(false)
            } else {
                pages.append("")
                confiances.append(0)
                douteuses.append(i + 1)
                natives.append(false)
            }
        }
        let moyenne = confiances.isEmpty ? 0 : confiances.reduce(0, +) / Double(confiances.count)
        var result = TextExtraction(pages: pages, confiance: moyenne, pagesDouteuses: douteuses, pagesNatives: natives)
        result.toutesPagesImages = doc.pageCount > 0
            && (0..<doc.pageCount).allSatisfy { i in doc.page(at: i).map(pageHasImages) ?? false }
        return result
    }

    // MARK: Images (photos, scans)

    static func extractImage(_ url: URL, languages: [String]) throws -> TextExtraction {
        guard let image = loadImage(url) else { throw PDFToolError.imageUnreadable(url) }
        var douteuses: [Int] = []
        let prepared = straighten(image)
        let (texte, conf) = ocrPage(prepared, numero: 1, douteuses: &douteuses,
                                    languages: languages, essayerRotations: true)
        return TextExtraction(pages: [texte], confiance: conf, pagesDouteuses: douteuses, pagesNatives: [false])
    }

    /// Charge une image en appliquant l'orientation EXIF (photo de téléphone tenue de travers).
    public static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Détecte la feuille dans une photo et la remet à plat (perspective).
    public static func straighten(_ image: CGImage) -> CGImage {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let doc = request.results?.first, doc.confidence > 0.6 else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func pt(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        // Si la feuille occupe déjà presque toute l'image, inutile de la recadrer.
        let area = doc.boundingBox.width * doc.boundingBox.height
        guard area < 0.92 else { return image }
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(pt(doc.topLeft), forKey: "inputTopLeft")
        filter.setValue(pt(doc.topRight), forKey: "inputTopRight")
        filter.setValue(pt(doc.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(pt(doc.bottomRight), forKey: "inputBottomRight")
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return image }
        return cg
    }

    static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        guard degrees % 360 != 0 else { return image }
        let swap = degrees % 180 != 0
        let w = swap ? image.height : image.width
        let h = swap ? image.width : image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    // MARK: OCR

    struct OCRRead {
        let texte: String
        let confiance: Double     // 0-100
        let score: Double         // lisibilité : somme des confiances × longueur
    }

    static func read(_ image: CGImage, languages: [String]) -> OCRRead {
        guard let observations = try? OCR.recognize(image, languages: languages), !observations.isEmpty else {
            return OCRRead(texte: "", confiance: 0, score: 0)
        }
        // Lignes de haut en bas ; une ligne vide quand l'écart vertical est grand (nouveau paragraphe).
        let lines = observations.compactMap { obs -> (String, CGRect, Float)? in
            guard let c = obs.topCandidates(1).first else { return nil }
            return (c.string, obs.boundingBox, c.confidence)
        }.sorted { a, b in
            abs(a.1.midY - b.1.midY) < min(a.1.height, b.1.height) * 0.5 ? a.1.minX < b.1.minX : a.1.midY > b.1.midY
        }
        var out: [String] = []
        var previous: CGRect?
        var total = 0.0, weights = 0.0
        for (text, box, conf) in lines {
            if let p = previous, p.minY - box.maxY > max(p.height, box.height) * 1.2 { out.append("") }
            out.append(text)
            previous = box
            total += Double(conf) * Double(text.count)
            weights += Double(text.count)
        }
        let confiance = weights > 0 ? total / weights * 100 : 0
        return OCRRead(texte: out.joined(separator: "\n"), confiance: confiance, score: total)
    }

    /// OCR d'une page ; ajoute son numéro aux pages douteuses si la lecture est mauvaise.
    static func ocrPage(_ image: CGImage, numero: Int, douteuses: inout [Int], languages: [String],
                        essayerRotations: Bool) -> (String, Double) {
        var best = read(image, languages: languages)
        let mauvaise = best.confiance < seuilConfiance || best.texte.count < seuilPageScannee
        if mauvaise && (essayerRotations || best.texte.count < seuilPageScannee) {
            // Plan B : les 3 autres sens sur une copie réduite, on garde le plus lisible.
            for angle in [90, 180, 270] {
                guard let turned = rotate(image, degrees: angle) else { continue }
                let r = read(turned, languages: languages)
                if r.score > best.score * 1.15 { best = r }
            }
        }
        var texte = AnnalesText.nettoyer(best.texte)
        if best.confiance < seuilConfiance || texte.trimmingCharacters(in: .whitespacesAndNewlines).count < seuilPageScannee {
            douteuses.append(numero)
            texte = "[PAGE \(numero) : LECTURE INCERTAINE, confiance \(Int(best.confiance)) %, à vérifier sur l'original]\n" + texte
        }
        return (texte, best.confiance)
    }

    // MARK: Documents texte (Word, OpenDocument, RTF, Markdown, LaTeX…)

    static func extractDocument(_ url: URL) throws -> TextExtraction {
        let ext = url.pathExtension.lowercased()
        let text: String
        if ["txt", "md", "tex"].contains(ext) {
            text = try String(contentsOf: url, encoding: .utf8)
        } else {
            let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            text = attributed.string
        }
        let clean = AnnalesText.nettoyer(text)
        // Un saut de page explicite (\f) découpe en pages ; sinon une seule « page ».
        let pages = text.contains("\u{0C}")
            ? text.components(separatedBy: "\u{0C}").map(AnnalesText.nettoyer)
            : [clean]
        return TextExtraction(pages: pages, confiance: 100, pagesDouteuses: [],
                              pagesNatives: Array(repeating: true, count: pages.count))
    }

    // MARK: Version PDF du dépôt

    /// PDF de travail : le PDF lui-même, la photo redressée en PDF, ou rien pour un document texte.
    public static func workingPDF(for url: URL, in folder: URL) throws -> URL? {
        switch DepositKind.of(url) {
        case .pdf:
            return url
        case .image:
            guard let image = loadImage(url) else { throw PDFToolError.imageUnreadable(url) }
            let straight = straighten(image)
            let ns = NSImage(cgImage: straight, size: NSSize(width: straight.width, height: straight.height))
            let doc = PDFDocument()
            let landscape = straight.width > straight.height
            let box = landscape ? CGRect(x: 0, y: 0, width: 842, height: 595) : CGRect(x: 0, y: 0, width: 595, height: 842)
            if let page = PDFPage(image: ns, options: [.mediaBox: NSValue(rect: box), .compressionQuality: 0.8]) {
                doc.insert(page, at: 0)
            }
            let out = folder.appendingPathComponent("original.pdf")
            try PDFOps.save(doc, to: out)
            return out
        default:
            return nil
        }
    }

    /// Le PDF contient-il des images (scan) ? Sert à repérer les pages manuscrites.
    public static func pageHasImages(_ page: PDFPage) -> Bool {
        guard let dict = page.pageRef?.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let res = resources else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xo = xobjects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(xo, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let s = stream, let sd = CGPDFStreamGetDictionary(s) {
                var name: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(sd, "Subtype", &name), let n = name, String(cString: n) == "Image" {
                    found = true
                    return false
                }
            }
            return true
        }, nil)
        return found
    }

    /// Images JPEG (base64) des pages, pour un modèle d'IA qui sait lire les images.
    public static func pageImagesBase64(pdf: URL?, image: URL?, pages: ClosedRange<Int>?, maxPages: Int = 4,
                                        maxSide: CGFloat = 1600) -> [String] {
        var images: [CGImage] = []
        if let pdf = pdf, let doc = PDFDocument(url: pdf) {
            let range = pages ?? 1...max(1, doc.pageCount)
            for n in range.prefix(maxPages) {
                guard let page = doc.page(at: n - 1) else { continue }
                let size = PageDrawing.displaySize(page)
                let dpi = Double(72 * maxSide / max(size.width, size.height))
                if let img = Converter.render(page, dpi: min(dpi, 200)) { images.append(img) }
            }
        } else if let image = image, let img = loadImage(image) {
            images.append(straighten(img))
        }
        return images.compactMap { jpegBase64($0) }
    }

    static func jpegBase64(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
