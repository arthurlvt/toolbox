import SwiftUI
import AppKit

// MARK: - Modes de la calculatrice

enum CalcMode: String, CaseIterable, Identifiable {
    case graph, scientific, programmer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graph: return "Graphique"
        case .scientific: return "Scientifique"
        case .programmer: return "Programmeur"
        }
    }
    var icon: String {
        switch self {
        case .graph: return "chart.xyaxis.line"
        case .scientific: return "function"
        case .programmer: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Scientifique

/// Calculatrice « comme sur le Mac » : on tape (ou on clique) une expression, le résultat s'affiche en direct.
final class SciCalc: ObservableObject {
    static let shared = SciCalc()

    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        var expression: String
        var result: String
    }

    @Published var expression = "" { didSet { preview() } }
    @Published private(set) var live = ""
    @Published private(set) var error = ""
    @Published var degrees = UserDefaults.standard.bool(forKey: "sci.deg") {
        didSet { UserDefaults.standard.set(degrees, forKey: "sci.deg"); preview() }
    }
    @Published var second = false
    @Published private(set) var memory: Double?
    @Published var history: [Entry] = [] {
        didSet { if let d = try? JSONEncoder().encode(history) { UserDefaults.standard.set(d, forKey: "sci.history") } }
    }
    private var ans = 0.0
    private var justEvaluated = false

    init() {
        if let d = UserDefaults.standard.data(forKey: "sci.history"), let h = try? JSONDecoder().decode([Entry].self, from: d) { history = h }
        ans = UserDefaults.standard.double(forKey: "sci.ans")
    }

    // MARK: Calcul

    /// Ajoute les « ) » manquantes, % → /100, virgule → point, EE → ×10^.
    static func prepare(_ s: String) -> String {
        var t = s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "/100")
        let open = t.filter { $0 == "(" }.count - t.filter { $0 == ")" }.count
        if open > 0 { t += String(repeating: ")", count: open) }
        return t
    }

    /// En degrés : sin(30) = sin(30·π/180), arcsin(x) rendu en degrés.
    static func toDegrees(_ n: MathNode) -> MathNode {
        let k = Double.pi / 180
        switch n {
        case .call(let f, let a):
            let a2 = toDegrees(a)
            switch f {
            case "sin", "cos", "tan", "cot": return .call(f, .mul(a2, .num(k)))
            case "arcsin", "arccos", "arctan": return .mul(.call(f, a2), .num(1 / k))
            default: return .call(f, a2)
            }
        case .neg(let a): return .neg(toDegrees(a))
        case .add(let a, let b): return .add(toDegrees(a), toDegrees(b))
        case .sub(let a, let b): return .sub(toDegrees(a), toDegrees(b))
        case .mul(let a, let b): return .mul(toDegrees(a), toDegrees(b))
        case .div(let a, let b): return .div(toDegrees(a), toDegrees(b))
        case .pow(let a, let b): return .pow(toDegrees(a), toDegrees(b))
        case .fact(let a): return .fact(toDegrees(a))
        case .user(let f, let p, let a): return .user(f, p, toDegrees(a))
        default: return n
        }
    }

    func value(of text: String) throws -> Double {
        let t = Self.prepare(text)
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { throw MathError(message: "") }
        var node = try MathEngine.parse(t)
        if node.containsX { throw MathError(message: "Pas de x ici : utilise le mode Graphique") }
        if degrees { node = Self.toDegrees(node) }
        var env = MathEnv()
        env.variables["ans"] = ans
        return try MathEngine.evaluate(node, env: env)
    }

    static func show(_ v: Double) -> String {
        guard v.isFinite else { return v.isNaN ? "Erreur" : (v > 0 ? "∞" : "−∞") }
        if v != 0, Swift.abs(v) >= 1e15 || Swift.abs(v) < 1e-9 {
            let s = String(format: "%.10e", v)            // 1.2345678900e+20
            let parts = s.split(separator: "e")
            var mant = String(parts[0])
            while mant.contains("."), mant.hasSuffix("0") { mant.removeLast() }
            if mant.hasSuffix(".") { mant.removeLast() }
            let exp = Int(parts[1]) ?? 0
            return mant.replacingOccurrences(of: ".", with: ",") + " × 10^\(exp)"
        }
        return MathFormat.fr(v, digits: 12)
    }

    private func preview() {
        do {
            let v = try value(of: expression)
            live = Self.show(v)
            error = ""
        } catch {
            live = ""
            self.error = expression.isEmpty ? "" : error.localizedDescription
        }
    }

    func evaluate() {
        guard !expression.isEmpty else { return }
        do {
            let v = try value(of: expression)
            ans = v
            UserDefaults.standard.set(v, forKey: "sci.ans")
            let shown = Self.show(v)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                history.insert(Entry(expression: Self.prepare(expression), result: shown), at: 0)
                if history.count > 60 { history.removeLast(history.count - 60) }
            }
            expression = v.isFinite ? MathFormat.fr(v, digits: 12) : ""
            justEvaluated = true
        } catch {
            self.error = error.localizedDescription
            NSSound.beep()
        }
    }

    // MARK: Touches

    func type(_ s: String) {
        let startsNew = justEvaluated && (s.first?.isNumber == true || s == "," || s.hasSuffix("("))
        if startsNew { expression = "" }
        justEvaluated = false
        expression += s
    }

    func clear() { expression = ""; justEvaluated = false }

    func backspace() {
        justEvaluated = false
        // supprime un nom de fonction entier : « sin( » d'un coup
        for token in ["arcsin(", "arccos(", "arctan(", "sinh(", "cosh(", "tanh(", "sin(", "cos(", "tan(", "ln(", "log(", "log2(", "sqrt(", "cbrt(", "e^(", "10^(", "2^(", "×10^(", "ans"] {
            if expression.hasSuffix(token) { expression.removeLast(token.count); return }
        }
        if !expression.isEmpty { expression.removeLast() }
    }

    func negate() {
        justEvaluated = false
        if expression.hasPrefix("-(") && expression.hasSuffix(")") {
            expression = String(expression.dropFirst(2).dropLast())
        } else if !expression.isEmpty {
            expression = "-(" + expression + ")"
        }
    }

    func inverse() {
        justEvaluated = false
        expression = expression.isEmpty ? "1/" : "1/(" + expression + ")"
    }

    func memoryOp(_ op: String) {
        switch op {
        case "mc": memory = nil
        case "mr": if let m = memory { type(MathFormat.fr(m, digits: 12)) }
        default:
            guard let v = try? value(of: expression) else { NSSound.beep(); return }
            memory = (memory ?? 0) + (op == "m+" ? v : -v)
            justEvaluated = true
        }
    }

    func random() { type(MathFormat.fr(Double.random(in: 0..<1), digits: 10)) }
}

