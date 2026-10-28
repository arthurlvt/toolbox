import Foundation
import PDFKit
import CoreGraphics

/// Une page de l'ancien PDF mise en face d'une page du nouveau.
public struct PagePair: Identifiable {
    public enum Kind { case identical, modified, added, removed }

    public let id: Int
    public let old: Int?          // index (0…) dans l'ancien PDF, nil si page ajoutée
    public let new: Int?          // index dans le nouveau, nil si page supprimée
    public var kind: Kind
    public var changedRatio: Double
    public var removedText: [String]
    public var addedText: [String]

    public var label: String {
        switch (old, new) {
        case let (a?, b?): return a == b ? "Page \(b + 1)" : "Page \(a + 1) → \(b + 1)"
        case let (a?, nil): return "Page \(a + 1) (ancienne)"
        case let (nil, b?): return "Page \(b + 1) (nouvelle)"
        default: return "?"
        }
    }
}

/// Comparaison de deux versions d'un PDF : texte (mot à mot) et rendu (pixel à pixel).
public enum PDFCompare {

    // MARK: Alignement des pages

    static func words(_ s: String?) -> [String] {
        (s ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        return Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
    }

    public static func compare(old: URL, new: URL, progress: ((Double) -> Void)? = nil) throws -> [PagePair] {
        guard let da = PDFDocument(url: old) else { throw PDFToolError.cannotOpen(old) }
        guard let db = PDFDocument(url: new) else { throw PDFToolError.cannotOpen(new) }
        if da.isLocked { throw PDFToolError.locked(old) }
        if db.isLocked { throw PDFToolError.locked(new) }

        let wa = (0..<da.pageCount).map { words(da.page(at: $0)?.string) }
        let wb = (0..<db.pageCount).map { words(db.page(at: $0)?.string) }
        let sa = wa.map { Set($0) }, sb = wb.map { Set($0) }

        // Pages « semblables » (≥ 50 % de mots en commun) = mêmes pages, éventuellement retouchées.
        let pairs = align(da.pageCount, db.pageCount) { i, j in similarity(sa[i], sb[j]) >= 0.5 }

        var result: [PagePair] = []
        for (k, pair) in pairs.enumerated() {
            let (a, b) = pair
            progress?(Double(k) / Double(max(1, pairs.count)))
            let pa = a.flatMap { da.page(at: $0) }
            let pb = b.flatMap { db.page(at: $0) }
            var removed: [String] = [], added: [String] = []
            for c in TextDiff.diff(a.map { wa[$0] } ?? [], b.map { wb[$0] } ?? []) where c.kind != .same {
                let text = c.items.joined(separator: " ")
                let short = text.count > 240 ? String(text.prefix(240)) + "…" : text
                if c.kind == .removed { removed.append(short) } else { added.append(short) }
            }
            let ratio = changedRatio(pa, pb)
            let kind: PagePair.Kind
            switch (a, b) {
            case (nil, _): kind = .added
            case (_, nil): kind = .removed
            default: kind = (ratio < 0.0002 && removed.isEmpty && added.isEmpty) ? .identical : .modified
            }
            result.append(PagePair(id: k, old: a, new: b, kind: kind, changedRatio: ratio,
                                   removedText: Array(removed.prefix(40)), addedText: Array(added.prefix(40))))
        }
        progress?(1)
        return result
    }

    /// Alignement des pages par plus longue sous-suite commune ; une suite de pages supprimées
    /// et ajoutées au même endroit est appariée (= pages très modifiées).
    static func align(_ n: Int, _ m: Int, _ similar: (Int, Int) -> Bool) -> [(Int?, Int?)] {
        if n * m > 4_000_000 {
            return (0..<max(n, m)).map { ($0 < n ? $0 : nil, $0 < m ? $0 : nil) }
        }
        let w = m + 1
        var L = [Int32](repeating: 0, count: (n + 1) * w)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    L[i * w + j] = similar(i, j) ? L[(i + 1) * w + j + 1] + 1 : max(L[(i + 1) * w + j], L[i * w + j + 1])
                }
            }
        }
        var out: [(Int?, Int?)] = []
        var removed: [Int] = [], added: [Int] = []
        func flush() {
            let k = min(removed.count, added.count)
            for t in 0..<k { out.append((removed[t], added[t])) }
            for a in removed.dropFirst(k) { out.append((a, nil)) }
            for b in added.dropFirst(k) { out.append((nil, b)) }
            removed = []
            added = []
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && similar(i, j) {
                flush()
                out.append((i, j))
                i += 1; j += 1
            } else if i < n && (j == m || L[(i + 1) * w + j] >= L[i * w + j + 1]) {
                removed.append(i); i += 1
            } else {
                added.append(j); j += 1
            }
        }
        flush()
        return out
    }

    // MARK: Rendu

    struct Bitmap {
        let width: Int
        let height: Int
        var data: [UInt8]   // RGBX, 4 octets par pixel, première ligne = haut de la page
    }

    static func canvas(_ a: PDFPage?, _ b: PDFPage?, scale: CGFloat) -> (Int, Int) {
        let sa = a.map(PageDrawing.displaySize) ?? .zero
        let sb = b.map(PageDrawing.displaySize) ?? .zero
        let w = Int((max(sa.width, sb.width) * scale).rounded(.up))
        let h = Int((max(sa.height, sb.height) * scale).rounded(.up))
        return (max(1, w), max(1, h))
    }

    static func bitmap(_ page: PDFPage?, width: Int, height: Int, scale: CGFloat) -> Bitmap {
        let bpr = width * 4
        var data = [UInt8](repeating: 255, count: bpr * height)
        if let page = page {
            data.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let size = PageDrawing.displaySize(page)
                ctx.translateBy(x: 0, y: CGFloat(height) - size.height * scale)   // collée en haut à gauche
                ctx.scaleBy(x: scale, y: scale)
                PageDrawing.drawUpright(page, in: ctx)
            }
        }
        return Bitmap(width: width, height: height, data: data)
    }

    @inline(__always) static func luminance(_ d: [UInt8], _ i: Int) -> Int {
        (Int(d[i]) * 3 + Int(d[i + 1]) * 6 + Int(d[i + 2])) / 10
    }

    /// Part des pixels qui changent entre les deux pages (rendu à 40 dpi).
    public static func changedRatio(_ a: PDFPage?, _ b: PDFPage?) -> Double {
        if a == nil || b == nil { return 1 }
        let scale: CGFloat = 40 / 72
        let (w, h) = canvas(a, b, scale: scale)
        let ba = bitmap(a, width: w, height: h, scale: scale)
        let bb = bitmap(b, width: w, height: h, scale: scale)
        var changed = 0
        var i = 0
        while i < ba.data.count {
            if abs(luminance(ba.data, i) - luminance(bb.data, i)) > 40 { changed += 1 }
            i += 4
        }
        return Double(changed) / Double(w * h)
    }

    /// Superposition : le nouveau en clair, ce qui a disparu en rouge, ce qui est apparu en vert,
    /// et les zones modifiées surlignées en jaune.
    public static func overlay(old a: PDFPage?, new b: PDFPage?, dpi: Double = 110) -> CGImage? {
        let scale = CGFloat(dpi / 72)
        let (w, h) = canvas(a, b, scale: scale)
        let ba = bitmap(a, width: w, height: h, scale: scale)
        let bb = bitmap(b, width: w, height: h, scale: scale)
        let ink = 185, cell = 14
        let cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell
        var mask = [UInt8](repeating: 0, count: w * h)      // 1 supprimé, 2 ajouté, 3 modifié
        var cells = [Bool](repeating: false, count: cw * ch)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let la = luminance(ba.data, i), lb = luminance(bb.data, i)
                guard abs(la - lb) > 60 else { continue }
                let inkA = la < ink, inkB = lb < ink
                let m: UInt8 = (inkA && !inkB) ? 1 : ((inkB && !inkA) ? 2 : 3)
                mask[y * w + x] = m
                cells[(y / cell) * cw + (x / cell)] = true
            }
        }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x, i = p * 4
                var r = Int(bb.data[i]), g = Int(bb.data[i + 1]), bl = Int(bb.data[i + 2])
                switch mask[p] {
                case 1: (r, g, bl) = (215, 35, 35)
                case 2: (r, g, bl) = (25, 145, 60)
                case 3: (r, g, bl) = (230, 120, 0)
                default:
                    // inchangé : estompé, sur fond jaune si la zone a bougé
                    r = 255 - (255 - r) * 4 / 10; g = 255 - (255 - g) * 4 / 10; bl = 255 - (255 - bl) * 4 / 10
                    if cells[(y / cell) * cw + (x / cell)] { r = r * 6 / 10 + 255 * 4 / 10; g = g * 6 / 10 + 236 * 4 / 10; bl = bl * 6 / 10 + 120 * 4 / 10 }
                }
                out[i] = UInt8(clamping: r); out[i + 1] = UInt8(clamping: g); out[i + 2] = UInt8(clamping: bl)
            }
        }
        return image(out, width: w, height: h)
    }

    /// Rendu simple d'une page sur le même canevas que sa partenaire (pour le côte à côte).
    public static func render(_ page: PDFPage?, partner: PDFPage?, dpi: Double = 110) -> CGImage? {
        let scale = CGFloat(dpi / 72)
        let (w, h) = canvas(page, partner, scale: scale)
        let b = bitmap(page, width: w, height: h, scale: scale)
        return image(b.data, width: w, height: h)
    }

    static func image(_ data: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Rapport

    /// Un PDF avec, pour chaque page qui change, la superposition et la liste des changements de texte.
    public static func report(old: URL, new: URL, pairs: [PagePair], to output: URL) throws {
        guard let da = PDFDocument(url: old), let db = PDFDocument(url: new) else { throw PDFToolError.cannotOpen(old) }
        let changed = pairs.filter { $0.kind != .identical }
        let black = CGColor(gray: 0, alpha: 1)
        try PageDrawing.rewrite(to: output, info: ["title": "Comparaison \(old.lastPathComponent) / \(new.lastPathComponent)"]) { writer in
            // Page de garde
            writer.page(size: CGSize(width: 595, height: 842)) { ctx in
                var y: CGFloat = 780
                PageDrawing.drawText("Comparaison de PDF", in: ctx, at: CGPoint(x: 50, y: y), size: 22, color: black, bold: true, anchor: .left)
                y -= 34
                for line in ["Ancien : \(old.lastPathComponent) (\(da.pageCount) pages)",
                             "Nouveau : \(new.lastPathComponent) (\(db.pageCount) pages)",
                             "\(changed.count) page(s) différente(s) sur \(pairs.count).",
                             "Légende : rouge = supprimé, vert = ajouté, orange = modifié, jaune = zone touchée."] {
                    PageDrawing.drawText(line, in: ctx, at: CGPoint(x: 50, y: y), size: 11, color: black, anchor: .left)
                    y -= 18
                }
                y -= 10
                for p in changed.prefix(30) {
                    let what: String
                    switch p.kind {
                    case .added: what = "page ajoutée"
                    case .removed: what = "page supprimée"
                    default: what = "\(p.removedText.count) passage(s) supprimé(s), \(p.addedText.count) ajouté(s)"
                    }
                    PageDrawing.drawText("• \(p.label) : \(what)", in: ctx, at: CGPoint(x: 60, y: y), size: 10, color: black, anchor: .left)
                    y -= 15
                    if y < 60 { break }
                }
            }
            for p in changed {
                guard let img = overlay(old: p.old.flatMap { da.page(at: $0) }, new: p.new.flatMap { db.page(at: $0) }) else { continue }
                let size = CGSize(width: CGFloat(img.width) * 72 / 110, height: CGFloat(img.height) * 72 / 110)
                writer.page(size: CGSize(width: size.width, height: size.height + 28)) { ctx in
                    ctx.draw(img, in: CGRect(origin: .zero, size: size))
                    PageDrawing.drawText(p.label, in: ctx, at: CGPoint(x: 12, y: size.height + 9), size: 12,
                                         color: black, bold: true, anchor: .left)
                }
            }
        }
    }
}
