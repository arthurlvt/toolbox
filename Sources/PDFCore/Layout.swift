import Foundation
import PDFKit

public struct Margins: Equatable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public init(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }

    public static func all(_ v: Double) -> Margins { Margins(top: v, bottom: v, left: v, right: v) }
}

public enum SheetLayout: String, CaseIterable, Identifiable {
    case twoUp = "2 pages par feuille"
    case fourUp = "4 pages par feuille"
    case booklet = "Livret (impression recto-verso)"

    public var id: String { rawValue }
}

/// Recadrage et mise en page pour l'impression.
public enum Layout {
    static let a4Portrait = CGSize(width: 595.28, height: 841.89)
    static let a4Landscape = CGSize(width: 841.89, height: 595.28)
    static let mm: Double = 72.0 / 25.4

    // MARK: Recadrer

    /// Rogne chaque bord tel qu'affiché (en mm). Sans perte : seule la cropBox change.
    @discardableResult
    public static func crop(_ input: URL, margins: Margins, pages text: String? = nil, to output: URL) throws -> Int {
        let doc = try PDFOps.open(input)
        let targets = try indices(text, doc.pageCount)
        for i in targets {
            guard let page = doc.page(at: i) else { continue }
            apply(margins, to: page)
        }
        try PDFOps.save(doc, to: output)
        return targets.count
    }

    /// Détecte le contenu de chaque page et retire le blanc autour (en gardant `keepMM` de marge).
    @discardableResult
    public static func autoCrop(_ input: URL, keepMM: Double = 5, pages text: String? = nil, to output: URL) throws -> Int {
        let doc = try PDFOps.open(input)
        var cropped = 0
        for i in try indices(text, doc.pageCount) {
            guard let page = doc.page(at: i), let content = contentBounds(page) else { continue }
            let size = PageDrawing.displaySize(page)
            let keep: Double = keepMM * mm
            let pageW = Double(size.width), pageH = Double(size.height)
            let cMinX = Double(content.minX), cMaxX = Double(content.maxX)
            let cMinY = Double(content.minY), cMaxY = Double(content.maxY)
            let m = Margins(top: max(0.0, (pageH - cMaxY - keep) / mm),
                            bottom: max(0.0, (cMinY - keep) / mm),
                            left: max(0.0, (cMinX - keep) / mm),
                            right: max(0.0, (pageW - cMaxX - keep) / mm))
            apply(m, to: page)
            cropped += 1
        }
        try PDFOps.save(doc, to: output)
        return cropped
    }

    private static func indices(_ text: String?, _ count: Int) throws -> [Int] {
        if let t = text, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return try PageRanges.indices(t, pageCount: count)
        }
        return Array(0..<count)
    }

    /// Les marges sont exprimées pour la page affichée ; on les ramène dans le
    /// repère non tourné de la page avant de modifier la cropBox.
    private static func apply(_ m: Margins, to page: PDFPage) {
        let t: Double = m.top * mm, b: Double = m.bottom * mm, l: Double = m.left * mm, r: Double = m.right * mm
        let mapped: (Double, Double, Double, Double)
        switch PageDrawing.rotation(page) {
        case 90: mapped = (r, l, t, b)
        case 180: mapped = (b, t, r, l)
        case 270: mapped = (l, r, b, t)
        default: mapped = (t, b, l, r)
        }
        let (top, bottom, left, right) = mapped
        let box = page.bounds(for: .cropBox)
        let x = Double(box.minX) + left
        let y = Double(box.minY) + bottom
        let width = Double(box.width) - left - right
        let height = Double(box.height) - top - bottom
        let rect = CGRect(x: x, y: y, width: width, height: height)
        guard rect.width > 20, rect.height > 20 else { return }
        page.setBounds(rect, for: .cropBox)
    }

    /// Rectangle (repère de la page affichée) contenant tout ce qui n'est pas blanc.
    public static func contentBounds(_ page: PDFPage, dpi: CGFloat = 50) -> CGRect? {
        let size = PageDrawing.displaySize(page)
        let scale = dpi / 72
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        guard w > 4, h > 4 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            PageDrawing.drawUpright(page, in: ctx)
        }
        var minX = w, minRow = h, maxX = -1, maxRow = -1
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                if lum < 230 {
                    if col < minX { minX = col }
                    if col > maxX { maxX = col }
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        // Ligne 0 du tampon = haut de l'image.
        return CGRect(x: CGFloat(minX) / scale,
                      y: CGFloat(h - 1 - maxRow) / scale,
                      width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxRow - minRow + 1) / scale)
    }

    // MARK: Plusieurs pages par feuille / livret

    /// Renvoie le nombre de feuilles (faces) créées.
    @discardableResult
    public static func impose(_ input: URL, layout: SheetLayout, to output: URL) throws -> Int {
        let doc = try PDFOps.open(input)
        let pages = PDFOps.pages(of: doc)
        guard !pages.isEmpty else { throw PDFToolError.noInput }
        var faces = 0

        try PageDrawing.rewrite(to: output, info: Metadata.info(of: doc)) { writer in
            switch layout {
            case .twoUp, .booklet:
                let sheet = a4Landscape
                let half = sheet.width / 2
                let cells = [
                    CGRect(x: 0, y: 0, width: half, height: sheet.height).insetBy(dx: 14, dy: 14),
                    CGRect(x: half, y: 0, width: half, height: sheet.height).insetBy(dx: 14, dy: 14),
                ]
                let order: [[PDFPage?]] = layout == .twoUp ? twoUpOrder(pages) : bookletOrder(pages)
                for pair in order {
                    writer.page(size: sheet) { ctx in
                        for (k, page) in pair.enumerated() {
                            if let page = page { PageDrawing.drawFitted(page, in: cells[k], ctx: ctx) }
                        }
                    }
                    faces += 1
                }

            case .fourUp:
                let sheet = a4Portrait
                let cw = sheet.width / 2, ch = sheet.height / 2
                let cells = [
                    CGRect(x: 0, y: ch, width: cw, height: ch),
                    CGRect(x: cw, y: ch, width: cw, height: ch),
                    CGRect(x: 0, y: 0, width: cw, height: ch),
                    CGRect(x: cw, y: 0, width: cw, height: ch),
                ].map { $0.insetBy(dx: 10, dy: 10) }
                for start in stride(from: 0, to: pages.count, by: 4) {
                    writer.page(size: sheet) { ctx in
                        for k in 0..<4 where start + k < pages.count {
                            PageDrawing.drawFitted(pages[start + k], in: cells[k], ctx: ctx, border: true)
                        }
                    }
                    faces += 1
                }
            }
        }
        return faces
    }

    static func twoUpOrder(_ pages: [PDFPage]) -> [[PDFPage?]] {
        var faces: [[PDFPage?]] = []
        var i = 0
        while i < pages.count {
            let second: PDFPage? = i + 1 < pages.count ? pages[i + 1] : nil
            faces.append([pages[i], second])
            i += 2
        }
        return faces
    }

    /// Ordre d'imposition d'un livret piqué : on complète à un multiple de 4 avec des pages blanches.
    static func bookletOrder(_ pages: [PDFPage]) -> [[PDFPage?]] {
        var padded: [PDFPage?] = pages
        while padded.count % 4 != 0 { padded.append(nil) }
        let n = padded.count
        var faces: [[PDFPage?]] = []
        for s in 0..<(n / 4) {
            faces.append([padded[n - 1 - 2 * s], padded[2 * s]])          // recto
            faces.append([padded[2 * s + 1], padded[n - 2 - 2 * s]])      // verso
        }
        return faces
    }
}
