import Foundation

/// Lecteur YAML minimal, suffisant pour les fichiers de config d'Annalyse
/// (config/etablissements.yaml, config/<niveau>/matieres.yaml, notions.yaml) :
/// commentaires, dictionnaires imbriqués par indentation, listes « [a, "b", c] »
/// éventuellement sur plusieurs lignes, listes « - x », chaînes entre guillemets, {}.
/// L'ordre des clés est conservé.
public indirect enum YAMLNode {
    case scalar(String)
    case list([YAMLNode])
    case map([(key: String, value: YAMLNode)])
    case null

    public subscript(key: String) -> YAMLNode? {
        if case .map(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }

    public var string: String? {
        if case .scalar(let s) = self { return s }
        return nil
    }

    public var strings: [String] {
        switch self {
        case .list(let items): return items.compactMap { $0.string }
        case .scalar(let s): return [s]
        default: return []
        }
    }

    public var pairs: [(key: String, value: YAMLNode)] {
        if case .map(let p) = self { return p }
        return []
    }
}

public enum MiniYAML {

    public static func load(_ url: URL) throws -> YAMLNode {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) -> YAMLNode {
        let lines = logicalLines(text)
        var index = 0
        return parseBlock(lines, &index, indent: lines.first?.indent ?? 0)
    }

    struct Line {
        let indent: Int
        let content: String
    }

    // MARK: Pré-traitement

    /// Retire les commentaires et les lignes vides, recolle les listes « [ ... ] » sur plusieurs lignes.
    static func logicalLines(_ text: String) -> [Line] {
        var result: [Line] = []
        var pending: (indent: Int, content: String)?
        for raw in text.components(separatedBy: .newlines) {
            let stripped = stripComment(raw)
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if var p = pending {
                p.content += " " + stripped.trimmingCharacters(in: .whitespaces)
                if bracketBalance(p.content) <= 0 {
                    result.append(Line(indent: p.indent, content: p.content))
                    pending = nil
                } else {
                    pending = p
                }
                continue
            }
            let indent = stripped.prefix { $0 == " " }.count
            let content = stripped.trimmingCharacters(in: .whitespaces)
            if bracketBalance(content) > 0 {
                pending = (indent, content)
            } else {
                result.append(Line(indent: indent, content: content))
            }
        }
        if let p = pending { result.append(Line(indent: p.indent, content: p.content)) }
        return result
    }

    static func stripComment(_ line: String) -> String {
        var inSingle = false, inDouble = false
        var previous: Character = " "
        var out = ""
        for c in line {
            if c == "\"" && !inSingle { inDouble.toggle() }
            else if c == "'" && !inDouble && (previous == " " || previous == "[" || previous == "," || inSingle) { inSingle.toggle() }
            else if c == "#" && !inSingle && !inDouble && (previous == " " || out.isEmpty) { break }
            out.append(c)
            previous = c
        }
        return out.replacingOccurrences(of: "\t", with: "  ")
    }

    static func bracketBalance(_ s: String) -> Int {
        var balance = 0
        var inDouble = false
        for c in s {
            if c == "\"" { inDouble.toggle() }
            if inDouble { continue }
            if c == "[" { balance += 1 }
            if c == "]" { balance -= 1 }
        }
        return balance
    }

    // MARK: Analyse

    static func parseBlock(_ lines: [Line], _ i: inout Int, indent: Int) -> YAMLNode {
        guard i < lines.count else { return .null }
        if lines[i].content.hasPrefix("- ") || lines[i].content == "-" {
            var items: [YAMLNode] = []
            while i < lines.count, lines[i].indent == indent, lines[i].content.hasPrefix("-") {
                let value = String(lines[i].content.dropFirst()).trimmingCharacters(in: .whitespaces)
                i += 1
                items.append(value.isEmpty ? parseChild(lines, &i, parentIndent: indent) : parseValue(value))
            }
            return .list(items)
        }
        var pairs: [(key: String, value: YAMLNode)] = []
        while i < lines.count, lines[i].indent == indent {
            let line = lines[i].content
            guard let kv = splitKey(line) else { i += 1; continue }
            let (key, rest) = kv
            i += 1
            if rest.isEmpty {
                pairs.append((key, parseChild(lines, &i, parentIndent: indent)))
            } else {
                pairs.append((key, parseValue(rest)))
            }
        }
        return .map(pairs)
    }

    static func parseChild(_ lines: [Line], _ i: inout Int, parentIndent: Int) -> YAMLNode {
        guard i < lines.count, lines[i].indent > parentIndent else { return .null }
        return parseBlock(lines, &i, indent: lines[i].indent)
    }

    /// « clé: valeur » → (clé, valeur). La clé peut être entre guillemets.
    static func splitKey(_ line: String) -> (String, String)? {
        var inDouble = false
        let chars = Array(line)
        for (k, c) in chars.enumerated() {
            if c == "\"" { inDouble.toggle() }
            if c == ":" && !inDouble && (k + 1 == chars.count || chars[k + 1] == " ") {
                let key = unquote(String(chars[..<k]).trimmingCharacters(in: .whitespaces))
                let rest = k + 1 < chars.count ? String(chars[(k + 1)...]).trimmingCharacters(in: .whitespaces) : ""
                return (key, rest)
            }
        }
        return nil
    }

    static func parseValue(_ raw: String) -> YAMLNode {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if v == "{}" { return .map([]) }
        if v == "~" || v == "null" { return .null }
        if v.hasPrefix("[") && v.hasSuffix("]") {
            let inner = String(v.dropFirst().dropLast())
            return .list(splitFlow(inner).map { .scalar(unquote($0)) })
        }
        return .scalar(unquote(v))
    }

    /// Sépare « a, "b, c", d » en tenant compte des guillemets.
    static func splitFlow(_ s: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inDouble = false, inSingle = false
        for c in s {
            if c == "\"" && !inSingle { inDouble.toggle() }
            if c == "'" && !inDouble && (current.trimmingCharacters(in: .whitespaces).isEmpty || inSingle) { inSingle.toggle() }
            if c == "," && !inDouble && !inSingle {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { items.append(t) }
                current = ""
            } else {
                current.append(c)
            }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { items.append(t) }
        return items
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            return String(t.dropFirst().dropLast())
        }
        return t
    }
}