struct ScientificCalcView: View {
    @ObservedObject var s = SciCalc.shared

    private struct Key: Identifiable {
        var id: String { label + action }
        let label: String
        let action: String
        var kind = 0          // 0 fonction, 1 chiffre, 2 opérateur, 3 commande
    }

    private var keys: [[Key]] {
        let sec = s.second
        return [
            [Key(label: "(", action: "("), Key(label: ")", action: ")"), Key(label: "mc", action: "#mc"), Key(label: "m+", action: "#m+"),
             Key(label: "m−", action: "#m-"), Key(label: "mr", action: "#mr"),
             Key(label: "AC", action: "#ac", kind: 3), Key(label: "⌫", action: "#bs", kind: 3), Key(label: "%", action: "%", kind: 3), Key(label: "÷", action: "÷", kind: 2)],
            [Key(label: "2nde", action: "#2nd"), Key(label: "x²", action: "²"), Key(label: "x³", action: "³"), Key(label: "xʸ", action: "^("),
             Key(label: sec ? "2ˣ" : "eˣ", action: sec ? "2^(" : "e^("), Key(label: "10ˣ", action: "10^("),
             Key(label: "7", action: "7", kind: 1), Key(label: "8", action: "8", kind: 1), Key(label: "9", action: "9", kind: 1), Key(label: "×", action: "×", kind: 2)],
            [Key(label: "1/x", action: "#inv"), Key(label: "√x", action: "sqrt("), Key(label: "∛x", action: "cbrt("), Key(label: "ʸ√x", action: "^(1/"),
             Key(label: sec ? "log₂" : "ln", action: sec ? "log2(" : "ln("), Key(label: "log₁₀", action: "log("),
             Key(label: "4", action: "4", kind: 1), Key(label: "5", action: "5", kind: 1), Key(label: "6", action: "6", kind: 1), Key(label: "−", action: "−", kind: 2)],
            [Key(label: "x!", action: "!"), Key(label: sec ? "sin⁻¹" : "sin", action: sec ? "arcsin(" : "sin("),
             Key(label: sec ? "cos⁻¹" : "cos", action: sec ? "arccos(" : "cos("), Key(label: sec ? "tan⁻¹" : "tan", action: sec ? "arctan(" : "tan("),
             Key(label: "e", action: "e"), Key(label: "EE", action: "×10^("),
             Key(label: "1", action: "1", kind: 1), Key(label: "2", action: "2", kind: 1), Key(label: "3", action: "3", kind: 1), Key(label: "+", action: "+", kind: 2)],
            [Key(label: s.degrees ? "Deg" : "Rad", action: "#deg"), Key(label: "sinh", action: "sinh("), Key(label: "cosh", action: "cosh("),
             Key(label: "tanh", action: "tanh("), Key(label: "π", action: "π"), Key(label: "Rand", action: "#rand"),
             Key(label: "±", action: "#neg", kind: 1), Key(label: "0", action: "0", kind: 1), Key(label: ",", action: ",", kind: 1), Key(label: "=", action: "#eq", kind: 2)],
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 12) {
                display
                VStack(spacing: 6) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) { ForEach(row) { key($0) } }
                    }
                }
            }
            .frame(minWidth: 560, maxWidth: 720)
            historyPanel.frame(width: 240)
        }
    }

    private var display: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Text(s.degrees ? "DEG" : "RAD").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                if s.memory != nil { Text("M").font(.caption2.weight(.bold)).foregroundStyle(Color.orange) }
                if s.second { Text("2nde").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor) }
                Spacer()
            }
            TextField("0", text: $s.expression)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .onSubmit { s.evaluate() }
            Text(s.live.isEmpty ? (s.error.isEmpty ? " " : s.error) : "= " + s.live)
                .font(.system(size: s.live.isEmpty ? 12 : 34, weight: .semibold, design: .rounded))
                .foregroundStyle(s.live.isEmpty ? Color.orange : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.4)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }

    private func key(_ k: Key) -> some View {
        let bg: Color
        switch k.kind {
        case 1: bg = Color.primary.opacity(0.10)
        case 2: bg = Color.orange
        case 3: bg = Color.primary.opacity(0.18)
        default: bg = Color.primary.opacity(k.action == "#2nd" && s.second ? 0.3 : 0.05)
        }
        return Button { press(k.action) } label: {
            Text(k.label)
                .font(.system(size: k.kind == 1 || k.kind == 2 ? 20 : 15, weight: k.kind == 2 ? .semibold : .regular, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(k.kind == 2 ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 10).fill(bg))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func press(_ a: String) {
        switch a {
        case "#ac": s.clear()
        case "#bs": s.backspace()
        case "#eq": s.evaluate()
        case "#neg": s.negate()
        case "#inv": s.inverse()
        case "#2nd": s.second.toggle()
        case "#deg": s.degrees.toggle()
        case "#rand": s.random()
        case "#mc", "#mr", "#m+", "#m-": s.memoryOp(String(a.dropFirst()))
        default:
            s.type(a)
            if s.second, a.hasSuffix("(") { s.second = false }
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Historique").font(.headline)
                Spacer()
                if !s.history.isEmpty {
                    Button("Effacer") { withAnimation { s.history = [] } }.buttonStyle(.borderless).font(.caption)
                }
            }
            ScrollView {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(s.history) { e in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(e.expression).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            Text(e.result).font(.callout.weight(.semibold).monospacedDigit())
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture { s.type(e.result.replacingOccurrences(of: " × 10^", with: "×10^")) }
                        .contextMenu {
                            Button("Reprendre le calcul") { s.expression = e.expression }
                            Button("Copier le résultat") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(e.result, forType: .string)
                            }
                        }
                    }
                }
            }
            Text("Clic : insère le résultat · Entrée : calcule · « ans » : dernier résultat")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }
}

