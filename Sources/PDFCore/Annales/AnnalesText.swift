import Foundation
import CryptoKit

/// Petite enveloppe autour de NSRegularExpression, avec les positions en UTF-16
/// (comme NSString) pour pouvoir découper le texte aux mêmes endroits.
public struct Rx {
    public let re: NSRegularExpression

    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // Les motifs sont écrits dans le code : une erreur ici est un bug à corriger tout de suite.
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    public struct Match {
        public let location: Int              // début (UTF-16)
        public let groups: [String?]          // groupe 0 = tout le motif
        public subscript(i: Int) -> String? { i < groups.count ? groups[i] : nil }
    }

    private func convert(_ m: NSTextCheckingResult, _ ns: NSString) -> Match {
        var groups: [String?] = []
        for k in 0..<m.numberOfRanges {
            let r = m.range(at: k)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        return Match(location: m.range.location, groups: groups)
    }

    public func first(_ s: String) -> Match? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return convert(m, ns)
    }

    public func all(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { convert($0, ns) }
    }

    public func test(_ s: String) -> Bool { first(s) != nil }

    public func count(_ s: String) -> Int {
        re.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    public func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: template)
    }

    public static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }
}

public enum AnnalesText {

    /// Minuscules, sans accents, « n◦1 » → « n°1 », espaces simplifiés.
    public static func normaliser(_ texte: String) -> String {
        let decomposed = texte.lowercased().decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for u in decomposed.unicodeScalars where u.properties.generalCategory != .nonspacingMark {
            scalars.append(u)
        }
        let t = String(scalars).replacingOccurrences(of: "◦", with: "°").replacingOccurrences(of: "º", with: "°")
        return spaces.replace(t, with: " ")
    }
    private static let spaces = Rx("[ \\t]+")

    // Accents « détachés » produits par les PDF compilés avec LaTeX : « Universit´e » → « Université »
    private static let detached: [(String, String)] = [
        ("´", "\u{0301}"), ("`", "\u{0300}"), ("ˆ", "\u{0302}"), ("¨", "\u{0308}"), ("˜", "\u{0303}"),
    ]
    private static let ligatures: [(String, String)] = [
        ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl"),
    ]
    private static let detachedRules: [(Rx, String)] = detached.map { accent, combining in
        let letters = accent == "`" ? "aeiouAEIOU" : "a-zA-Z"   // ` : seulement devant une voyelle (code !)
        return (Rx(Rx.escape(accent) + "\\s?([" + letters + "])"), "$1" + combining)
    }

    /// Recolle les accents détachés, remplace les ligatures, normalise (NFC).
    public static func nettoyer(_ texte: String) -> String {
        var t = texte
        for (rule, template) in detachedRules { t = rule.replace(t, with: template) }
        for (lig, letters) in ligatures { t = t.replacingOccurrences(of: lig, with: letters) }
        t = t.replacingOccurrences(of: "\u{0C}", with: "\n")   // \f est réservé aux sauts de page
        return t.precomposedStringWithCanonicalMapping
    }

    /// Empreinte SHA-256 d'un fichier (hexadécimal).
    public static func empreinte(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Les n premiers caractères (comme texte[:n] en Python).
    public static func debut(_ texte: String, _ n: Int) -> String { String(texte.prefix(n)) }

    /// Échappe une valeur pour la placer dans une commande LaTeX.
    public static func latexEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\textbackslash{}"
            case "&", "%", "$", "#", "_", "{", "}": out += "\\\(c)"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            default: out.append(c)
            }
        }
        return out
    }
}
