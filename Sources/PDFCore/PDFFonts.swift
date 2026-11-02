import Foundation
import AppKit
import PDFKit
import CoreText

/// Retrouver la police d'un texte du PDF pour le réécrire à l'identique :
/// 1. la police embarquée dans le PDF (si elle contient toutes les lettres à écrire) ;
/// 2. la même police installée sur le Mac ;
/// 3. une police qui lui ressemble (serif / sans serif / chasse fixe, gras, italique).
public enum PDFFonts {

    /// « ABCDEF+Calibri-Bold » → « Calibri-Bold » (préfixe de sous-ensemble retiré).
    public static func baseName(_ raw: String) -> String {
        if raw.count > 7, raw.dropFirst(6).first == "+",
           raw.prefix(6).allSatisfy({ $0.isUppercase && $0.isLetter }) {
            return String(raw.dropFirst(7))
        }
        return raw
    }

    static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Polices embarquées

    /// Polices TrueType / OpenType embarquées dans la page (nom sans préfixe → descripteur).
    /// Les polices Type 1 (souvent celles de LaTeX) ne sont pas lisibles par CoreText : on passe alors aux suivantes.
    public static func embedded(on page: PDFPage) -> [String: CTFontDescriptor] {
        guard var dict = page.pageRef?.dictionary else { return [:] }
        // Ressources de la page, ou héritées d'un nœud parent
        var resources: CGPDFDictionaryRef?
        for _ in 0..<8 {
            if CGPDFDictionaryGetDictionary(dict, "Resources", &resources) { break }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Parent", &parent), let p = parent else { break }
            dict = p
        }
        var fonts: CGPDFDictionaryRef?
        guard let res = resources, CGPDFDictionaryGetDictionary(res, "Font", &fonts), let fontDict = fonts else { return [:] }
        var out: [String: CTFontDescriptor] = [:]
        CGPDFDictionaryApplyBlock(fontDict, { _, object, _ in
            var fd: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &fd), let font = fd, let found = PDFFonts.load(font) {
                out[found.0] = found.1
            }
            return true
        }, nil)
        return out
    }

    static func load(_ font: CGPDFDictionaryRef) -> (String, CTFontDescriptor)? {
        var base: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(font, "BaseFont", &base), let b = base else { return nil }
        var descriptor: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor) {
            // police composite (Type0) : le descripteur est dans DescendantFonts[0]
            var arr: CGPDFArrayRef?
            var first: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(font, "DescendantFonts", &arr), let a = arr,
               CGPDFArrayGetDictionary(a, 0, &first), let f = first {
                _ = CGPDFDictionaryGetDictionary(f, "FontDescriptor", &descriptor)
            }
        }
        guard let desc = descriptor else { return nil }
        for key in ["FontFile2", "FontFile3"] {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(desc, key, &stream), let s = stream else { continue }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(s, &format), format == .raw,
                  let fd = CTFontManagerCreateFontDescriptorFromData(data) else { continue }
            return (baseName(String(cString: b)), fd)
        }
        return nil
    }

    /// La police contient-elle toutes les lettres du texte ? (une police embarquée n'a souvent que celles utilisées)
    public static func covers(_ font: NSFont, _ text: String) -> Bool {
        let chars = Array(text.filter { !$0.isWhitespace && !$0.isNewline }.utf16)
        guard !chars.isEmpty else { return true }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyphs, chars.count) && !glyphs.contains(0)
    }

    // MARK: Polices installées

    /// La même police installée sur le Mac (nom exact, sinon même famille et même style).
    public static func installed(_ raw: String, size: CGFloat) -> NSFont? {
        let name = baseName(raw)
        if let f = NSFont(name: name, size: size) { return f }
        let n = norm(name)
        // famille la plus longue dont le nom commence le nom de la police (« TimesNewRomanPS-BoldMT » → Times New Roman)
        let family = NSFontManager.shared.availableFontFamilies
            .filter { let f = norm($0); return f.count >= 4 && n.hasPrefix(f) }
            .max { norm($0).count < norm($1).count }
        guard let fam = family else { return nil }
        return NSFontManager.shared.font(withFamily: fam, traits: traits(name), weight: 5, size: size)
            ?? NSFont(name: fam, size: size)
    }

    static func traits(_ name: String) -> NSFontTraitMask {
        let l = name.lowercased()
        var t: NSFontTraitMask = []
        if ["bold", "black", "heavy", "semibold", "demi", "cmbx", "-bd"].contains(where: { l.contains($0) }) { t.insert(.boldFontMask) }
        if ["italic", "oblique", "cmti", "cmsl", "-it"].contains(where: { l.contains($0) }) { t.insert(.italicFontMask) }
        return t
    }

    /// Une police installée qui ressemble (genre et style), toujours trouvée.
    public static func lookalike(_ raw: String, size: CGFloat) -> NSFont {
        let l = baseName(raw).lowercased()
        let family: String
        if ["mono", "courier", "consol", "cmtt", "code", "menlo", "inconsolata"].contains(where: { l.contains($0) }) {
            family = "Menlo"
        } else if !l.contains("sans") && ["times", "roman", "serif", "georgia", "garamond", "cmr", "lmroman", "minion",
                                           "cambria", "palatino", "book", "cmbx", "cmti", "cmsl", "baskerville", "caslon"]
                    .contains(where: { l.contains($0) }) {
            family = "Times New Roman"
        } else {
            family = "Helvetica"
        }
        return NSFontManager.shared.font(withFamily: family, traits: traits(l), weight: 5, size: size)
            ?? NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
    }

    /// Polices pour réécrire un texte écrit en `raw` : la police embarquée (si présente) et une police de secours
    /// installée (la même, ou une qui ressemble). Choisir ensuite avec `pick`.
    public static func candidates(for raw: String, on page: PDFPage, size: CGFloat) -> (embedded: NSFont?, fallback: NSFont) {
        let name = baseName(raw)
        let n = norm(name)
        var embeddedFont: NSFont?
        let found = embedded(on: page)
        if let d = found[name] ?? found.first(where: { norm($0.key) == n })?.value
            ?? found.first(where: { !n.isEmpty && (norm($0.key).hasPrefix(n) || n.hasPrefix(norm($0.key))) })?.value {
            embeddedFont = CTFontCreateWithFontDescriptor(d, size, nil) as NSFont
        }
        return (embeddedFont, installed(name, size: size) ?? lookalike(name, size: size))
    }

    /// La police embarquée si elle sait écrire tout le texte, sinon celle de secours.
    public static func pick(_ c: (embedded: NSFont?, fallback: NSFont), for text: String) -> NSFont {
        if let e = c.embedded, covers(e, text) { return e }
        return c.fallback
    }
}