// MARK: - Programmeur

/// Calculatrice entière : bases 2 / 8 / 10 / 16, 8 à 64 bits, signé ou non, opérations bit à bit.
final class ProgCalc: ObservableObject {
    static let shared = ProgCalc()

    enum Base: Int, CaseIterable, Identifiable {
        case hex = 16, dec = 10, oct = 8, bin = 2
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .hex: return "HEX"
            case .dec: return "DEC"
            case .oct: return "OCT"
            case .bin: return "BIN"
            }
        }
    }

    @Published var base = Base(rawValue: UserDefaults.standard.object(forKey: "prog.base") as? Int ?? 10) ?? .dec {
        didSet { UserDefaults.standard.set(base.rawValue, forKey: "prog.base") }
    }
    @Published var bits = UserDefaults.standard.object(forKey: "prog.bits") as? Int ?? 32 {
        didSet { UserDefaults.standard.set(bits, forKey: "prog.bits"); value &= mask; lhs &= mask }
    }
    @Published var signed = UserDefaults.standard.object(forKey: "prog.signed") as? Bool ?? true {
        didSet { UserDefaults.standard.set(signed, forKey: "prog.signed") }
    }
    @Published var value: UInt64 = 0
    @Published private(set) var pending: String?
    @Published private(set) var lhs: UInt64 = 0
    @Published var error = ""
    private var typing = false

    static let sizes = [8, 16, 32, 64]

    var mask: UInt64 { bits >= 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1 }

    func signedValue(_ v: UInt64) -> Int64 {
        let m = v & mask
        if bits >= 64 { return Int64(bitPattern: m) }
        let signBit = UInt64(1) << UInt64(bits - 1)
        return m & signBit != 0 ? Int64(bitPattern: m | ~mask) : Int64(m)
    }

    func text(_ v: UInt64, base b: Base) -> String {
        let m = v & mask
        switch b {
        case .dec: return signed ? String(signedValue(m)) : String(m)
        case .hex: return Self.group(String(m, radix: 16).uppercased(), 4)
        case .oct: return Self.group(String(m, radix: 8), 3)
        case .bin: return Self.group(String(m, radix: 2), 4)
        }
    }

    static func group(_ s: String, _ n: Int) -> String {
        var out = ""
        for (i, c) in s.reversed().enumerated() {
            if i > 0 && i % n == 0 { out.append(" ") }
            out.append(c)
        }
        return String(out.reversed())
    }

    var character: String? {
        let m = value & mask
        guard m >= 32, m != 127, m < 0x110000, let u = UnicodeScalar(UInt32(m)) else { return nil }
        return String(Character(u))
    }

    // MARK: Saisie

    func digit(_ d: Int) {
        guard d < base.rawValue else { NSSound.beep(); return }
        error = ""
        if !typing { value = 0; typing = true }
        let (mul, o1) = value.multipliedReportingOverflow(by: UInt64(base.rawValue))
        let (next, o2) = mul.addingReportingOverflow(UInt64(d))
        guard !o1, !o2, next & ~mask == 0 else { NSSound.beep(); return }
        value = next
    }

    func backspace() {
        guard typing else { return }
        value /= UInt64(base.rawValue)
    }

    func clear() { value = 0; pending = nil; lhs = 0; typing = false; error = "" }
    func clearEntry() { value = 0; typing = false }

    // MARK: Opérations

    static let binary = ["+", "−", "×", "÷", "mod", "AND", "OR", "XOR", "NOR", "<<", ">>"]

    func op(_ o: String) {
        if pending != nil, typing { equals(keepPending: true) }
        lhs = value
        pending = o
        typing = false
    }

    func equals(keepPending: Bool = false) {
        guard let o = pending else { return }
        let a = lhs & mask, b = value & mask
        var r: UInt64
        switch o {
        case "+": r = a &+ b
        case "−": r = a &- b
        case "×": r = a &* b
        case "÷", "mod":
            guard b != 0 else { clear(); error = "Division par zéro"; NSSound.beep(); return }
            if signed {
                let x = signedValue(a), y = signedValue(b)
                if x == Int64.min && y == -1 { r = UInt64(bitPattern: x) } else { r = UInt64(bitPattern: o == "÷" ? x / y : x % y) }
            } else {
                r = o == "÷" ? a / b : a % b
            }
        case "AND": r = a & b
        case "OR": r = a | b
        case "XOR": r = a ^ b
        case "NOR": r = ~(a | b)
        case "<<": r = b >= 64 ? 0 : a << b
        case ">>":
            if signed { r = b >= 64 ? (signedValue(a) < 0 ? UInt64.max : 0) : UInt64(bitPattern: signedValue(a) >> Int64(b)) }
            else { r = b >= 64 ? 0 : a >> b }
        default: r = b
        }
        value = r & mask
        lhs = value
        typing = false
        if !keepPending { pending = nil }
    }

    func unary(_ o: String) {
        let v = value & mask
        switch o {
        case "NOT": value = ~v & mask
        case "±": value = (0 &- v) & mask
        case "<<1": value = (v << 1) & mask
        case ">>1": value = signed ? UInt64(bitPattern: signedValue(v) >> 1) & mask : v >> 1
        case "RoL": value = ((v << 1) | (v >> UInt64(bits - 1))) & mask
        case "RoR": value = ((v >> 1) | ((v & 1) << UInt64(bits - 1))) & mask
        case "flip":  // inverse l'ordre des octets
            var out: UInt64 = 0, x = v
            for _ in 0..<(bits / 8) { out = (out << 8) | (x & 0xFF); x >>= 8 }
            value = out & mask
        default: break
        }
        typing = false
    }

    func toggleBit(_ i: Int) {
        guard i < bits else { return }
        value ^= UInt64(1) << UInt64(i)
        typing = false
    }

    private var monitor: Any?

    func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // pas quand on écrit dans un champ texte
            if NSApp.keyWindow?.firstResponder is NSTextView { return e }
            return self?.handle(e) == true ? nil : e
        }
    }

    func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// Clavier : chiffres et A–F, + - * /, Entrée, ⌫, Échap, & | ^ ~ < >.
    func handle(_ e: NSEvent) -> Bool {
        guard let chars = e.charactersIgnoringModifiers?.lowercased(), let c = chars.first else { return false }
        if e.modifierFlags.intersection([.command, .control]).isEmpty == false { return false }
        switch e.keyCode {
        case 51: backspace(); return true          // ⌫
        case 53: clear(); return true              // Échap
        case 36, 76: equals(); return true         // Entrée
        default: break
        }
        if let d = Int(String(c), radix: 16), c.isHexDigit { digit(d); return true }
        switch c {
        case "+": op("+")
        case "-": op("−")
        case "*": op("×")
        case "/": op("÷")
        case "%": op("mod")
        case "&": op("AND")
        case "|": op("OR")
        case "^": op("XOR")
        case "~": unary("NOT")
        case "<": op("<<")
        case ">": op(">>")
        case "=": equals()
        default: return false
        }
        return true
    }
}

