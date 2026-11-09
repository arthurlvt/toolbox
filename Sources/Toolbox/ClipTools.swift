import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Couleurs & presse-papiers
//
// Trois onglets : la pipette et tous les formats d'une couleur (hex, RGB, HSL, SwiftUI, LaTeX…),
// des transformations de texte en un clic (casse, lignes copiées d'un PDF, Base64, JSON…),
// et l'historique du presse-papiers. Tout est local.

// MARK: Couleur (calculs)

/// Couleur sRGB, composantes entre 0 et 1.
struct RGBColor: Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    private static func byte(_ x: Double) -> Int { Int((clamp(x) * 255).rounded()) }

    var r8: Int { Self.byte(r) }
    var g8: Int { Self.byte(g) }
    var b8: Int { Self.byte(b) }

    /// « #1A73E8 » (« #1A73E8CC » si transparente)
    var hex: String {
        let base = String(format: "#%02X%02X%02X", r8, g8, b8)
        return a < 0.999 ? base + String(format: "%02X", Self.byte(a)) : base
    }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = Self.clamp(r); self.g = Self.clamp(g); self.b = Self.clamp(b); self.a = Self.clamp(a)
    }

    init?(hex raw: String) {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("#") { h.removeFirst() }
        if h.hasPrefix("0x") { h.removeFirst(2) }
        guard [3, 4, 6, 8].contains(h.count), h.allSatisfy({ $0.isHexDigit }) else { return nil }
        if h.count <= 4 { h = h.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(h, radix: 16) else { return nil }
        if h.count == 8 {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        } else {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        }
    }

    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? ns
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: nsColor) }

    // MARK: Espaces de couleur

    /// Teinte (0–360), saturation et luminosité HSL (0–1).
    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let l = (mx + mn) / 2
        guard d > 1e-9 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        return (hue(mx, d), s, l)
    }

    /// Teinte (0–360), saturation et valeur HSB / HSV (0–1).
    var hsb: (h: Double, s: Double, b: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        return (d > 1e-9 ? hue(mx, d) : 0, mx > 1e-9 ? d / mx : 0, mx)
    }

    private func hue(_ mx: Double, _ d: Double) -> Double {
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return h >= 360 ? h - 360 : h
    }

    var cmyk: (c: Double, m: Double, y: Double, k: Double) {
        let k = 1 - max(r, g, b)
        guard k < 0.999_999 else { return (0, 0, 0, 1) }
        return ((1 - r - k) / (1 - k), (1 - g - k) / (1 - k), (1 - b - k) / (1 - k), k)
    }

    static func fromHSL(_ h: Double, _ s: Double, _ l: Double, a: Double = 1) -> RGBColor {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 1e-9 else { return RGBColor(r: l, g: l, b: l, a: a) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGBColor(r: f(hh + 1.0 / 3), g: f(hh), b: f(hh - 1.0 / 3), a: a)
    }

    func rotated(_ degrees: Double) -> RGBColor {
        let c = hsl
        return Self.fromHSL(c.h + degrees, c.s, c.l, a: a)
    }

    /// Mélange avec une autre couleur (t = 0 : soi-même, 1 : l'autre).
    func mixed(with o: RGBColor, _ t: Double) -> RGBColor {
        RGBColor(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a)
    }

    // MARK: Contraste (WCAG)

    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(with o: RGBColor) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static let white = RGBColor(r: 1, g: 1, b: 1)
    static let black = RGBColor(r: 0, g: 0, b: 0)

    /// Texte lisible sur cette couleur : blanc ou noir.
    var readableText: RGBColor { contrast(with: .white) >= contrast(with: .black) ? .white : .black }

    // MARK: Lecture d'une couleur tapée ou collée

    /// « #1a73e8 », « 1A73E8 », « #abc », « rgb(26, 115, 232) », « rgba(…, 0.5) », « hsl(214, 81%, 51%) »,
    /// « 26, 115, 232 », « 0.1 0.45 0.91 », « \definecolor{x}{HTML}{1A73E8} », « Color(red: 0.1, green: …) »…
    static func parse(_ raw: String) -> RGBColor? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if let c = RGBColor(hex: t) { return c }
        let nums: [Double] = {
            guard let re = try? NSRegularExpression(pattern: "-?\\d+(?:[.,]\\d+)?") else { return [] }
            return re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { m in
                Range(m.range, in: t).flatMap { Double(t[$0].replacingOccurrences(of: ",", with: ".")) }
            }
        }()
        if t.hasPrefix("hsl"), nums.count >= 3 {
            let s = nums[1] > 1 ? nums[1] / 100 : nums[1], l = nums[2] > 1 ? nums[2] / 100 : nums[2]
            return fromHSL(nums[0], s, l, a: nums.count > 3 ? (nums[3] > 1 ? nums[3] / 100 : nums[3]) : 1)
        }
        if t.contains("{html}"), let r = t.range(of: "[0-9a-f]{6}", options: .regularExpression) {
            return RGBColor(hex: String(t[r]))
        }
        if nums.count >= 3 {
            let rgb = Array(nums.prefix(3))
            // « Color(red: 0.1, …) » ou « 0.1 0.45 0.91 » : fractions ; sinon 0–255
            let fractions = rgb.allSatisfy { $0 <= 1 } && (t.contains(".") || t.contains("red:")) && !t.hasPrefix("rgb")
            let k = fractions ? 1.0 : 255.0
            let alpha = nums.count > 3 ? (nums[3] > 1 ? nums[3] / 100 : nums[3]) : 1
            return RGBColor(r: rgb[0] / k, g: rgb[1] / k, b: rgb[2] / k, a: alpha)
        }
        if let r = t.range(of: "#?[0-9a-f]{6}\\b", options: .regularExpression) {
            return RGBColor(hex: String(t[r]))
        }
        return nil
    }

    // MARK: Formats

    static func fmt(_ x: Double) -> String { String(format: "%.3f", x) }
    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded())) %" }

    /// (nom, texte à copier) dans l'ordre d'affichage.
    func formats(latexName: String) -> [(String, String)] {
        let h = hsl, v = hsb, k = cmyk
        let name = latexName.isEmpty ? "macouleur" : latexName
        let html = String(hex.dropFirst().prefix(6))
        let alpha = a < 0.999 ? ", \(Self.fmt(a))" : ""
        return [
            ("HEX", hex),
            ("RGB", a < 0.999 ? "rgba(\(r8), \(g8), \(b8)\(alpha))" : "rgb(\(r8), \(g8), \(b8))"),
            ("HSL", "hsl(\(Int(h.h.rounded())), \(Int((h.s * 100).rounded()))%, \(Int((h.l * 100).rounded()))%)"),
            ("HSB", "\(Int(v.h.rounded()))°, \(Self.pct(v.s)), \(Self.pct(v.b))"),
            ("CMJN", "\(Self.pct(k.c)), \(Self.pct(k.m)), \(Self.pct(k.y)), \(Self.pct(k.k))"),
            ("LaTeX", "\\definecolor{\(name)}{HTML}{\(html)}"),
            ("LaTeX RGB", "\\definecolor{\(name)}{RGB}{\(r8),\(g8),\(b8)}"),
            ("SwiftUI", "Color(red: \(Self.fmt(r)), green: \(Self.fmt(g)), blue: \(Self.fmt(b))\(a < 0.999 ? ", opacity: \(Self.fmt(a))" : ""))"),
            ("AppKit", "NSColor(srgbRed: \(Self.fmt(r)), green: \(Self.fmt(g)), blue: \(Self.fmt(b)), alpha: \(Self.fmt(a)))"),
            ("Entier", "0x" + html),
        ]
    }
}

