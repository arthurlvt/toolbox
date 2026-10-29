import Foundation
import PDFKit
import CoreText

/// Outils de dessin bas niveau partagés par la numérotation, le filigrane,
/// l'OCR, la mise en page et le rendu en images.
///
/// Convention : une page est toujours manipulée « à l'endroit », telle qu'on la
/// voit à l'écran (rotation appliquée, cropBox), coin bas-gauche en (0, 0).
public enum PageDrawing {

    public static func rotation(_ page: PDFPage) -> Int {
        ((page.rotation % 360) + 360) % 360
    }

    /// Taille affichée de la page (cropBox, rotation comprise), en points.
    public static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return rotation(page) % 180 == 90 ? CGSize(width: b.height, height: b.width) : b.size
    }

    /// Dessine la page à l'endroit dans le rectangle (0, 0, displaySize).
    public static func drawUpright(_ page: PDFPage, in ctx: CGContext) {
        let box = page.bounds(for: .cropBox)
        ctx.saveGState()
        switch rotation(page) {
        case 90:
            ctx.translateBy(x: 0, y: box.width)
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: box.width, y: box.height)
            ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: box.height, y: 0)
            ctx.rotate(by: .pi / 2)
        default:
            break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.clip(to: box)
        if let ref = page.pageRef {
            ctx.drawPDFPage(ref)
        } else {
            page.draw(with: .cropBox, to: ctx)
        }
        ctx.restoreGState()
    }

    /// Dessine la page réduite et centrée dans `rect` (pour 2/4 pages par feuille, livret).
    public static func drawFitted(_ page: PDFPage, in rect: CGRect, ctx: CGContext, border: Bool = false) {
        let s = displaySize(page)
        guard s.width > 0, s.height > 0 else { return }
        let k = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * k
        let h = s.height * k
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - w / 2, y: rect.midY - h / 2)
        ctx.scaleBy(x: k, y: k)
        drawUpright(page, in: ctx)
        ctx.restoreGState()
        if border {
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
            ctx.setLineWidth(0.5)
            ctx.stroke(CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            ctx.restoreGState()
        }
    }

    // MARK: Texte

    public enum Anchor { case left, center, right }

    public static func makeLine(_ text: String, size: CGFloat, color: CGColor, bold: Bool = false) -> CTLine {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs) as CFAttributedString)
    }

    public static func textWidth(_ text: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        let line = makeLine(text, size: size, color: CGColor(gray: 0, alpha: 1), bold: bold)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Dessine du texte ancré en `point` (ligne de base), éventuellement tourné.
    public static func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat,
                                color: CGColor, bold: Bool = false, anchor: Anchor = .center,
                                angle: CGFloat = 0, baselineOffset: CGFloat = 0) {
        guard !text.isEmpty else { return }
        let line = makeLine(text, size: size, color: color, bold: bold)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let dx: CGFloat
        switch anchor {
        case .left: dx = 0
        case .center: dx = -w / 2
        case .right: dx = -w
        }
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: angle)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: dx, y: baselineOffset)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Texte invisible mais sélectionnable / cherchable, étiré pour couvrir `rect` (couche OCR).
    public static func drawInvisibleText(_ text: String, in ctx: CGContext, rect: CGRect) {
        guard rect.width > 1, rect.height > 1, !text.isEmpty else { return }
        let size = rect.height * 0.85
        let line = makeLine(text, size: size, color: CGColor(gray: 0, alpha: 1))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard w > 0 else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.textMatrix = .identity
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.18)
        ctx.scaleBy(x: rect.width / w, y: 1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Écriture d'un nouveau PDF

    /// Écrit un PDF page par page avec CoreGraphics, dans un fichier temporaire
    /// remplacé à la fin (on peut donc écraser le fichier source).
    public static func rewrite(to output: URL, info: [String: String] = [:],
                               _ build: (PDFWriter) throws -> Void) throws {
        let tmp = FileUtils.temporarySibling(of: output)
        do {
            let writer = try PDFWriter(url: tmp, info: info)
            try build(writer)
            writer.close()
            try FileUtils.replace(output, with: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

public final class PDFWriter {
    private let ctx: CGContext
    private var closed = false

    public init(url: URL, info: [String: String] = [:]) throws {
        var aux: [CFString: Any] = [kCGPDFContextCreator: "Toolbox"]
        if let v = info["title"], !v.isEmpty { aux[kCGPDFContextTitle] = v }
        if let v = info["author"], !v.isEmpty { aux[kCGPDFContextAuthor] = v }
        if let v = info["subject"], !v.isEmpty { aux[kCGPDFContextSubject] = v }
        if let v = info["keywords"], !v.isEmpty { aux[kCGPDFContextKeywords] = v }
        guard let c = CGContext(url as CFURL, mediaBox: nil, aux as CFDictionary) else {
            throw PDFToolError.cannotWrite(url)
        }
        ctx = c
    }

    public func page(size: CGSize, _ draw: (CGContext) throws -> Void) rethrows {
        var box = CGRect(origin: .zero, size: size)
        ctx.beginPage(mediaBox: &box)
        defer { ctx.endPage() }
        try draw(ctx)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        ctx.closePDF()
    }

    deinit { close() }
}
