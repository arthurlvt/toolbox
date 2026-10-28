import Foundation
import PDFKit

public enum StampPosition: String, CaseIterable, Identifiable {
    case bottomCenter = "En bas au centre"
    case bottomRight = "En bas à droite"
    case bottomLeft = "En bas à gauche"
    case topCenter = "En haut au centre"
    case topRight = "En haut à droite"

    public var id: String { rawValue }
}

/// Numérotation, en-tête, pied de page et filigrane.
/// Dans les textes : {n} = numéro, {total} = dernier numéro, {fichier} = nom du fichier, {date} = date du jour.
public struct StampOptions {
    public var numbering = false
    public var numberFormat = "{n} / {total}"
    public var numberPosition: StampPosition = .bottomCenter
    public var firstNumber = 1
    public var skipFirstPage = false
    public var header = ""
    public var footer = ""
    public var watermark = ""
    public var watermarkOpacity = 0.15
    public var fontSize = 10.0

    public init() {}

    public var isEmpty: Bool {
        !numbering
            && header.trimmingCharacters(in: .whitespaces).isEmpty
            && footer.trimmingCharacters(in: .whitespaces).isEmpty
            && watermark.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public enum Stamper {

    @discardableResult
    public static func stamp(_ input: URL, options o: StampOptions, to output: URL) throws -> Int {
        let doc = try PDFOps.open(input)
        let count = doc.pageCount
        let file = input.deletingPathExtension().lastPathComponent
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateFormat = "dd/MM/yyyy"
        let date = df.string(from: Date())
        let numbered = o.skipFirstPage ? max(0, count - 1) : count
        let lastNumber = o.firstNumber + numbered - 1

        try PageDrawing.rewrite(to: output, info: Metadata.info(of: doc)) { writer in
            for i in 0..<count {
                guard let page = doc.page(at: i) else { continue }
                let size = PageDrawing.displaySize(page)
                let isNumbered = !(o.skipFirstPage && i == 0)
                let n = o.firstNumber + i - (o.skipFirstPage ? 1 : 0)
                func expand(_ s: String) -> String {
                    s.replacingOccurrences(of: "{n}", with: "\(n)")
                        .replacingOccurrences(of: "{total}", with: "\(lastNumber)")
                        .replacingOccurrences(of: "{fichier}", with: file)
                        .replacingOccurrences(of: "{date}", with: date)
                }
                writer.page(size: size) { ctx in
                    PageDrawing.drawUpright(page, in: ctx)
                    overlay(ctx, size: size, options: o, numbered: isNumbered, expand: expand)
                }
            }
        }
        return count
    }

    /// Aperçu de la première page tamponnée (pour l'interface).
    public static func preview(_ input: URL, options o: StampOptions, maxSize: CGFloat = 520) -> CGImage? {
        guard let doc = PDFDocument(url: input), !doc.isLocked else { return nil }
        let index = (o.skipFirstPage && doc.pageCount > 1) ? 1 : 0
        guard let page = doc.page(at: index) else { return nil }
        let size = PageDrawing.displaySize(page)
        let scale = maxSize / max(size.width, size.height)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        PageDrawing.drawUpright(page, in: ctx)
        let numbered = o.skipFirstPage ? max(0, doc.pageCount - 1) : doc.pageCount
        let n = o.firstNumber + index - (o.skipFirstPage ? 1 : 0)
        let last = o.firstNumber + numbered - 1
        let file = input.deletingPathExtension().lastPathComponent
        let df = DateFormatter()
        df.dateFormat = "dd/MM/yyyy"
        let date = df.string(from: Date())
        overlay(ctx, size: size, options: o, numbered: !(o.skipFirstPage && index == 0)) { s in
            s.replacingOccurrences(of: "{n}", with: "\(n)")
                .replacingOccurrences(of: "{total}", with: "\(last)")
                .replacingOccurrences(of: "{fichier}", with: file)
                .replacingOccurrences(of: "{date}", with: date)
        }
        return ctx.makeImage()
    }

    private static func overlay(_ ctx: CGContext, size: CGSize, options o: StampOptions,
                                numbered: Bool, expand: (String) -> String) {
        let w = size.width
        let h = size.height
        let fs = CGFloat(o.fontSize)
        let margin = max(18, min(w, h) * 0.045)
        let ink = CGColor(gray: 0.2, alpha: 1)

        // Filigrane en diagonale.
        let wm = o.watermark.trimmingCharacters(in: .whitespaces)
        if !wm.isEmpty {
            let text = expand(wm)
            let diagonal = hypot(w, h)
            let base = PageDrawing.textWidth(text, size: 100, bold: true)
            let size = min(220, 100 * diagonal * 0.7 / max(base, 1))
            let alpha = CGFloat(min(max(o.watermarkOpacity, 0.03), 1))
            PageDrawing.drawText(text, in: ctx, at: CGPoint(x: w / 2, y: h / 2), size: size,
                                 color: CGColor(red: 0.75, green: 0.1, blue: 0.15, alpha: alpha),
                                 bold: true, anchor: .center, angle: atan2(h, w), baselineOffset: -size * 0.35)
        }

        // En-tête (centré) et pied de page (à gauche).
        let header = o.header.trimmingCharacters(in: .whitespaces)
        if !header.isEmpty {
            PageDrawing.drawText(expand(header), in: ctx, at: CGPoint(x: w / 2, y: h - margin - fs * 0.3),
                                 size: fs, color: ink, anchor: .center)
        }
        let footer = o.footer.trimmingCharacters(in: .whitespaces)
        if !footer.isEmpty {
            PageDrawing.drawText(expand(footer), in: ctx, at: CGPoint(x: margin, y: margin),
                                 size: fs, color: ink, anchor: .left)
        }

        // Numéro de page.
        if o.numbering && numbered {
            let text = expand(o.numberFormat.isEmpty ? "{n}" : o.numberFormat)
            let top = h - margin - fs * 0.3
            let point: CGPoint
            let anchor: PageDrawing.Anchor
            switch o.numberPosition {
            case .bottomCenter: point = CGPoint(x: w / 2, y: margin); anchor = .center
            case .bottomRight: point = CGPoint(x: w - margin, y: margin); anchor = .right
            case .bottomLeft: point = CGPoint(x: margin, y: margin); anchor = .left
            case .topCenter: point = CGPoint(x: w / 2, y: top); anchor = .center
            case .topRight: point = CGPoint(x: w - margin, y: top); anchor = .right
            }
            PageDrawing.drawText(text, in: ctx, at: point, size: fs, color: ink, anchor: anchor)
        }
    }
}