// MARK: Pipette et couleurs

final class ColorStore: ObservableObject {
    static let shared = ColorStore()
    private let d = UserDefaults.standard

    @Published var current: RGBColor
    @Published var input = ""
    @Published var inputError = false
    @Published var latexName: String { didSet { d.set(latexName, forKey: "colors.latexName") } }
    @Published var copyFormat: String { didSet { d.set(copyFormat, forKey: "colors.copyFormat") } }
    @Published private(set) var history: [String] { didSet { d.set(history, forKey: "colors.history") } }
    @Published private(set) var favorites: [String] { didSet { d.set(favorites, forKey: "colors.favorites") } }

    static let copyFormats = ["HEX", "RGB", "HSL", "LaTeX", "SwiftUI"]

    init() {
        let d = UserDefaults.standard
        history = d.stringArray(forKey: "colors.history") ?? []
        favorites = d.stringArray(forKey: "colors.favorites") ?? []
        latexName = d.string(forKey: "colors.latexName") ?? "macouleur"
        copyFormat = d.string(forKey: "colors.copyFormat") ?? "HEX"
        current = (d.stringArray(forKey: "colors.history")?.first).flatMap { RGBColor(hex: $0) } ?? RGBColor(r: 0.102, g: 0.451, b: 0.910)
    }

