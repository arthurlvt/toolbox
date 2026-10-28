import Foundation

// Moteur de la calculatrice graphique : lecture d'expressions « à la main » (2x, sin x, x², √x, |x|…),
// évaluation rapide, dérivée exacte, simplification, export LaTeX / pgfplots, petite analyse numérique.

indirect enum MathNode: Equatable {
    case num(Double)
    case x
    case const(String)                 // pi, e, inf
    case variable(String)              // paramètres : a, b, k…
    case neg(MathNode)
    case add(MathNode, MathNode)
    case sub(MathNode, MathNode)
    case mul(MathNode, MathNode)
    case div(MathNode, MathNode)
    case pow(MathNode, MathNode)
    case call(String, MathNode)        // sin, ln, sqrt…
    case user(String, Int, MathNode)   // f(…), f'(…) (nombre de primes)
    case fact(MathNode)

    var containsX: Bool {
        switch self {
        case .x: return true
        case .num, .const, .variable: return false
        case .neg(let a), .call(_, let a), .fact(let a), .user(_, _, let a): return a.containsX
        case .add(let a, let b), .sub(let a, let b), .mul(let a, let b), .div(let a, let b), .pow(let a, let b):
            return a.containsX || b.containsX
        }
    }

    /// Paramètres utilisés (hors x).
    var variables: Set<String> {
        switch self {
        case .variable(let v): return [v]
        case .num, .const, .x: return []
        case .neg(let a), .call(_, let a), .fact(let a), .user(_, _, let a): return a.variables
        case .add(let a, let b), .sub(let a, let b), .mul(let a, let b), .div(let a, let b), .pow(let a, let b):
            return a.variables.union(b.variables)
        }
    }

    var userCalls: Set<String> {
        switch self {
        case .user(let f, _, let a): return a.userCalls.union([f])
        case .num, .const, .x, .variable: return []
        case .neg(let a), .call(_, let a), .fact(let a): return a.userCalls
        case .add(let a, let b), .sub(let a, let b), .mul(let a, let b), .div(let a, let b), .pow(let a, let b):
            return a.userCalls.union(b.userCalls)
        }
    }
}

struct MathError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Ce que connaît le moteur au moment d'évaluer : paramètres et fonctions définies.
struct MathEnv {
    var variables: [String: Double] = [:]
    var functions: [String: MathNode] = [:]
}

enum MathEngine {
    static let functionNames: Set<String> = ["sin", "cos", "tan", "cot", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
                                             "exp", "ln", "log", "log2", "sqrt", "cbrt", "abs", "floor", "ceil", "sign"]
    static let aliases: [String: String] = ["asin": "arcsin", "acos": "arccos", "atan": "arctan", "racine": "sqrt",
                                            "ent": "floor", "sgn": "sign", "argsh": "asinh", "tg": "tan"]
    static let constantNames: Set<String> = ["pi", "e", "inf", "ans"]
    /// Noms possibles d'une fonction définie par l'utilisateur.
    static let userNames = Array("fghpqruvw")

    // MARK: Lecture

    enum Token: Equatable {
        case num(Double)
        case name(String)
        case op(Character)        // + - * / ^ !
        case lparen, rparen, bar, prime, sqrtSign
    }