// MARK: - Liens et sommaire

/// Les copies réécrites page par page (éditeur, signature) perdent liens et sommaire : on les remet.
public enum PDFLinks {

    /// Remet dans `output` les liens (web et internes) et le sommaire de `source`.
    /// `output` doit avoir les mêmes pages, dans le même ordre, dessinées à l'endroit (PageDrawing).
    public static func restore(from source: PDFDocument, into output: URL) throws {
        guard let out = PDFDocument(url: output), out.pageCount == source.pageCount else { return }
        var changed = false
        for i in 0..<source.pageCount {
            guard let sp = source.page(at: i), let op = out.page(at: i) else { continue }
            let t = sp.transform(for: .cropBox)
            for a in sp.annotations where PDFEdit.kind(a) == "Link" {
                let link = PDFAnnotation(bounds: a.bounds.applying(t).standardized, forType: .link, withProperties: nil)
                if let u = a.url ?? (a.action as? PDFActionURL)?.url {
                    link.url = u
                } else if let d = a.destination ?? (a.action as? PDFActionGoTo)?.destination,
                          let nd = remap(d, from: source, to: out) {
                    link.destination = nd
                } else {
                    continue
                }
                let b = PDFBorder()
                b.lineWidth = 0
                link.border = b
                op.addAnnotation(link)
                changed = true
            }
        }
        if let root = source.outlineRoot, root.numberOfChildren > 0 {
            out.outlineRoot = copy(root, from: source, to: out)
            changed = true
        }
        guard changed else { return }
        let tmp = FileUtils.temporarySibling(of: output)
        guard out.write(to: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        try FileUtils.replace(output, with: tmp)
    }

    static func remap(_ d: PDFDestination, from source: PDFDocument, to out: PDFDocument) -> PDFDestination? {
        guard let p = d.page else { return nil }
        let i = source.index(for: p)
        guard i < out.pageCount, let np = out.page(at: i) else { return nil }
        var pt = d.point
        let u = kPDFDestinationUnspecifiedValue
        if pt.x != u && pt.y != u {
            pt = pt.applying(p.transform(for: .cropBox))
        } else if pt.y != u {
            pt.y = CGPoint(x: 0, y: pt.y).applying(p.transform(for: .cropBox)).y
        }
        return PDFDestination(page: np, at: pt)
    }

    static func copy(_ o: PDFOutline, from source: PDFDocument, to out: PDFDocument) -> PDFOutline {
        let n = PDFOutline()
        n.label = o.label
        if let d = o.destination ?? (o.action as? PDFActionGoTo)?.destination {
            n.destination = remap(d, from: source, to: out)
        } else if let a = o.action as? PDFActionURL, let u = a.url {
            n.action = PDFActionURL(url: u)
        }
        for k in 0..<o.numberOfChildren {
            if let c = o.child(at: k) { n.insertChild(copy(c, from: source, to: out), at: n.numberOfChildren) }
        }
        n.isOpen = o.isOpen
        return n
    }
}