    /// Pour le nuancier système (ColorPicker).
    var swiftUIColor: Color {
        get { current.color }
        set { set(RGBColor(NSColor(newValue)), remember: false) }
    }

    func set(_ c: RGBColor, remember: Bool = true) {
        current = c
        inputError = false
        if remember { addHistory(c.hex) }
    }

    func addHistory(_ hex: String) {
        history.removeAll { $0 == hex }
        history.insert(hex, at: 0)
        if history.count > 24 { history.removeLast(history.count - 24) }
    }

    func applyInput() {
        if let c = RGBColor.parse(input) {
            set(c)
            inputError = false
        } else {
            inputError = !input.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Pipette système : une loupe suit la souris, n'importe où à l'écran (aucune autorisation nécessaire).
    func pick(copy: Bool) {
        NSColorSampler().show { [weak self] picked in
            guard let self = self, let ns = picked else { return }
            let c = RGBColor(ns)
            DispatchQueue.main.async {
                self.set(c)
                if copy { self.copy(self.value(of: self.copyFormat), label: self.copyFormat) }
            }
        }
    }

    func value(of format: String) -> String {
        current.formats(latexName: latexName).first { $0.0 == format }?.1 ?? current.hex
    }

    func copy(_ text: String, label: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.show(label.map { L("Copié") + " (\($0)) : " + text } ?? L("Copié") + " : " + text)
    }

    func isFavorite(_ hex: String) -> Bool { favorites.contains(hex) }

    func toggleFavorite(_ hex: String) {
        if let i = favorites.firstIndex(of: hex) { favorites.remove(at: i) } else { favorites.insert(hex, at: 0) }
    }

    func clearHistory() { history = [] }

    /// ⌃⌥C depuis n'importe quelle app : pipette, puis la couleur est copiée (format choisi).
    static func registerHotKey() {
        guard UserDefaults.standard.object(forKey: "colors.hotkey") as? Bool ?? true else {
            GlobalHotKey.shared.unregister(id: 2)
            return
        }
        GlobalHotKey.shared.register(id: 2, keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey)) {
            ColorStore.shared.pick(copy: true)
        }
    }

    /// Nuances : du presque blanc au presque noir, la couleur au milieu.
    var shades: [RGBColor] {
        let c = current
        return [0.85, 0.7, 0.55, 0.4, 0.2].map { c.mixed(with: .white, $0) } + [c]
            + [0.2, 0.4, 0.55, 0.7, 0.85].map { c.mixed(with: .black, $0) }
    }

    var harmonies: [(String, [RGBColor])] {
        let c = current
        return [("Complémentaire", [c, c.rotated(180)]),
                ("Analogues", [c.rotated(-30), c, c.rotated(30)]),
                ("Triade", [c, c.rotated(120), c.rotated(240)]),
                ("Carré", [c, c.rotated(90), c.rotated(180), c.rotated(270)])]
    }
}

// MARK: Transformations de texte

enum TextTransform: String, CaseIterable, Identifiable {
    case upper, lower, sentence, title, noAccents
    case joinLines, collapseSpaces, trimLines, sortLines, uniqueLines, reverseLines, numberLines
    case straightQuotes, frenchQuotes
    case slug, camel, snake
    case urlEncode, urlDecode, base64Encode, base64Decode, jsonPretty, jsonCompact, latexEscape