    static func tokenize(_ input: String, userFunctions: Set<String>) throws -> [Token] {
        var s = input
        for (a, b) in [("×", "*"), ("·", "*"), ("÷", "/"), ("−", "-"), ("–", "-"), ("π", "pi"), ("∞", "inf"),
                       ("²", "^2"), ("³", "^3"), ("**", "^"), ("’", "'"), ("[", "("), ("]", ")"), ("{", "("), ("}", ")")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        let chars = Array(s)
        var tokens: [Token] = []
        var i = 0
        let known = functionNames.union(aliases.keys).union(constantNames)
        let sortedKnown = known.sorted { $0.count > $1.count }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                var text = ""
                while j < chars.count {
                    let d = chars[j]
                    if d.isNumber { text.append(d) }
                    else if (d == "." || d == ","), !text.contains("."), j + 1 < chars.count, chars[j + 1].isNumber { text.append(".") }
                    else { break }
                    j += 1
                }
                guard let v = Double(text) else { throw MathError(message: "Nombre illisible « \(text) »") }
                tokens.append(.num(v))
                i = j
                continue
            }
            if c.isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter || (chars[j].isNumber && j > i && String(chars[i..<j]) == "log") { j += 1 }
                let word = String(chars[i..<j]).lowercased()
                // découpe « 2xsinx » en x, sin, x ; « pix » en pi, x…
                var k = word.startIndex
                while k < word.endIndex {
                    let rest = word[k...]
                    if let m = sortedKnown.first(where: { rest.hasPrefix($0) }) {
                        tokens.append(.name(aliases[m] ?? m))
                        k = word.index(k, offsetBy: m.count)
                    } else {
                        tokens.append(.name(String(word[k])))
                        k = word.index(after: k)
                    }
                }
                i = j
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "!": tokens.append(.op(c))
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case "|": tokens.append(.bar)
            case "'": tokens.append(.prime)
            case "√": tokens.append(.sqrtSign)
            case ",", ";": throw MathError(message: "Une seule variable par fonction : utilise « . » ou « , » seulement dans les nombres")
            case "=": throw MathError(message: "« = » n'est permis qu'au début : f(x) = … ou a = …")
            default: throw MathError(message: "Symbole inconnu « \(c) »")
            }
            i += 1
        }
        return tokens
    }

    final class Parser {
        let tokens: [Token]
        var pos = 0
        var absDepth = 0
        let userFunctions: Set<String>

        init(_ tokens: [Token], userFunctions: Set<String>) {
            self.tokens = tokens
            self.userFunctions = userFunctions
        }

        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }
        func next() -> Token? { defer { pos += 1 }; return peek }

        func parse() throws -> MathNode {
            guard !tokens.isEmpty else { throw MathError(message: "Expression vide") }
            let n = try expr()
            if let t = peek {
                if t == .rparen { throw MathError(message: "Parenthèse fermante en trop") }
                throw MathError(message: "Expression mal formée près de « \(describe(t)) »")
            }
            return n
        }

        func describe(_ t: Token) -> String {
            switch t {
            case .num(let v): return MathFormat.plain(v)
            case .name(let n): return n
            case .op(let c): return String(c)
            case .lparen: return "("
            case .rparen: return ")"
            case .bar: return "|"
            case .prime: return "'"
            case .sqrtSign: return "√"
            }
        }

        func expr() throws -> MathNode {
            var left = try term()
            while let t = peek, t == .op("+") || t == .op("-") {
                pos += 1
                let right = try term()
                left = t == .op("+") ? .add(left, right) : .sub(left, right)
            }
            return left
        }

        func startsFactor(_ t: Token) -> Bool {
            switch t {
            case .num, .name, .lparen, .sqrtSign: return true
            case .bar: return absDepth == 0
            default: return false
            }
        }

        func term() throws -> MathNode {
            var left = try unary()
            while let t = peek {
                if t == .op("*") || t == .op("/") {
                    pos += 1
                    let right = try unary()
                    left = t == .op("*") ? .mul(left, right) : .div(left, right)
                } else if startsFactor(t) {
                    left = .mul(left, try power())        // multiplication implicite : 2x, 3(x+1), x sin x
                } else {
                    break
                }
            }
            return left
        }

        func unary() throws -> MathNode {
            if peek == .op("-") { pos += 1; return .neg(try unary()) }
            if peek == .op("+") { pos += 1; return try unary() }
            return try power()
        }

        func power() throws -> MathNode {
            let base = try postfix()
            if peek == .op("^") {
                pos += 1
                return .pow(base, try unary())          // 2^-x, 2^3^2 = 2^(3^2)
            }
            return base
        }

        func postfix() throws -> MathNode {
            var n = try primary()
            while peek == .op("!") { pos += 1; n = .fact(n) }
            return n
        }

        func primary() throws -> MathNode {
            guard let t = next() else { throw MathError(message: "Il manque quelque chose à la fin") }
            switch t {
            case .num(let v): return .num(v)
            case .lparen:
                let inner = try expr()
                guard next() == .rparen else { throw MathError(message: "Parenthèse fermante manquante") }
                return inner
            case .bar:
                absDepth += 1
                let inner = try expr()
                absDepth -= 1
                guard next() == .bar else { throw MathError(message: "Barre de valeur absolue « | » non fermée") }
                return .call("abs", inner)
            case .sqrtSign:
                return .call("sqrt", try power())
            case .name(let name):
                if name == "x" { return .x }
                if constantNames.contains(name) { return name == "ans" ? .variable("ans") : .const(name) }
                if functionNames.contains(name) { return try functionCall(name) }
                if userFunctions.contains(name), peek == .lparen || peek == .prime {
                    var primes = 0
                    while peek == .prime { pos += 1; primes += 1 }
                    guard next() == .lparen else { throw MathError(message: "Écris \(name)(…) avec des parenthèses") }
                    let arg = try expr()
                    guard next() == .rparen else { throw MathError(message: "Parenthèse fermante manquante") }
                    return .user(name, primes, arg)
                }
                if name.count == 1, name != "e" { return .variable(name) }
                throw MathError(message: "Nom inconnu « \(name) »")
            default:
                throw MathError(message: "Expression mal formée près de « \(describe(t)) »")
            }
        }

        /// Argument sans parenthèses : « sin 2x » = sin(2x), mais « sin x cos x » = sin(x)·cos(x).
        func tightProduct() throws -> MathNode {
            var n = try power()
            while let t = peek, startsFactor(t), t != .lparen {
                if case .name(let name) = t, functionNames.contains(name) || name == "x" && n.containsX { break }
                n = .mul(n, try power())
            }
            return n
        }

        /// sin x, sin(x), sin²x, sin^2(x)
        func functionCall(_ name: String) throws -> MathNode {
            var exponent: MathNode?
            if peek == .op("^") {
                pos += 1
                exponent = try postfix()
            }
            let arg: MathNode
            if peek == .lparen {
                pos += 1
                arg = try expr()
                guard next() == .rparen else { throw MathError(message: "Parenthèse fermante manquante après \(name)") }
            } else {
                guard let t = peek, startsFactor(t) else { throw MathError(message: "Il manque l'argument de \(name)") }
                arg = try tightProduct()
            }
            let call = MathNode.call(name, arg)
            return exponent.map { .pow(call, $0) } ?? call
        }
    }

    static func parse(_ input: String, userFunctions: Set<String> = []) throws -> MathNode {
        try Parser(try tokenize(input, userFunctions: userFunctions), userFunctions: userFunctions).parse()
    }

    /// « f(x) = x² », « y = x² » ou « x² » → (nom éventuel, expression).
    static func splitDefinition(_ line: String) -> (name: String?, body: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^([a-zA-Z])\s*\(\s*x\s*\)\s*="#, options: .regularExpression) {
            return (String(t[t.startIndex]), String(t[r.upperBound...]))
        }
        if let r = t.range(of: #"^y\s*="#, options: .regularExpression) { return (nil, String(t[r.upperBound...])) }
        return (nil, t)
    }

    // MARK: Évaluation

    typealias Fn = (Double) -> Double

    static func compile(_ n: MathNode, env: MathEnv, depth: Int = 0) throws -> Fn {
        guard depth < 10 else { throw MathError(message: "Définition circulaire (une fonction s'appelle elle-même)") }
        switch n {
        case .num(let v): return { _ in v }
        case .x: return { $0 }
        case .const(let c):
            let v = c == "pi" ? Double.pi : (c == "e" ? M_E : Double.infinity)
            return { _ in v }
        case .variable(let name):
            guard let v = env.variables[name] else { throw MathError(message: "« \(name) » n'a pas de valeur") }
            return { _ in v }
        case .neg(let a):
            let fa = try compile(a, env: env, depth: depth)
            return { -fa($0) }
        case .add(let a, let b):
            let fa = try compile(a, env: env, depth: depth), fb = try compile(b, env: env, depth: depth)
            return { fa($0) + fb($0) }
        case .sub(let a, let b):
            let fa = try compile(a, env: env, depth: depth), fb = try compile(b, env: env, depth: depth)
            return { fa($0) - fb($0) }
        case .mul(let a, let b):
            let fa = try compile(a, env: env, depth: depth), fb = try compile(b, env: env, depth: depth)
            return { fa($0) * fb($0) }
        case .div(let a, let b):
            let fa = try compile(a, env: env, depth: depth), fb = try compile(b, env: env, depth: depth)
            return { fa($0) / fb($0) }
        case .pow(let a, let b):
            let fa = try compile(a, env: env, depth: depth), fb = try compile(b, env: env, depth: depth)
            // racine impaire d'un négatif : x^(1/3) défini pour x < 0, comme sur une calculatrice
            if case .div(.num(let p), .num(let q)) = b, q.truncatingRemainder(dividingBy: 2) == 1, p == p.rounded() {
                return { x in
                    let base = fa(x)
                    if base >= 0 { return Foundation.pow(base, p / q) }
                    let r = -Foundation.pow(-base, 1 / q)
                    return Foundation.pow(r, p)
                }
            }
            return { Foundation.pow(fa($0), fb($0)) }
        case .fact(let a):
            let fa = try compile(a, env: env, depth: depth)
            return { tgamma(fa($0) + 1) }
        case .call(let f, let a):
            let fa = try compile(a, env: env, depth: depth)
            let g = try elementary(f)
            return { g(fa($0)) }
        case .user(let name, let primes, let a):
            guard var def = env.functions[name] else { throw MathError(message: "La fonction \(name) n'est pas définie") }
            for _ in 0..<primes { def = simplify(try derivative(def, env: env)) }
            let g = try compile(def, env: env, depth: depth + 1)
            let fa = try compile(a, env: env, depth: depth)
            return { g(fa($0)) }
        }
    }

    static func elementary(_ f: String) throws -> Fn {
        switch f {
        case "sin": return { Foundation.sin($0) }
        case "cos": return { Foundation.cos($0) }
        case "tan": return { Foundation.tan($0) }
        case "cot": return { 1 / Foundation.tan($0) }
        case "arcsin": return { Foundation.asin($0) }
        case "arccos": return { Foundation.acos($0) }
        case "arctan": return { Foundation.atan($0) }
        case "sinh": return { Foundation.sinh($0) }
        case "cosh": return { Foundation.cosh($0) }
        case "tanh": return { Foundation.tanh($0) }
        case "exp": return { Foundation.exp($0) }
        case "ln": return { Foundation.log($0) }
        case "log": return { Foundation.log10($0) }
        case "log2": return { Foundation.log2($0) }
        case "sqrt": return { Foundation.sqrt($0) }
        case "cbrt": return { Foundation.cbrt($0) }
        case "abs": return { Swift.abs($0) }
        case "floor": return { Foundation.floor($0) }
        case "ceil": return { Foundation.ceil($0) }
        case "sign": return { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        default: throw MathError(message: "Fonction inconnue « \(f) »")
        }
    }

    static func evaluate(_ n: MathNode, env: MathEnv, x: Double = 0) throws -> Double {
        try compile(n, env: env)(x)
    }

    // MARK: Dérivée exacte

    /// Remplace x par `arg` (pour déplier f(2x+1)).
    static func substitute(_ n: MathNode, _ arg: MathNode) -> MathNode {
        switch n {
        case .x: return arg
        case .num, .const, .variable: return n
        case .neg(let a): return .neg(substitute(a, arg))
        case .add(let a, let b): return .add(substitute(a, arg), substitute(b, arg))
        case .sub(let a, let b): return .sub(substitute(a, arg), substitute(b, arg))
        case .mul(let a, let b): return .mul(substitute(a, arg), substitute(b, arg))
        case .div(let a, let b): return .div(substitute(a, arg), substitute(b, arg))
        case .pow(let a, let b): return .pow(substitute(a, arg), substitute(b, arg))
        case .call(let f, let a): return .call(f, substitute(a, arg))
        case .user(let f, let p, let a): return .user(f, p, substitute(a, arg))
        case .fact(let a): return .fact(substitute(a, arg))
        }
    }

    /// Déplie les appels f(…) avec leur définition.
    static func inline(_ n: MathNode, env: MathEnv, depth: Int = 0) throws -> MathNode {
        guard depth < 10 else { throw MathError(message: "Définition circulaire") }
        switch n {
        case .num, .const, .variable, .x: return n
        case .neg(let a): return .neg(try inline(a, env: env, depth: depth))
        case .add(let a, let b): return .add(try inline(a, env: env, depth: depth), try inline(b, env: env, depth: depth))
        case .sub(let a, let b): return .sub(try inline(a, env: env, depth: depth), try inline(b, env: env, depth: depth))
        case .mul(let a, let b): return .mul(try inline(a, env: env, depth: depth), try inline(b, env: env, depth: depth))
        case .div(let a, let b): return .div(try inline(a, env: env, depth: depth), try inline(b, env: env, depth: depth))
        case .pow(let a, let b): return .pow(try inline(a, env: env, depth: depth), try inline(b, env: env, depth: depth))
        case .call(let f, let a): return .call(f, try inline(a, env: env, depth: depth))
        case .fact(let a): return .fact(try inline(a, env: env, depth: depth))
        case .user(let f, let primes, let a):
            guard var def = env.functions[f] else { throw MathError(message: "La fonction \(f) n'est pas définie") }
            def = try inline(def, env: env, depth: depth + 1)
            for _ in 0..<primes { def = simplify(try derivative(def, env: env)) }
            return substitute(def, try inline(a, env: env, depth: depth))
        }
    }

    static func derivative(_ node: MathNode, env: MathEnv) throws -> MathNode {
        let n = try inline(node, env: env)
        return try d(n)
    }

    private static func d(_ n: MathNode) throws -> MathNode {
        if !n.containsX { return .num(0) }
        switch n {
        case .x: return .num(1)
        case .num, .const, .variable: return .num(0)
        case .neg(let a): return .neg(try d(a))
        case .add(let a, let b): return .add(try d(a), try d(b))
        case .sub(let a, let b): return .sub(try d(a), try d(b))
        case .mul(let a, let b): return .add(.mul(try d(a), b), .mul(a, try d(b)))
        case .div(let a, let b):
            if !b.containsX { return .div(try d(a), b) }
            return .div(.sub(.mul(try d(a), b), .mul(a, try d(b))), .pow(b, .num(2)))
        case .pow(let u, let v):
            if !v.containsX {                                   // (u^n)' = n u^(n-1) u'
                return .mul(.mul(v, .pow(u, .sub(v, .num(1)))), try d(u))
            }
            if !u.containsX {                                   // (a^v)' = ln(a) a^v v'
                if u == .const("e") { return .mul(n, try d(v)) }
                return .mul(.mul(.call("ln", u), n), try d(v))
            }
            // u^v = e^(v ln u)
            return .mul(n, .add(.mul(try d(v), .call("ln", u)), .div(.mul(v, try d(u)), u)))
        case .call(let f, let u):
            let du = try d(u)
            let outer: MathNode
            switch f {
            case "sin": outer = .call("cos", u)
            case "cos": outer = .neg(.call("sin", u))
            case "tan": outer = .div(.num(1), .pow(.call("cos", u), .num(2)))
            case "cot": outer = .neg(.div(.num(1), .pow(.call("sin", u), .num(2))))
            case "arcsin": outer = .div(.num(1), .call("sqrt", .sub(.num(1), .pow(u, .num(2)))))
            case "arccos": outer = .neg(.div(.num(1), .call("sqrt", .sub(.num(1), .pow(u, .num(2))))))
            case "arctan": outer = .div(.num(1), .add(.num(1), .pow(u, .num(2))))
            case "sinh": outer = .call("cosh", u)
            case "cosh": outer = .call("sinh", u)
            case "tanh": outer = .sub(.num(1), .pow(.call("tanh", u), .num(2)))
            case "exp": outer = .call("exp", u)
            case "ln": return .div(du, u)
            case "log": return .div(du, .mul(u, .call("ln", .num(10))))
            case "log2": return .div(du, .mul(u, .call("ln", .num(2))))
            case "sqrt": return .div(du, .mul(.num(2), .call("sqrt", u)))
            case "cbrt": return .div(du, .mul(.num(3), .pow(.call("cbrt", u), .num(2))))
            case "abs": outer = .call("sign", u)
            case "floor", "ceil", "sign": return .num(0)
            default: throw MathError(message: "Je ne sais pas dériver \(f)")
            }
            return .mul(outer, du)
        case .fact:
            throw MathError(message: "La factorielle n'a pas de dérivée simple")
        case .user:
            throw MathError(message: "Fonction non dépliée")
        }
    }

    // MARK: Simplification (juste ce qu'il faut pour des dérivées lisibles)

    static func simplify(_ n: MathNode) -> MathNode {
        var current = n
        for _ in 0..<16 {
            let s = simp(current)
            if s == current { return s }
            current = s
        }
        return current
    }

    private static func isInt(_ v: Double) -> Bool { v == v.rounded() && Swift.abs(v) < 1e15 }

    private static func simp(_ n: MathNode) -> MathNode {
        switch n {
        case .num, .x, .const, .variable: return n
        case .fact(let a):
            let a = simp(a)
            if case .num(let v) = a, isInt(v), v >= 0, v <= 20 { return .num(tgamma(v + 1)) }
            return .fact(a)
        case .user(let f, let p, let a): return .user(f, p, simp(a))
        case .neg(let a):
            let a = simp(a)
            if case .num(let v) = a { return .num(-v) }
            if case .neg(let b) = a { return b }
            if case .sub(let p, let q) = a { return .sub(q, p) }
            return .neg(a)
        case .add(let a, let b):
            let a = simp(a), b = simp(b)
            if a == .num(0) { return b }
            if b == .num(0) { return a }
            if case .num(let p) = a, case .num(let q) = b { return .num(p + q) }
            if case .neg(let c) = b { return .sub(a, c) }
            if case .num(let q) = b, q < 0 { return .sub(a, .num(-q)) }
            if case .mul(.num(let q), let c) = b, q < 0 { return .sub(a, .mul(.num(-q), c)) }
            if case .neg(let c) = a { return .sub(b, c) }
            if a == b { return .mul(.num(2), a) }
            if case .num = a, !(b.isNum) { return .add(b, a) }       // x + 1 plutôt que 1 + x
            return .add(a, b)
        case .sub(let a, let b):
            let a = simp(a), b = simp(b)
            if b == .num(0) { return a }
            if a == .num(0) { return .neg(b) }
            if case .num(let p) = a, case .num(let q) = b { return .num(p - q) }
            if a == b { return .num(0) }
            if case .neg(let c) = b { return .add(a, c) }
            if case .num(let q) = b, q < 0 { return .add(a, .num(-q)) }
            if case .mul(.num(let q), let c) = b, q < 0 { return .add(a, .mul(.num(-q), c)) }
            return .sub(a, b)
        case .mul(let a, let b):
            let a = simp(a), b = simp(b)
            if a == .num(0) || b == .num(0) { return .num(0) }
            if a == .num(1) { return b }
            if b == .num(1) { return a }
            if a == .num(-1) { return .neg(b) }
            if b == .num(-1) { return .neg(a) }
            if case .num(let p) = a, case .num(let q) = b { return .num(p * q) }
            if case .neg(let c) = a { return .neg(.mul(c, b)) }
            if case .neg(let c) = b { return .neg(.mul(a, c)) }
            if case .num = b, !a.isNum { return .mul(b, a) }        // constantes devant : 2x
            if case .num(let p) = a, case .mul(.num(let q), let c) = b { return .mul(.num(p * q), c) }
            if case .mul(.num(let p), let c) = a { return .mul(.num(p), .mul(c, b)) }
            if case .div(let p, let q) = b, p == .num(1) { return .div(a, q) }
            if case .div(let p, let q) = a, p == .num(1) { return .div(b, q) }
            if case .div(let p, let q) = b, case .num = a, case .num = p { return .div(.mul(a, p), q) }
            if a == b { return .pow(a, .num(2)) }
            if case .pow(let base, let e) = a, base == b { return .pow(base, .add(e, .num(1))) }
            if case .pow(let base, let e) = b, base == a { return .pow(base, .add(e, .num(1))) }
            if case .pow(let b1, let e1) = a, case .pow(let b2, let e2) = b, b1 == b2 { return .pow(b1, .add(e1, e2)) }
            return .mul(a, b)
        case .div(let a, let b):
            let a = simp(a), b = simp(b)
            if a == .num(0) { return .num(0) }
            if b == .num(1) { return a }
            if a == b { return .num(1) }
            if case .num(let p) = a, case .num(let q) = b, q != 0 {
                if isInt(p), isInt(q) {
                    let g = gcd(Int(p), Int(q))
                    if g > 1 || q < 0 {
                        let s = q < 0 ? -1.0 : 1.0
                        let r = MathNode.div(.num(s * p / Double(g)), .num(s * q / Double(g)))
                        if case .div(_, .num(1)) = r, case .div(let top, _) = r { return top }
                        return r
                    }
                    return .div(a, b)
                }
                return .num(p / q)
            }
            if case .neg(let c) = a { return .neg(.div(c, b)) }
            if case .neg(let c) = b { return .neg(.div(a, c)) }
            if case .div(let p, let q) = a { return .div(p, .mul(q, b)) }
            if case .div(let p, let q) = b { return .div(.mul(a, q), p) }
            if case .mul(.num(let p), let c) = a, case .num(let q) = b, isInt(p), isInt(q), q != 0,
               p.truncatingRemainder(dividingBy: q) == 0 { return .mul(.num(p / q), c) }
            if case .pow(let base, let e) = a, base == b { return .pow(base, .sub(e, .num(1))) }
            return .div(a, b)
        case .pow(let a, let b):
            let a = simp(a), b = simp(b)
            if b == .num(0) { return .num(1) }
            if b == .num(1) { return a }
            if a == .num(1) { return .num(1) }
            if b == .num(0.5) { return .call("sqrt", a) }
            if case .num(let p) = a, case .num(let q) = b, isInt(q) {
                let r = Foundation.pow(p, q)
                if isInt(r) { return .num(r) }
            }
            if case .pow(let base, .num(let m)) = a, case .num(let k) = b { return .pow(base, .num(m * k)) }
            if case .call("sqrt", let inner) = a, b == .num(2) { return inner }
            return .pow(a, b)
        case .call(let f, let a):
            let a = simp(a)
            if case .num(let v) = a, let g = try? elementary(f) {
                let r = g(v)
                if r.isFinite, isInt(r) { return .num(r) }
            }
            if f == "ln", a == .const("e") { return .num(1) }
            if f == "ln", case .call("exp", let inner) = a { return inner }
            if f == "exp", case .call("ln", let inner) = a { return inner }
            if f == "exp" { return .pow(.const("e"), a) }
            if f == "ln", case .pow(.const("e"), let inner) = a { return inner }
            return .call(f, a)
        }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = Swift.abs(a), y = Swift.abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}

extension MathNode {
    var isNum: Bool { if case .num = self { return true }; return false }
}

// MARK: - Écriture : texte, LaTeX, pgfplots

enum MathFormat {
    /// 2.5 → « 2.5 », 3.0 → « 3 » (syntaxe de saisie).
    static func plain(_ v: Double, digits: Int = 10) -> String {
        if v.isNaN { return "indéfini" }
        if v.isInfinite { return v > 0 ? "+∞" : "-∞" }
        if v == v.rounded(), Swift.abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.\(digits)g", v)
        if s.contains("e") { return s }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// Affichage français : 2,5.
    static func fr(_ v: Double, digits: Int = 10) -> String {
        plain(v, digits: digits).replacingOccurrences(of: ".", with: ",")
    }

    /// Forme « exacte » probable d'un résultat : 1/3, 3π/4, √2… (nil si rien de convaincant).
    static func exactGuess(_ v: Double) -> String? {
        guard v.isFinite, v != v.rounded() else { return nil }
        let eps = 1e-9 * max(1, Swift.abs(v))
        func frac(_ x: Double) -> (Int, Int)? {
            for q in 2...12 {
                let p = (x * Double(q)).rounded()
                if Swift.abs(x - p / Double(q)) < eps { return (Int(p), q) }
            }
            return nil
        }
        if let f = frac(v) { return "\(f.0)/\(f.1)" }
        let r = v / Double.pi
        if Swift.abs(r - r.rounded()) < eps, r.rounded() != 0 {
            let k = Int(r.rounded())
            return k == 1 ? "π" : (k == -1 ? "-π" : "\(k)π")
        }
        if let f = frac(r) { return "\(f.0 == 1 ? "" : (f.0 == -1 ? "-" : "\(f.0)"))π/\(f.1)" }
        for n in [2, 3, 5, 6, 7] {
            let s = v / Foundation.sqrt(Double(n))
            if Swift.abs(s - s.rounded()) < eps, s.rounded() != 0 {
                let k = Int(s.rounded())
                return (k == 1 ? "" : (k == -1 ? "-" : "\(k)")) + "√\(n)"
            }
            if let f = frac(s) { return "\(f.0 == 1 ? "" : (f.0 == -1 ? "-" : "\(f.0)"))√\(n)/\(f.1)" }
        }
        let l = v / M_E
        if Swift.abs(l - l.rounded()) < eps, l.rounded() != 0 { return "\(Int(l.rounded()) == 1 ? "" : "\(Int(l.rounded()))")e" }
        return nil
    }

    private static func prec(_ n: MathNode) -> Int {
        switch n {
        case .add, .sub: return 1
        case .mul, .div: return 2
        case .neg: return 2
        case .pow: return 3
        case .num(let v): return v < 0 ? 2 : 4
        default: return 4
        }
    }

    // Texte saisissable (pour remettre une dérivée dans la liste des fonctions).
    static func text(_ n: MathNode) -> String {
        func wrap(_ m: MathNode, _ need: Bool) -> String { need ? "(\(text(m)))" : text(m) }
        switch n {
        case .num(let v): return plain(v)
        case .x: return "x"
        case .const(let c): return c == "inf" ? "∞" : (c == "pi" ? "π" : c)
        case .variable(let v): return v
        case .neg(let a): return "-" + wrap(a, prec(a) <= 1)
        case .add(let a, let b): return text(a) + " + " + wrap(b, prec(b) <= 1 || isNeg(b))
        case .sub(let a, let b): return text(a) + " - " + wrap(b, prec(b) <= 1 || isNeg(b))
        case .mul(let a, let b):
            let l = wrap(a, prec(a) < 2), r = wrap(b, prec(b) < 2 || isNeg(b))
            if a.isNum, !b.isNum, r.first?.isNumber == false { return l + r }
            return l + "*" + r
        case .div(let a, let b): return wrap(a, prec(a) < 2) + "/" + wrap(b, prec(b) < 4)
        case .pow(let a, let b): return wrap(a, prec(a) < 4) + "^" + wrap(b, prec(b) < 4)
        case .call(let f, let a): return "\(f)(\(text(a)))"
        case .user(let f, let p, let a): return f + String(repeating: "'", count: p) + "(\(text(a)))"
        case .fact(let a): return wrap(a, prec(a) < 4) + "!"
        }
    }

    private static func isNeg(_ n: MathNode) -> Bool {
        if case .neg = n { return true }
        if case .num(let v) = n, v < 0 { return true }
        return false
    }

    static func latexNumber(_ v: Double) -> String {
        if v.isInfinite { return v > 0 ? "+\\infty" : "-\\infty" }
        return plain(v).replacingOccurrences(of: ".", with: "{,}")
    }

    static let trig: Set<String> = ["sin", "cos", "tan", "cot", "sinh", "cosh", "tanh", "ln", "log", "arcsin", "arccos", "arctan"]

    static func latex(_ n: MathNode) -> String {
        func paren(_ s: String) -> String { "\\left(" + s + "\\right)" }
        func wrap(_ m: MathNode, _ need: Bool) -> String { need ? paren(latex(m)) : latex(m) }
        func isAtom(_ m: MathNode) -> Bool {
            switch m {
            case .x, .variable, .const: return true
            case .num(let v): return v >= 0
            default: return false
            }
        }
        func command(_ f: String) -> String {
            switch f {
            case "log2": return "\\log_2"
            case "sign": return "\\operatorname{sgn}"
            case "cot": return "\\cot"
            default: return "\\" + f
            }
        }
        switch n {
        case .num(let v): return latexNumber(v)
        case .x: return "x"
        case .const(let c): return c == "pi" ? "\\pi" : (c == "e" ? "\\mathrm{e}" : "\\infty")
        case .variable(let v): return v == "ans" ? "\\mathrm{ans}" : v
        case .neg(let a): return "-" + wrap(a, prec(a) <= 1)
        case .add(let a, let b): return latex(a) + " + " + wrap(b, prec(b) <= 1 || isNeg(b))
        case .sub(let a, let b): return latex(a) + " - " + wrap(b, prec(b) <= 1 || isNeg(b))
        case .mul(let a, let b):
            let l = wrap(a, prec(a) < 2), r = wrap(b, prec(b) < 2 || isNeg(b))
            let rStartsDigit = r.first?.isNumber == true
            if rStartsDigit || (a.isNum && r.hasPrefix("\\frac")) || (isFracLike(a) && b.isNum) { return l + " \\times " + r }
            return l + " " + r
        case .div(let a, let b): return "\\frac{" + latex(a) + "}{" + latex(b) + "}"
        case .pow(let a, let b):
            if a == .const("e") { return "\\mathrm{e}^{" + latex(b) + "}" }
            if b == .num(0.5) { return "\\sqrt{" + latex(a) + "}" }
            if case .div(.num(1), .num(let q)) = b, q == q.rounded(), q > 1 {
                return "\\sqrt[" + plain(q) + "]{" + latex(a) + "}"
            }
            if case .call(let f, let arg) = a, trig.contains(f), case .num(let k) = b, k > 0, k == k.rounded() {
                return command(f) + "^{" + plain(k) + "}" + wrap(arg, true)
            }
            let base = (prec(a) < 4 || isNeg(a) || isFracLike(a)) ? paren(latex(a)) : latex(a)
            return base + "^{" + latex(b) + "}"
        case .call(let f, let a):
            switch f {
            case "sqrt": return "\\sqrt{" + latex(a) + "}"
            case "cbrt": return "\\sqrt[3]{" + latex(a) + "}"
            case "abs": return "\\left|" + latex(a) + "\\right|"
            case "floor": return "\\left\\lfloor " + latex(a) + " \\right\\rfloor"
            case "ceil": return "\\left\\lceil " + latex(a) + " \\right\\rceil"
            case "exp": return "\\mathrm{e}^{" + latex(a) + "}"
            default: return command(f) + (isAtom(a) ? " " + latex(a) : paren(latex(a)))
            }
        case .user(let f, let p, let a): return f + String(repeating: "'", count: p) + paren(latex(a))
        case .fact(let a): return wrap(a, prec(a) < 4) + "!"
        }
    }

    private static func isFracLike(_ n: MathNode) -> Bool {
        if case .div = n { return true }
        return false
    }

    /// Syntaxe pgfplots (les fonctions trigo de pgf travaillent en degrés).
    static func pgf(_ n: MathNode, env: MathEnv) -> String {
        func p(_ m: MathNode) -> String { pgf(m, env: env) }
        switch n {
        case .num(let v): return plain(v)
        case .x: return "x"
        case .const(let c): return c == "pi" ? "pi" : (c == "e" ? "e" : "inf")
        case .variable(let v): return env.variables[v].map { "(" + plain($0) + ")" } ?? v
        case .neg(let a): return "-(" + p(a) + ")"
        case .add(let a, let b): return "(" + p(a) + ")+(" + p(b) + ")"
        case .sub(let a, let b): return "(" + p(a) + ")-(" + p(b) + ")"
        case .mul(let a, let b): return "(" + p(a) + ")*(" + p(b) + ")"
        case .div(let a, let b): return "(" + p(a) + ")/(" + p(b) + ")"
        case .pow(let a, let b): return "(" + p(a) + ")^(" + p(b) + ")"
        case .fact(let a): return "factorial(" + p(a) + ")"
        case .user(let f, let primes, let a):
            if let inl = try? MathEngine.inline(.user(f, primes, a), env: env) { return p(MathEngine.simplify(inl)) }
            return f + "(" + p(a) + ")"
        case .call(let f, let a):
            let u = p(a)
            switch f {
            case "sin", "cos", "tan", "cot": return "\(f)(deg(\(u)))"
            case "arcsin": return "rad(asin(\(u)))"
            case "arccos": return "rad(acos(\(u)))"
            case "arctan": return "rad(atan(\(u)))"
            case "sinh", "cosh", "tanh", "exp", "ln", "sqrt", "abs", "floor", "ceil": return "\(f)(\(u))"
            case "log": return "log10(\(u))"
            case "log2": return "ln(\(u))/ln(2)"
            case "cbrt": return "sign(\(u))*abs(\(u))^(1/3)"
            case "sign": return "sign(\(u))"
            default: return "\(f)(\(u))"
            }
        }
    }
}

// MARK: - Analyse numérique

enum MathAnalysis {
    struct LimitRow: Identifiable {
        let id = UUID()
        let x: Double
        let left: Double?
        let right: Double?
    }

    struct LimitResult {
        var rows: [LimitRow]
        var verdict: String
        var detail: String
    }

    /// Valeur vers laquelle semble tendre une suite de valeurs (nil = pas de convergence visible).
    static func trend(_ values: [Double]) -> (kind: Int, value: Double)? {
        // kind : 0 = fini, 1 = +∞, -1 = -∞
        if let last = values.last, last.isInfinite { return (last > 0 ? 1 : -1, last) }
        guard values.count >= 3 else { return nil }
        let a = values[values.count - 3], b = values[values.count - 2], c = values[values.count - 1]
        guard a.isFinite, b.isFinite, c.isFinite else { return nil }
        if Swift.abs(c) > 1e5, Swift.abs(c) > Swift.abs(b) * 1.5, Swift.abs(b) > Swift.abs(a) * 1.5, (a > 0) == (c > 0), (b > 0) == (c > 0) {
            return (c > 0 ? 1 : -1, c)
        }
        let tol = 1e-3 * max(1, Swift.abs(c))
        if Swift.abs(c - b) < tol, Swift.abs(c - b) <= Swift.abs(b - a) + 1e-12 { return (0, c) }
        return nil
    }

    static func nice(_ v: Double) -> String {
        if Swift.abs(v - v.rounded()) < 2e-4 { return MathFormat.fr(v.rounded() == 0 ? 0 : v.rounded()) }
        for q in 2...12 {
            let p = (v * Double(q)).rounded()
            if Swift.abs(v - p / Double(q)) < 2e-4 { return "\(Int(p))/\(q)" }
        }
        let r = v / Double.pi
        for q in 1...6 {
            let p = (r * Double(q)).rounded()
            if p != 0, Swift.abs(r - p / Double(q)) < 1e-4 {
                let num = p == 1 ? "π" : (p == -1 ? "-π" : "\(Int(p))π")
                return q == 1 ? num : "\(num)/\(q)"
            }
        }
        if Swift.abs(v - M_E) < 2e-4 { return "e" }
        return "≈ " + MathFormat.fr((v * 10000).rounded() / 10000)
    }

    private static func describe(_ t: (kind: Int, value: Double)?) -> String? {
        guard let t = t else { return nil }
        if t.kind == 1 { return "+∞" }
        if t.kind == -1 { return "-∞" }
        return nice(t.value)
    }

    /// Estimation numérique d'une limite en a (a = ±∞ accepté).
    static func limit(_ f: MathEngine.Fn, at a: Double) -> LimitResult {
        if a.isInfinite {
            let xs = (1...8).map { (a > 0 ? 1.0 : -1.0) * Foundation.pow(10, Double($0)) }
            let ys = xs.map(f)
            let rows = zip(xs, ys).map { LimitRow(x: $0.0, left: a < 0 ? $0.1 : nil, right: a > 0 ? $0.1 : nil) }
            let label = a > 0 ? "+∞" : "-∞"
            if let d = describe(trend(ys)) {
                return LimitResult(rows: rows, verdict: "lim f(x) en \(label) : \(d)", detail: "")
            }
            return LimitResult(rows: rows, verdict: "Pas de limite visible en \(label)",
                               detail: "Les valeurs ne se stabilisent pas (fonction qui oscille ?).")
        }
        let hs = (1...7).map { Foundation.pow(10, -Double($0)) }
        let left = hs.map { f(a - $0) }, right = hs.map { f(a + $0) }
        let rows = hs.indices.map { LimitRow(x: hs[$0], left: left[$0], right: right[$0]) }
        let L = describe(trend(Array(left.prefix(6)))), R = describe(trend(Array(right.prefix(6))))
        let point = MathFormat.fr(a)
        switch (L, R) {
        case let (l?, r?) where l == r:
            return LimitResult(rows: rows, verdict: "lim f(x) quand x → \(point) : \(l)", detail: "Même valeur à gauche et à droite.")
        case let (l?, r?):
            return LimitResult(rows: rows, verdict: "Pas de limite en \(point)",
                               detail: "À gauche : \(l) · à droite : \(r) (limites à gauche et à droite différentes).")
        case let (l?, nil):
            let rightDefined = right.contains { $0.isFinite }
            return LimitResult(rows: rows, verdict: "Limite à gauche en \(point) : \(l)",
                               detail: rightDefined ? "À droite, pas de stabilisation." : "f n'est pas définie à droite de \(point).")
        case let (nil, r?):
            let leftDefined = left.contains { $0.isFinite }
            return LimitResult(rows: rows, verdict: "Limite à droite en \(point) : \(r)",
                               detail: leftDefined ? "À gauche, pas de stabilisation." : "f n'est pas définie à gauche de \(point).")
        default:
            return LimitResult(rows: rows, verdict: "Pas de limite visible en \(point)", detail: "Les valeurs ne se stabilisent d'aucun côté.")
        }
    }

    /// Changements de signe de f sur [a, b] affinés par dichotomie (ignore les sauts type 1/x).
    static func roots(_ f: MathEngine.Fn, from a: Double, to b: Double, samples: Int = 1600) -> [Double] {
        guard b > a else { return [] }
        var result: [Double] = []
        let step = (b - a) / Double(samples)
        var x0 = a, y0 = f(a)
        let scale = max(1e-9, (b - a) * 1e-9)
        for i in 1...samples {
            let x1 = a + Double(i) * step
            let y1 = f(x1)
            if y0.isFinite, y1.isFinite {
                if y0 == 0 {
                    if result.last.map({ Swift.abs($0 - x0) > step }) ?? true { result.append(x0) }
                } else if (y0 < 0) != (y1 < 0), y1 != 0 {
                    var lo = x0, hi = x1, flo = y0
                    for _ in 0..<80 {
                        let m = (lo + hi) / 2
                        let fm = f(m)
                        if !fm.isFinite { break }
                        if (fm < 0) == (flo < 0) { lo = m; flo = fm } else { hi = m }
                        if hi - lo < scale { break }
                    }
                    let r = (lo + hi) / 2
                    let fr = f(r)
                    // vraie racine (pas une asymptote où f saute de -∞ à +∞)
                    if fr.isFinite, Swift.abs(fr) < 1e-6 * max(1, Swift.abs(y0), Swift.abs(y1)) {
                        if result.last.map({ Swift.abs($0 - r) > step / 2 }) ?? true { result.append(r) }
                    }
                }
            }
            x0 = x1; y0 = y1
        }
        return result
    }

    /// Valeur arrondie pour l'affichage d'une abscisse trouvée numériquement.
    static func clean(_ v: Double) -> Double {
        let r = (v * 1e9).rounded() / 1e9
        return Swift.abs(r) < 1e-10 ? 0 : r
    }

    /// Pas « rond » (1, 2, 5 × 10^n) pour une graduation.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let p = Foundation.pow(10, Foundation.floor(Foundation.log10(raw)))
        let m = raw / p
        return (m < 1.5 ? 1 : (m < 3.5 ? 2 : (m < 7.5 ? 5 : 10))) * p
    }
}