struct ProgrammerCalcView: View {
    @ObservedObject var p = ProgCalc.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("Taille", selection: $p.bits) {
                    ForEach(ProgCalc.sizes, id: \.self) { Text("\($0) bits").tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 300)
                Toggle("Signé (complément à 2)", isOn: $p.signed).toggleStyle(.switch)
                Spacer()
                if !p.error.isEmpty { Text(p.error).foregroundStyle(Color.red).font(.callout) }
            }
            display
            bitGrid
            keypad
        }
        .frame(maxWidth: 900)
        .onAppear { p.installMonitor() }
        .onDisappear { p.removeMonitor() }
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let o = p.pending {
                    Text("\(p.text(p.lhs, base: p.base)) \(o)").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if let ch = p.character { Text("« \(ch) »").font(.callout).foregroundStyle(.secondary).help("Caractère Unicode") }
            }
            Text(p.text(p.value, base: p.base))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.3)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
            ForEach(ProgCalc.Base.allCases) { b in
                Button { p.base = b } label: {
                    HStack(spacing: 10) {
                        Text(b.title).font(.caption.weight(.bold)).frame(width: 34, alignment: .leading)
                            .foregroundStyle(p.base == b ? Color.accentColor : Color.secondary)
                        Text(p.text(p.value, base: b)).font(.system(size: 12, design: .monospaced))
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(p.base == b ? Color.accentColor.opacity(0.12) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Saisir en \(b.title)")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }

    /// Les bits, cliquables (comme sur la calculatrice du Mac).
    private var bitGrid: some View {
        let rows = max(1, p.bits / 16)
        let groups = min(4, p.bits / 4)
        return VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { r in
                let top = p.bits - 1 - r * 16
                HStack(spacing: 10) {
                    ForEach(0..<groups, id: \.self) { g in
                        VStack(spacing: 1) {
                            HStack(spacing: 3) {
                                ForEach(0..<4, id: \.self) { k in
                                    let i = top - g * 4 - k
                                    let on = (p.value >> UInt64(i)) & 1 == 1
                                    Text(on ? "1" : "0")
                                        .font(.system(size: 13, weight: on ? .bold : .regular, design: .monospaced))
                                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                                        .frame(width: 14)
                                        .contentShape(Rectangle())
                                        .onTapGesture { p.toggleBit(i) }
                                }
                            }
                            Text("\(top - g * 4 - 3)").font(.system(size: 8)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var keypad: some View {
        let rows: [[String]] = [
            ["AND", "OR", "XOR", "NOR", "NOT", "AC", "C", "⌫"],
            ["<<", ">>", "<<1", ">>1", "D", "E", "F", "÷"],
            ["RoL", "RoR", "flip", "mod", "A", "B", "C̲", "×"],
            ["", "", "", "", "7", "8", "9", "−"],
            ["", "", "", "", "4", "5", "6", "+"],
            ["", "", "", "", "1", "2", "3", "="],
            ["", "", "", "", "±", "0", "FF", "00"],
        ]
        return VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, k in keyButton(k) }
                }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ k: String) -> some View {
        if k.isEmpty {
            Color.clear.frame(maxWidth: .infinity, minHeight: 38)
        } else {
            let label = k == "C̲" ? "C" : k
            let hexDigit = ["A", "B", "C̲", "D", "E", "F"].contains(k)
            let digitValue: Int? = hexDigit ? Int(label, radix: 16) : Int(k)
            let disabled = digitValue.map { $0 >= p.base.rawValue } ?? (k == "FF" || k == "00" ? p.base != .hex : false)
            let isOp = ProgCalc.binary.contains(k) || k == "="
            Button {
                if let d = digitValue { p.digit(d) }
                else if k == "FF" { p.digit(15); p.digit(15) }
                else if k == "00" { p.digit(0); p.digit(0) }
                else if k == "AC" { p.clear() }
                else if k == "C" { p.clearEntry() }
                else if k == "⌫" { p.backspace() }
                else if k == "=" { p.equals() }
                else if ProgCalc.binary.contains(k) { p.op(k) }
                else { p.unary(k) }
            } label: {
                Text(label)
                    .font(.system(size: digitValue != nil ? 18 : 13, weight: isOp ? .semibold : .regular, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .foregroundStyle(isOp && ["+", "−", "×", "÷", "="].contains(k) ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 9).fill(
                        ["+", "−", "×", "÷", "="].contains(k) ? (p.pending == k ? Color.orange.opacity(0.7) : Color.orange)
                            : (digitValue != nil ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)
            .help(Self.help[k] ?? "")
        }
    }

    static let help: [String: String] = [
        "AND": "ET bit à bit (&)", "OR": "OU bit à bit (|)", "XOR": "OU exclusif (^)", "NOR": "NON-OU", "NOT": "NON / complément à 1 (~)",
        "<<": "Décalage à gauche de n bits", ">>": "Décalage à droite de n bits (arithmétique si signé)",
        "<<1": "Décaler d'un bit à gauche", ">>1": "Décaler d'un bit à droite", "RoL": "Rotation à gauche", "RoR": "Rotation à droite",
        "flip": "Inverser l'ordre des octets (endianness)", "mod": "Reste de la division (%)", "±": "Opposé (complément à 2)",
        "AC": "Tout effacer (Échap)", "C": "Effacer la saisie", "⌫": "Effacer le dernier chiffre",
    ]
}