    var id: String { rawValue }

    static let groups: [(String, [TextTransform])] = [
        ("Casse", [.upper, .lower, .sentence, .title, .noAccents]),
        ("Lignes et espaces", [.joinLines, .collapseSpaces, .trimLines, .sortLines, .uniqueLines, .reverseLines, .numberLines]),
        ("Guillemets et noms", [.straightQuotes, .frenchQuotes, .slug, .camel, .snake]),
        ("Encodage et code", [.urlEncode, .urlDecode, .base64Encode, .base64Decode, .jsonPretty, .jsonCompact, .latexEscape]),
    ]

    var title: String {
        switch self {
        case .upper: return "MAJUSCULES"
        case .lower: return "minuscules"
        case .sentence: return "Début de phrase"
        case .title: return "Chaque Mot"
        case .noAccents: return "Sans accents"
        case .joinLines: return "Recoller les lignes (PDF)"
        case .collapseSpaces: return "Espaces en trop"
        case .trimLines: return "Nettoyer les lignes"
        case .sortLines: return "Trier les lignes"
        case .uniqueLines: return "Lignes en double"
        case .reverseLines: return "Inverser les lignes"
        case .numberLines: return "Numéroter"
        case .straightQuotes: return "Guillemets droits"
        case .frenchQuotes: return "Guillemets « »"
        case .slug: return "nom-de-fichier"
        case .camel: return "camelCase"
        case .snake: return "snake_case"
        case .urlEncode: return "Encoder l'URL"
        case .urlDecode: return "Décoder l'URL"
        case .base64Encode: return "→ Base64"
        case .base64Decode: return "Base64 →"
        case .jsonPretty: return "JSON indenté"
        case .jsonCompact: return "JSON compact"
        case .latexEscape: return "Échapper pour LaTeX"
        }
    }

