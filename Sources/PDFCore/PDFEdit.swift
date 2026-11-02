import Foundation
import AppKit
import PDFKit
import Vision

/// Enregistrement de l'éditeur de PDF : les annotations (texte ajouté, surlignage, dessins, images…)
/// sont dessinées dans le contenu des pages (« aplaties »), comme une impression.
public enum PDFEdit {

    public struct Result {
        public let pages: Int
        public let redactedPages: Int
    }

    /// Nom PDFKit du type sans la barre oblique (« FreeText », « Link »…).
    public static func kind(_ a: PDFAnnotation) -> String {
        (a.type ?? "").replacingOccurrences(of: "/", with: "")
    }

    /// Annotations qu'on ne dessine pas : liens (invisibles) et bulles des notes.
    static func drawable(_ a: PDFAnnotation) -> Bool {
        let k = kind(a)
        return a.shouldDisplay && k != "Link" && k != "Popup"
    }

    /// Écrit une copie aplatie de `doc`.
    /// - redact : les annotations qui *cachent* quelque chose (caches blancs). Sur leurs pages, le texte d'origine
    ///   est vraiment supprimé : la page est recréée en image (`dpi`), avec une couche de texte OCR invisible
    ///   pour qu'elle reste cherchable, puis le reste des annotations est posé par-dessus en vectoriel.
    ///   Les autres pages restent vectorielles (texte sélectionnable).
    @discardableResult
    public static func flatten(_ doc: PDFDocument, to output: URL, dpi: Double = 220,
                               redact: (PDFAnnotation) -> Bool = { _ in false },
                               progress: ((Int, Int) -> Void)? = nil) throws -> Result {
        let count = doc.pageCount
        var redacted = 0
        try PageDrawing.rewrite(to: output, info: Metadata.info(of: doc)) { writer in
            for i in 0..<count {
                guard let page = doc.page(at: i) else { continue }
                progress?(i + 1, count)
                let size = PageDrawing.displaySize(page)
                let annots = page.annotations.filter(drawable)
                let hiding = annots.filter(redact)

                if hiding.isEmpty {
                    writer.page(size: size) { ctx in
                        draw(page, annotations: annots, in: ctx, content: true)
                    }
                    continue
                }

                // Page avec caches : image (contenu + caches) + OCR invisible + annotations vectorielles.
                redacted += 1
                let k = dpi / 72
                let w = Int((size.width * k).rounded()), h = Int((size.height * k).rounded())
                var image: CGImage?
                if w > 0, h > 0, let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                    bmp.setFillColor(CGColor(gray: 1, alpha: 1))
                    bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    bmp.scaleBy(x: CGFloat(k), y: CGFloat(k))
                    bmp.interpolationQuality = .high
                    draw(page, annotations: hiding, in: bmp, content: true)
                    image = bmp.makeImage()
                }
                var lines: [(String, CGRect)] = []
                if let img = image, let found = try? OCR.recognize(img, languages: ["fr-FR", "en-US"]) {
                    for obs in found {
                        guard let c = obs.topCandidates(1).first else { continue }
                        let b = obs.boundingBox
                        lines.append((c.string, CGRect(x: b.minX * size.width, y: b.minY * size.height,
                                                       width: b.width * size.width, height: b.height * size.height)))
                    }
                }
                let others = annots.filter { a in !hiding.contains { $0 === a } }
                writer.page(size: size) { ctx in
                    if let img = image {
                        ctx.interpolationQuality = .high
                        ctx.draw(img, in: CGRect(origin: .zero, size: size))
                    }
                    for (text, rect) in lines { PageDrawing.drawInvisibleText(text, in: ctx, rect: rect) }
                    draw(page, annotations: others, in: ctx, content: false)
                }
            }
        }
        // liens (web et internes) et sommaire : remis par-dessus la copie
        try? PDFLinks.restore(from: doc, into: output)
        return Result(pages: count, redactedPages: redacted)
    }

    /// Dessine la page (si `content`) puis les annotations, à l'endroit, dans (0, 0, displaySize).
    static func draw(_ page: PDFPage, annotations: [PDFAnnotation], in ctx: CGContext, content: Bool) {
        ctx.saveGState()
        page.transform(ctx, for: .cropBox)
        ctx.clip(to: page.bounds(for: .cropBox))
        if content {
            if let ref = page.pageRef {
                ctx.drawPDFPage(ref)
            } else {
                page.draw(with: .cropBox, to: ctx)
            }
        }
        // Certaines annotations (texte) dessinent via AppKit : on lui donne le contexte.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for a in annotations {
            ctx.saveGState()
            a.draw(with: .cropBox, in: ctx)
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// Enregistre le document en gardant les annotations modifiables (Aperçu, Acrobat…).
    public static func saveEditable(_ doc: PDFDocument, to output: URL) throws {
        let tmp = FileUtils.temporarySibling(of: output)
        guard doc.write(to: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            throw PDFToolError.cannotWrite(output)
        }
        try FileUtils.replace(output, with: tmp)
    }

    /// Page blanche de la taille donnée (pour l'insérer dans un document).
    public static func blankPage(size: CGSize) -> PDFPage? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