    var help: String {
        switch self {
        case .joinLines: return "Le texte copié d'un PDF arrive coupé à chaque ligne : on recolle les phrases (et les mots coupés par un tiret), les paragraphes restent"
        case .collapseSpaces: return "Plusieurs espaces ou tabulations → un seul espace"
        case .trimLines: return "Espaces au début et à la fin de chaque ligne, lignes vides en trop"
        case .uniqueLines: return "Garde la première occurrence de chaque ligne"
        case .noAccents: return "é → e, ç → c, œ → oe…"
        case .slug: return "« Analyse 1 – TD n°3 » → analyse-1-td-n-3"
        case .latexEscape: return "& % $ # _ { } ~ ^ \\ → leur version LaTeX"
        default: return title
        }
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let s) = self { return s } else { return nil } }
    }

    private static let fr = Locale(identifier: "fr_FR")

    private static func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    private static func words(_ s: String) -> [String] {
        s.folding(options: .diacriticInsensitive, locale: fr)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    func run(_ s0: String) throws -> String {
        let s = s0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch self {
        case .upper: return s.uppercased(with: Self.fr)
        case .lower: return s.lowercased(with: Self.fr)
        case .title: return s.lowercased(with: Self.fr).capitalized(with: Self.fr)
        case .sentence:
            var out = ""
            var start = true
            for ch in s.lowercased(with: Self.fr) {
                if start, ch.isLetter {
                    out += String(ch).uppercased(with: Self.fr)
                    start = false
                } else {
                    out.append(ch)
                    if ".!?\n".contains(ch) { start = true } else if !ch.isWhitespace && !"«“\"'(".contains(ch) { start = false }
                }
            }
            return out
        case .noAccents:
            return s.replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "Œ", with: "OE")
                .replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "Æ", with: "AE")
                .folding(options: .diacriticInsensitive, locale: Self.fr)
        case .joinLines:
            // paragraphes séparés par une ligne vide ; dans un paragraphe, les lignes sont recollées
            let paragraphs = s.components(separatedBy: "\n").reduce(into: [[String]]([[]])) { acc, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { if !(acc.last?.isEmpty ?? true) { acc.append([]) } } else { acc[acc.count - 1].append(t) }
            }.filter { !$0.isEmpty }
            return paragraphs.map { lines in
                var out = ""
                for line in lines {
                    if out.isEmpty { out = line; continue }
                    if out.hasSuffix("-"), let f = line.first, f.isLowercase {
                        out.removeLast()          // mot coupé en fin de ligne : « exem- / ple » → « exemple »
                        out += line
                    } else {
                        out += " " + line
                    }
                }
                return out
            }.joined(separator: "\n\n")
        case .collapseSpaces:
            return s.replacingOccurrences(of: "[ \\t\\u00A0]{2,}", with: " ", options: .regularExpression)
        case .trimLines:
            let ls = Self.lines(s).map { $0.trimmingCharacters(in: .whitespaces) }
            var out: [String] = []
            for l in ls where !(l.isEmpty && (out.last?.isEmpty ?? true)) { out.append(l) }
            while out.last?.isEmpty == true { out.removeLast() }
            return out.joined(separator: "\n")
        case .sortLines:
            return Self.lines(s).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<String>()
            return Self.lines(s).filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .reverseLines:
            return Self.lines(s).reversed().joined(separator: "\n")
        case .numberLines:
            var n = 0
            return Self.lines(s).map { l in
                if l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
                n += 1
                return "\(n). \(l)"
            }.joined(separator: "\n")
        case .straightQuotes:
            return s.replacingOccurrences(of: "«[\\s\\u00A0\\u202F]*", with: "\"", options: .regularExpression)
                .replacingOccurrences(of: "[\\s\\u00A0\\u202F]*»", with: "\"", options: .regularExpression)
                .replacingOccurrences(of: "[“”„]", with: "\"", options: .regularExpression)
                .replacingOccurrences(of: "[‘’‚]", with: "'", options: .regularExpression)
        case .frenchQuotes:
            var open = true
            var out = ""
            for ch in s {
                if ch == "\"" || ch == "“" || ch == "”" {
                    out += open ? "«\u{00A0}" : "\u{00A0}»"
                    open.toggle()
                } else {
                    out.append(ch)
                }
            }
            return out.replacingOccurrences(of: "«\u{00A0} ", with: "«\u{00A0}").replacingOccurrences(of: " \u{00A0}»", with: "\u{00A0}»")
        case .slug:
            return Self.words(s.lowercased(with: Self.fr)).joined(separator: "-")
        case .camel:
            let w = Self.words(s)
            guard let first = w.first else { return "" }
            return first.lowercased() + w.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
        case .snake:
            return Self.words(s).map { $0.lowercased() }.joined(separator: "_")
        case .urlEncode:
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=?+#")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        case .urlDecode:
            guard let r = s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { throw Failure.invalid(L("Encodage URL invalide.")) }
            return r
        case .base64Encode:
            return Data(s.utf8).base64EncodedString()
        case .base64Decode:
            let clean = s.filter { !$0.isWhitespace }
            guard let d = Data(base64Encoded: clean, options: .ignoreUnknownCharacters), let r = String(data: d, encoding: .utf8) else {
                throw Failure.invalid(L("Ce n'est pas du Base64 contenant du texte."))
            }
            return r
        case .jsonPretty, .jsonCompact:
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                throw Failure.invalid(L("JSON invalide."))
            }
            var opts: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
            if self == .jsonPretty { opts.insert(.prettyPrinted); opts.insert(.sortedKeys) }
            let out = try JSONSerialization.data(withJSONObject: obj, options: opts)
            return String(data: out, encoding: .utf8) ?? s
        case .latexEscape:
            return LatexDocTemplates.esc(s)
        }
    }
}

final class TextToolsStore: ObservableObject {
    static let shared = TextToolsStore()
    @Published var text = ""
    @Published var previous: String?
    @Published var error: String?
    @Published var autoCopy = UserDefaults.standard.bool(forKey: "texttools.autoCopy") {
        didSet { UserDefaults.standard.set(autoCopy, forKey: "texttools.autoCopy") }
    }

    func paste() {
        if let s = NSPasteboard.general.string(forType: .string) {
            previous = text
            text = s
        }
    }

    func copy() {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.show(L("Copié !"))
    }

    func apply(_ t: TextTransform) {
        if text.isEmpty { paste() }
        do {
            let r = try t.run(text)
            previous = text
            text = r
            error = nil
            if autoCopy { copy() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func undo() {
        guard let p = previous else { return }
        previous = text
        text = p
    }

    var stats: String {
        let chars = text.count
        let noSpace = text.filter { !$0.isWhitespace }.count
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        let minutes = max(1, Int((Double(words) / 230).rounded(.up)))
        return "\(chars) " + L("caractères") + " · \(noSpace) " + L("sans espaces") + " · \(words) " + L("mots")
            + " · \(lines) " + L("lignes") + (words > 0 ? " · ≈ \(minutes) min " + L("de lecture") : "")
    }
}

// MARK: - Vue

final class ClipToolState: ObservableObject {
    static let shared = ClipToolState()
    @Published var tab = UserDefaults.standard.string(forKey: "cliptool.tab") ?? "colors" {
        didSet { UserDefaults.standard.set(tab, forKey: "cliptool.tab") }
    }
    @Published var search = ""
}

struct ClipToolView: View {
    @ObservedObject var st = ClipToolState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ToolHeader(tool: .clip)
                Picker("", selection: $st.tab) {
                    Label("Couleurs", systemImage: "eyedropper.halffull").tag("colors")
                    Label("Texte", systemImage: "textformat").tag("text")
                    Label("Historique", systemImage: "list.bullet.clipboard").tag("history")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .tourTarget("clip.tabs")
                switch st.tab {
                case "text": TextToolsPane()
                case "history": ClipHistoryPane()
                default: ColorPane()
                }
            }
            .padding(20)
        }
    }
}

struct Swatch: View {
    let color: RGBColor
    var size: CGFloat = 28
    var selected = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(color.color)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-2))
    }
}

struct ColorPane: View {
    @ObservedObject var c = ColorStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                // grand aperçu
                RoundedRectangle(cornerRadius: 14)
                    .fill(c.current.color)
                    .frame(width: 170, height: 170)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
                    .overlay(alignment: .bottomLeading) {
                        Text(c.current.hex)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(c.current.readableText.color)
                            .padding(12)
                    }
                    .onTapGesture { c.copy(c.current.hex) }
                    .help("Clic : copier le code hex")

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button { c.pick(copy: true) } label: {
                            Label("Pipette", systemImage: "eyedropper").frame(minWidth: 110)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("Choisis un pixel n'importe où à l'écran ; la couleur est copiée (⌃⌥C depuis n'importe quelle app)")
                        ColorPicker("Nuancier", selection: $c.swiftUIColor, supportsOpacity: true)
                            .fixedSize()
                        Button { c.toggleFavorite(c.current.hex) } label: {
                            Image(systemName: c.isFavorite(c.current.hex) ? "star.fill" : "star")
                                .foregroundStyle(c.isFavorite(c.current.hex) ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(c.isFavorite(c.current.hex) ? "Retirer des favoris" : "Ajouter aux favoris")
                    }
                    HStack(spacing: 6) {
                        TextField("Colle une couleur : #1A73E8, rgb(…), hsl(…), \\definecolor…", text: $c.input)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { c.applyInput() }
                            .frame(maxWidth: 380)
                        Button("Lire") { c.applyInput() }
                    }
                    if c.inputError {
                        Text("Format non reconnu.").font(.caption).foregroundStyle(.red)
                    }
                    HStack(spacing: 12) {
                        Picker("La pipette copie", selection: $c.copyFormat) {
                            ForEach(ColorStore.copyFormats, id: \.self) { Text($0).tag($0) }
                        }
                        .fixedSize()
                        TextField("Nom LaTeX", text: $c.latexName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .help("Nom utilisé dans \\definecolor{…}")
                    }
                    .controlSize(.small)
                    Text("⌃⌥C depuis n'importe quelle app : pipette, et la couleur est copiée au format choisi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // formats
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(c.current.formats(latexName: c.latexName).enumerated()), id: \.offset) { i, f in
                        HStack {
                            Text(f.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            Text(f.1).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                            Spacer()
                            Button { c.copy(f.1, label: f.0) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copier")
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { c.copy(f.1, label: f.0) }
                        if i < 9 { Divider() }
                    }
                }
                .padding(.horizontal, 4)
            } label: {
                Text("Formats (double-clic ou ⧉ pour copier)")
            }

            // nuances, harmonies
            VStack(alignment: .leading, spacing: 8) {
                Text("Nuances").font(.headline)
                HStack(spacing: 4) {
                    ForEach(Array(c.shades.enumerated()), id: \.offset) { i, s in
                        Swatch(color: s, size: 34, selected: i == 5)
                            .onTapGesture { c.set(s) }
                            .contextMenu { Button("Copier \(s.hex)") { c.copy(s.hex) } }
                            .help(s.hex)
                    }
                }
                Text("Harmonies").font(.headline).padding(.top, 6)
                HStack(alignment: .top, spacing: 22) {
                    ForEach(c.harmonies, id: \.0) { h in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L(h.0)).font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                ForEach(Array(h.1.enumerated()), id: \.offset) { _, s in
                                    Swatch(color: s, size: 30)
                                        .onTapGesture { c.set(s) }
                                        .contextMenu { Button("Copier \(s.hex)") { c.copy(s.hex) } }
                                        .help(s.hex)
                                }
                            }
                        }
                    }
                }
            }

            // contraste
            VStack(alignment: .leading, spacing: 8) {
                Text("Lisibilité (contraste WCAG)").font(.headline)
                HStack(spacing: 12) {
                    contrastSample(text: .white, label: "Texte blanc")
                    contrastSample(text: .black, label: "Texte noir")
                }
            }

            // favoris et historique
            if !c.favorites.isEmpty { swatchRow(title: "Favoris", list: c.favorites, clear: nil) }
            if !c.history.isEmpty { swatchRow(title: "Récentes", list: c.history, clear: { c.clearHistory() }) }
        }
    }

    private func contrastSample(text: RGBColor, label: String) -> some View {
        let ratio = c.current.contrast(with: text)
        let grade = ratio >= 7 ? "AAA" : ratio >= 4.5 ? "AA" : ratio >= 3 ? "AA gros texte" : "Illisible"
        return VStack(alignment: .leading, spacing: 4) {
            Text("Aa " + L(label))
                .font(.title3.weight(.semibold))
                .foregroundStyle(text.color)
                .frame(width: 190, height: 52)
                .background(RoundedRectangle(cornerRadius: 8).fill(c.current.color))
            Text(String(format: "%.2f : 1", ratio) + " · " + L(grade))
                .font(.caption.weight(.medium))
                .foregroundStyle(ratio >= 4.5 ? Color.green : ratio >= 3 ? Color.orange : Color.red)
        }
    }

    private func swatchRow(title: String, list: [String], clear: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L(title)).font(.headline)
                Spacer()
                if let clear = clear { Button("Effacer", action: clear).buttonStyle(.borderless).font(.caption) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(list, id: \.self) { hex in
                    if let col = RGBColor(hex: hex) {
                        Swatch(color: col, size: 30, selected: col.hex == c.current.hex)
                            .onTapGesture { c.set(col) }
                            .contextMenu {
                                Button("Copier \(hex)") { c.copy(hex) }
                                Button(c.isFavorite(hex) ? "Retirer des favoris" : "Ajouter aux favoris") { c.toggleFavorite(hex) }
                            }
                            .help(hex)
                    }
                }
            }
        }
    }
}

struct TextToolsPane: View {
    @ObservedObject var t = TextToolsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { t.paste() } label: { Label("Coller", systemImage: "doc.on.clipboard") }
                Button { t.copy() } label: { Label("Copier", systemImage: "doc.on.doc") }
                    .disabled(t.text.isEmpty)
                Button { t.undo() } label: { Label("Annuler", systemImage: "arrow.uturn.backward") }
                    .disabled(t.previous == nil)
                Button { t.previous = t.text; t.text = "" } label: { Label("Vider", systemImage: "xmark.circle") }
                    .disabled(t.text.isEmpty)
                Spacer()
                Toggle("Copier le résultat automatiquement", isOn: $t.autoCopy)
                    .toggleStyle(.checkbox)
            }
            .controlSize(.small)
            TextEditor(text: $t.text)
                .font(.system(.body, design: .default))
                .frame(minHeight: 170, maxHeight: 260)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                .overlay(alignment: .topLeading) {
                    if t.text.isEmpty {
                        Text("Colle ou tape un texte, puis choisis une transformation (vide = le presse-papiers est utilisé).")
                            .foregroundStyle(.tertiary).padding(10).allowsHitTesting(false)
                    }
                }
            HStack {
                Text(t.stats).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let e = t.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
            ForEach(TextTransform.groups, id: \.0) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text(L(g.0)).font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(g.1) { tr in
                            Button { t.apply(tr) } label: {
                                Text(L(tr.title)).frame(maxWidth: .infinity)
                            }
                            .help(L(tr.help))
                        }
                    }
                }
            }
        }
    }
}

struct ClipHistoryPane: View {
    @ObservedObject var clip = ClipboardStore.shared
    @ObservedObject var st = ClipToolState.shared

    private var filtered: [ClipboardStore.Item] {
        let q = st.search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? clip.items : clip.items.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Rechercher dans l'historique", text: $st.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Toggle("En pause", isOn: $clip.paused).toggleStyle(.checkbox)
                    .help("Ne plus rien enregistrer pour l'instant")
                Spacer()
                Button("Tout effacer") { clip.clear() }.disabled(clip.items.isEmpty)
            }
            .controlSize(.small)
            Text("Les \(clip.limit) derniers textes copiés, gardés en mémoire seulement (rien n'est écrit sur le disque, les mots de passe sont ignorés).")
                .font(.caption).foregroundStyle(.secondary)
            if filtered.isEmpty {
                Text(clip.items.isEmpty ? "Rien pour l'instant : copie un texte n'importe où." : "Aucun résultat.")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(filtered) { item in
                HStack(alignment: .top, spacing: 10) {
                    if let col = RGBColor.parse(item.text), item.text.count < 40 {
                        Swatch(color: col, size: 18)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).lineLimit(3).font(.callout)
                        Text(item.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { clip.copy(item) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copier")
                    Button {
                        TextToolsStore.shared.text = item.text
                        st.tab = "text"
                    } label: { Image(systemName: "textformat") }
                        .buttonStyle(.borderless).help("Transformer ce texte")
                    Button { clip.remove(item) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Retirer")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .onTapGesture(count: 2) { clip.copy(item) }
            }
        }
    }
}
