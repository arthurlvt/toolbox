import SwiftUI
import AppKit

// MARK: - Modèle

struct CalcFunction: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var expr: String
    var colorIndex: Int
    var visible = true
}

struct CalcVariable: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var value: Double
    var min: Double = -10
    var max: Double = 10
}

struct CalcEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var input: String
    var result: String
    var latex: String
    var isError = false
    var value: Double?
}

struct Viewport: Codable, Equatable {
    var xMin = -10.0, xMax = 10.0, yMin = -7.0, yMax = 7.0

    static let standard = Viewport()
    var width: Double { xMax - xMin }
    var height: Double { yMax - yMin }

    func shifted(_ dx: Double, _ dy: Double) -> Viewport {
        Viewport(xMin: xMin + dx, xMax: xMax + dx, yMin: yMin + dy, yMax: yMax + dy)
    }

    func zoomed(_ k: Double, x: Double, y: Double) -> Viewport {
        let nw = max(1e-9, min(1e9, width * k)), nh = max(1e-9, min(1e9, height * k))
        let fx = (x - xMin) / width, fy = (y - yMin) / height
        return Viewport(xMin: x - fx * nw, xMax: x - fx * nw + nw, yMin: y - fy * nh, yMax: y - fy * nh + nh)
    }
}

struct CalcCompiled {
    var node: MathNode?
    var fn: MathEngine.Fn?
    var error: String?
}

final class CalcStore: ObservableObject {
    static let shared = CalcStore()

    enum Tab: String, CaseIterable, Identifiable {
        case values = "Valeurs", limits = "Limites", study = "Étude"
        var id: String { rawValue }
    }

    static let colors: [Color] = [.blue, .red, .green, .purple, .orange, .teal, .pink, .brown]
    static let tikzColors = ["blue", "red", "green!60!black", "violet", "orange", "teal", "magenta", "brown"]

    @Published var functions: [CalcFunction] = [] { didSet { if functions != oldValue { recompile(); save() } } }
    @Published var variables: [CalcVariable] = [] { didSet { if variables != oldValue { recompile(); save() } } }
    @Published var tape: [CalcEntry] = [] { didSet { save() } }
    @Published var input = ""
    @Published var view = Viewport.standard { didSet { saveSoon() } }
    @Published var hover: CGPoint?
    @Published var size: CGSize = .zero
    @Published var studyX: Double?
    @Published var selectedID: UUID?
    @Published var tab: Tab = .values
    @Published var mode = CalcMode(rawValue: UserDefaults.standard.string(forKey: "calc.mode") ?? "") ?? .graph {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "calc.mode") }
    }
    @Published var tableStart = "-3"
    @Published var tableStep = "1"
    @Published var limitPoint = "0"
    @Published var studyText = ""
    @Published var showTangent = true
    @Published var showKeypad = false
    @Published var ans = 0.0

    private(set) var compiled: [UUID: CalcCompiled] = [:]
    private(set) var env = MathEnv()
    var dragOrigin: Viewport?
    var zoomOrigin: Viewport?
    private var monitor: Any?
    private var loading = true
    private var saveWork: DispatchWorkItem?

    struct Saved: Codable {
        var functions: [CalcFunction]
        var variables: [CalcVariable]
        var tape: [CalcEntry]
        var view: Viewport
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "calc.state"),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            functions = s.functions
            variables = s.variables
            tape = s.tape
            view = s.view
        } else {
            functions = [CalcFunction(name: "f", expr: "x^2 - 2x - 3", colorIndex: 0)]
        }
        loading = false
        selectedID = functions.first?.id
        recompile()
    }

    private func save() {
        guard !loading else { return }
        let s = Saved(functions: functions, variables: variables, tape: Array(tape.suffix(60)), view: view)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "calc.state") }
    }

    private func saveSoon() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    // MARK: Compilation

    func recompile() {
        guard !loading else { return }
        var e = MathEnv()
        for v in variables { e.variables[v.name] = v.value }
        e.variables["ans"] = ans
        let names = Set(functions.map { $0.name })
        var nodes: [UUID: MathNode] = [:]
        var result: [UUID: CalcCompiled] = [:]
        for f in functions {
            let body = MathEngine.splitDefinition(f.expr).body
            if body.trimmingCharacters(in: .whitespaces).isEmpty { result[f.id] = CalcCompiled(); continue }
            do { nodes[f.id] = try MathEngine.parse(body, userFunctions: names) }
            catch { result[f.id] = CalcCompiled(error: error.localizedDescription) }
        }
        e.functions = Dictionary(functions.compactMap { f in nodes[f.id].map { (f.name, $0) } }, uniquingKeysWith: { a, _ in a })
        // paramètres utilisés mais pas encore créés : un curseur apparaît (comme sur Desmos)
        let used = Set(nodes.values.flatMap { $0.variables }).subtracting(["ans"]).subtracting(names)
        let missing = used.subtracting(variables.map { $0.name })
        if !missing.isEmpty {
            variables += missing.sorted().map { CalcVariable(name: $0, value: 1) }
            return   // variables.didSet relance la compilation
        }
        for f in functions {
            guard let n = nodes[f.id] else { continue }
            do { result[f.id] = CalcCompiled(node: n, fn: try MathEngine.compile(n, env: e)) }
            catch { result[f.id] = CalcCompiled(node: n, error: error.localizedDescription) }
        }
        env = e
        compiled = result
        objectWillChange.send()
    }

    var selected: CalcFunction? { functions.first { $0.id == selectedID } ?? functions.first }

    func color(_ f: CalcFunction) -> Color { Self.colors[f.colorIndex % Self.colors.count] }

    var curves: [GraphCurve] {
        functions.compactMap { f in
            guard f.visible, let fn = compiled[f.id]?.fn else { return nil }
            return GraphCurve(id: f.id, name: f.name, fn: fn, color: color(f))
        }
    }

    // MARK: Fonctions

    func nextName() -> String {
        let used = Set(functions.map { $0.name })
        return MathEngine.userNames.map(String.init).first { !used.contains($0) } ?? "f\(functions.count + 1)"
    }

    func nextColor() -> Int {
        let used = Set(functions.map { $0.colorIndex % Self.colors.count })
        return (0..<Self.colors.count).first { !used.contains($0) } ?? functions.count
    }

    @discardableResult
    func addFunction(_ expr: String = "", name: String? = nil) -> CalcFunction {
        let f = CalcFunction(name: name ?? nextName(), expr: expr, colorIndex: nextColor())
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { functions.append(f) }
        selectedID = f.id
        return f
    }

    func remove(_ f: CalcFunction) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { functions.removeAll { $0.id == f.id } }
        if selectedID == f.id { selectedID = functions.first?.id }
    }

    func derivativeNode(_ f: CalcFunction) throws -> MathNode {
        guard let n = compiled[f.id]?.node else { throw MathError(message: "Corrige d'abord l'expression de \(f.name)") }
        return MathEngine.simplify(try MathEngine.derivative(n, env: env))
    }

    func derivativeFn(_ f: CalcFunction) -> MathEngine.Fn? {
        guard let d = try? derivativeNode(f) else { return nil }
        return try? MathEngine.compile(d, env: env)
    }

    func addDerivative(_ f: CalcFunction) {
        do {
            let d = try derivativeNode(f)
            addFunction(MathFormat.text(d))
            ToastCenter.shared.show("\(f.name)'(x) = \(MathFormat.text(d))")
        } catch {
            ToastCenter.shared.show(error.localizedDescription)
        }
    }

    func latex(_ f: CalcFunction) -> String? {
        guard let n = compiled[f.id]?.node else { return nil }
        return "\(f.name)(x) = " + MathFormat.latex(n)
    }

    func derivativeLatex(_ f: CalcFunction) -> String? {
        guard let d = try? derivativeNode(f) else { return nil }
        return "\(f.name)'(x) = " + MathFormat.latex(d)
    }

    func copy(_ s: String, what: String = "LaTeX") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        ToastCenter.shared.show("\(what) copié ✓")
    }

    func sendToLatex(_ s: String) {
        AppRouter.shared.latexInsert = s
    }

    // MARK: Calculs

    func submit() {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        input = ""
        let def = MathEngine.splitDefinition(line)
        if let name = def.name, name != "x" {
            if let i = functions.firstIndex(where: { $0.name == name }) {
                functions[i].expr = def.body
                selectedID = functions[i].id
            } else {
                addFunction(def.body, name: name)
            }
            push(CalcEntry(input: line, result: "\(name)(x) tracée sur le graphe", latex: ""))
            return
        }
        if let r = line.range(of: #"^([a-df-wyzA-Z])\s*=\s*(.+)$"#, options: .regularExpression), r.lowerBound == line.startIndex {
            let name = String(line[line.startIndex])
            let rhs = line[line.index(after: line.startIndex)...].drop { $0 == " " || $0 == "=" }
            do {
                let node = try MathEngine.parse(String(rhs), userFunctions: Set(functions.map { $0.name }))
                guard !node.containsX else { throw MathError(message: "Un paramètre ne peut pas dépendre de x") }
                let v = try MathEngine.evaluate(node, env: env)
                if let i = variables.firstIndex(where: { $0.name == name }) {
                    variables[i].value = v
                    variables[i].min = Swift.min(variables[i].min, v)
                    variables[i].max = Swift.max(variables[i].max, v)
                } else {
                    variables.append(CalcVariable(name: name, value: v, min: Swift.min(-10, v), max: Swift.max(10, v)))
                }
                push(CalcEntry(input: line, result: "\(name) = \(MathFormat.fr(v))", latex: "\(name) = " + MathFormat.latexNumber(v), value: v))
            } catch {
                push(CalcEntry(input: line, result: error.localizedDescription, latex: "", isError: true))
            }
            return
        }
        do {
            let node = try MathEngine.parse(def.body, userFunctions: Set(functions.map { $0.name }))
            if node.containsX {
                let f = addFunction(def.body)
                push(CalcEntry(input: line, result: "Tracée comme \(f.name)(x)", latex: "\(f.name)(x) = " + MathFormat.latex(node)))
                return
            }
            let v = try MathEngine.evaluate(node, env: env)
            ans = v
            env.variables["ans"] = v
            var shown = MathFormat.fr(v)
            if let exact = MathFormat.exactGuess(v) { shown += "  (= \(exact))" }
            push(CalcEntry(input: line, result: shown, latex: MathFormat.latex(node) + " = " + MathFormat.latexNumber(v), value: v))
        } catch {
            push(CalcEntry(input: line, result: error.localizedDescription, latex: "", isError: true))
        }
    }

    private func push(_ e: CalcEntry) {
        withAnimation(.easeOut(duration: 0.2)) { tape.append(e) }
    }

    // MARK: Vue

    func px(_ x: Double) -> CGFloat { CGFloat((x - view.xMin) / view.width) * size.width }
    func dataX(_ px: CGFloat) -> Double { view.xMin + Double(px / max(size.width, 1)) * view.width }
    func dataY(_ py: CGFloat) -> Double { view.yMax - Double(py / max(size.height, 1)) * view.height }

    func zoom(_ k: Double, at p: CGPoint? = nil) {
        let x = p.map { dataX($0.x) } ?? (view.xMin + view.width / 2)
        let y = p.map { dataY($0.y) } ?? (view.yMin + view.height / 2)
        withAnimation(.easeOut(duration: 0.15)) { view = view.zoomed(k, x: x, y: y) }
    }

    func reset() { withAnimation(.easeInOut(duration: 0.3)) { view = .standard } }

    func orthonormal() {
        guard size.width > 0, size.height > 0 else { return }
        let h = view.width * Double(size.height / size.width), cy = view.yMin + view.height / 2
        withAnimation(.easeInOut(duration: 0.3)) { view = Viewport(xMin: view.xMin, xMax: view.xMax, yMin: cy - h / 2, yMax: cy + h / 2) }
    }

    /// Cadre les y sur ce que font les courbes visibles.
    func fitY() {
        var ys: [Double] = []
        for c in curves {
            for i in 0...400 {
                let y = c.fn(view.xMin + view.width * Double(i) / 400)
                if y.isFinite { ys.append(y) }
            }
        }
        guard ys.count > 10 else { return }
        ys.sort()
        var lo = ys[Int(Double(ys.count) * 0.03)], hi = ys[Int(Double(ys.count) * 0.97)]
        if hi - lo < 1e-9 { lo -= 1; hi += 1 }
        let m = (hi - lo) * 0.12
        withAnimation(.easeInOut(duration: 0.3)) { view = Viewport(xMin: view.xMin, xMax: view.xMax, yMin: lo - m, yMax: hi + m) }
    }

    func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self = self, let p = self.hover, self.size.width > 0 else { return e }
            if e.hasPreciseScrollingDeltas {
                // trackpad : déplacer (pincer pour zoomer)
                let dx = -Double(e.scrollingDeltaX) / Double(self.size.width) * self.view.width
                let dy = Double(e.scrollingDeltaY) / Double(self.size.height) * self.view.height
                self.view = self.view.shifted(dx, dy)
            } else {
                // molette : zoomer autour du pointeur
                let k = Foundation.exp(-Double(e.scrollingDeltaY) * 0.08)
                self.view = self.view.zoomed(k, x: self.dataX(p.x), y: self.dataY(p.y))
            }
            return nil
        }
    }

    func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        hover = nil
    }

    // MARK: Exports

    func point(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let n = try? MathEngine.parse(t), !n.containsX else { return nil }
        return try? MathEngine.evaluate(n, env: env)
    }

    var tableXs: [Double] {
        let start = point(tableStart) ?? -3, step = point(tableStep) ?? 1
        return (0..<15).map { MathAnalysis.clean(start + Double($0) * (step == 0 ? 1 : step)) }
    }

    func tableLatex() -> String {
        let fs = functions.filter { $0.visible && compiled[$0.id]?.fn != nil }.prefix(4)
        let xs = tableXs
        var rows = ["$x$ & " + xs.map { MathFormat.latexNumber($0) }.joined(separator: " & ") + " \\\\ \\hline"]
        for f in fs {
            guard let fn = compiled[f.id]?.fn else { continue }
            rows.append("$\(f.name)(x)$ & " + xs.map { x -> String in
                let y = fn(x)
                return y.isFinite ? MathFormat.latexNumber((y * 1000).rounded() / 1000) : "\\times"
            }.joined(separator: " & ") + " \\\\")
        }
        return "\\begin{tabular}{|c|" + String(repeating: "c", count: xs.count) + "|}\n\\hline\n" + rows.joined(separator: "\n") + "\n\\hline\n\\end{tabular}"
    }

    func tikz() -> String {
        let v = view
        var lines = [
            "% \\usepackage{pgfplots} \\pgfplotsset{compat=1.18}",
            "\\begin{tikzpicture}",
            "\\begin{axis}[axis lines=middle, grid=major, grid style={gray!25}, width=12cm, height=8cm,",
            "  xmin=\(MathFormat.plain(v.xMin, digits: 4)), xmax=\(MathFormat.plain(v.xMax, digits: 4)), ymin=\(MathFormat.plain(v.yMin, digits: 4)), ymax=\(MathFormat.plain(v.yMax, digits: 4)),",
            "  xlabel={$x$}, ylabel={$y$}, samples=300, unbounded coords=jump, legend pos=outer north east]",
        ]
        for f in functions where f.visible {
            guard let n = compiled[f.id]?.node, compiled[f.id]?.fn != nil else { continue }
            let color = Self.tikzColors[f.colorIndex % Self.tikzColors.count]
            lines.append("\\addplot[\(color), thick, domain=\(MathFormat.plain(v.xMin, digits: 4)):\(MathFormat.plain(v.xMax, digits: 4))] {\(MathFormat.pgf(n, env: env))};")
            lines.append("\\addlegendentry{$\(latex(f) ?? f.name)$}")
        }
        lines += ["\\end{axis}", "\\end{tikzpicture}"]
        return lines.joined(separator: "\n")
    }

    @MainActor
    func copyImage() {
        let content = GraphCanvas(view: view, curves: curves, hover: nil, marks: [], tangent: nil)
            .frame(width: 900, height: 560)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let image = r.nsImage else { ToastCenter.shared.show("Image impossible à créer"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        ToastCenter.shared.show("Graphe copié en image ✓ (colle-le avec ⌘V)")
    }
}

// MARK: - Dessin du graphe

struct GraphCurve: Identifiable {
    let id: UUID
    let name: String
    let fn: MathEngine.Fn
    let color: Color
}

struct GraphMark: Identifiable {
    let id = UUID()
    let x: Double
    let y: Double
    let color: Color
    var filled = true
}

struct GraphCanvas: View {
    let view: Viewport
    let curves: [GraphCurve]
    let hover: CGPoint?
    let marks: [GraphMark]
    let tangent: (fn: MathEngine.Fn, color: Color)?

    static func label(_ v: Double) -> String { MathFormat.fr((v * 1e6).rounded() / 1e6, digits: 6) }

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 2, size.height > 2 else { return }
            let v = view
            func px(_ x: Double) -> CGFloat { CGFloat((x - v.xMin) / v.width) * size.width }
            func py(_ y: Double) -> CGFloat {
                let c = Swift.min(Swift.max(y, v.yMin - 20 * v.height), v.yMax + 20 * v.height)
                return size.height - CGFloat((c - v.yMin) / v.height) * size.height
            }

            // grille
            let sx = MathAnalysis.niceStep(v.width / Double(size.width / 90))
            let sy = MathAnalysis.niceStep(v.height / Double(size.height / 70))
            var minor = Path(), major = Path()
            var x = (v.xMin / sx).rounded(.down) * sx
            while x <= v.xMax {
                for k in 1..<5 {
                    let mx = x + Double(k) * sx / 5
                    minor.move(to: CGPoint(x: px(mx), y: 0)); minor.addLine(to: CGPoint(x: px(mx), y: size.height))
                }
                major.move(to: CGPoint(x: px(x), y: 0)); major.addLine(to: CGPoint(x: px(x), y: size.height))
                x += sx
            }
            var y = (v.yMin / sy).rounded(.down) * sy
            while y <= v.yMax {
                for k in 1..<5 {
                    let my = y + Double(k) * sy / 5
                    minor.move(to: CGPoint(x: 0, y: py(my))); minor.addLine(to: CGPoint(x: size.width, y: py(my)))
                }
                major.move(to: CGPoint(x: 0, y: py(y))); major.addLine(to: CGPoint(x: size.width, y: py(y)))
                y += sy
            }
            ctx.stroke(minor, with: .color(.primary.opacity(0.04)), lineWidth: 1)
            ctx.stroke(major, with: .color(.primary.opacity(0.10)), lineWidth: 1)

            // axes
            let ax = Swift.min(Swift.max(py(0), 0), size.height), ay = Swift.min(Swift.max(px(0), 0), size.width)
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: ax)); axes.addLine(to: CGPoint(x: size.width, y: ax))
            axes.move(to: CGPoint(x: ay, y: 0)); axes.addLine(to: CGPoint(x: ay, y: size.height))
            ctx.stroke(axes, with: .color(.primary.opacity(0.55)), lineWidth: 1.2)

            // graduations
            x = (v.xMin / sx).rounded(.down) * sx
            while x <= v.xMax {
                if Swift.abs(x) > sx / 1000 {
                    let below = ax + 14 < size.height
                    ctx.draw(Text(Self.label(x)).font(.system(size: 10)).foregroundColor(.secondary),
                             at: CGPoint(x: px(x), y: below ? ax + 3 : ax - 3), anchor: below ? .top : .bottom)
                }
                x += sx
            }
            y = (v.yMin / sy).rounded(.down) * sy
            while y <= v.yMax {
                if Swift.abs(y) > sy / 1000 {
                    let right = ay + 40 < size.width
                    ctx.draw(Text(Self.label(y)).font(.system(size: 10)).foregroundColor(.secondary),
                             at: CGPoint(x: right ? ay + 4 : ay - 4, y: py(y)), anchor: right ? .leading : .trailing)
                }
                y += sy
            }
            if px(0) >= 0, px(0) <= size.width, py(0) >= 0, py(0) <= size.height {
                ctx.draw(Text("0").font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: ay - 4, y: ax + 3), anchor: .topTrailing)
            }

            // courbes
            let n = Int(size.width * 1.5)
            func curvePath(_ fn: MathEngine.Fn) -> Path {
                var path = Path()
                var down = false
                var last: Double?
                for i in 0...n {
                    let xv = v.xMin + v.width * Double(i) / Double(n)
                    let yv = fn(xv)
                    guard yv.isFinite else { down = false; last = nil; continue }
                    if let l = last, down {
                        // saut d'une asymptote (tan, 1/x…) : on lève le crayon
                        let jump = Swift.abs(yv - l) > v.height && ((yv > v.yMax && l < v.yMin) || (yv < v.yMin && l > v.yMax))
                        if jump || Swift.abs(yv - l) > v.height * 40 { down = false }
                    }
                    let p = CGPoint(x: px(xv), y: py(yv))
                    if down { path.addLine(to: p) } else { path.move(to: p); down = true }
                    last = yv
                }
                return path
            }
            for c in curves {
                ctx.stroke(curvePath(c.fn), with: .color(c.color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            if let t = tangent {
                ctx.stroke(curvePath(t.fn), with: .color(t.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
            }

            // points remarquables
            for m in marks where m.y.isFinite {
                let r: CGFloat = 4.5
                let rect = CGRect(x: px(m.x) - r, y: py(m.y) - r, width: 2 * r, height: 2 * r)
                if m.filled { ctx.fill(Path(ellipseIn: rect), with: .color(m.color)) }
                ctx.stroke(Path(ellipseIn: rect), with: .color(m.filled ? .white : m.color), lineWidth: 1.5)
            }

            // lecture au pointeur
            if let h = hover {
                let xv = v.xMin + Double(h.x / size.width) * v.width
                var line = Path()
                line.move(to: CGPoint(x: h.x, y: 0)); line.addLine(to: CGPoint(x: h.x, y: size.height))
                ctx.stroke(line, with: .color(.primary.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var row: CGFloat = 0
                for c in curves {
                    let yv = c.fn(xv)
                    guard yv.isFinite else { continue }
                    let p = CGPoint(x: h.x, y: py(yv))
                    if p.y >= 0, p.y <= size.height {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(c.color))
                    }
                    let text = Text("\(c.name)(\(Self.label(xv))) = \(Self.label(yv))").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(c.color)
                    let anchorRight = h.x > size.width - 190
                    ctx.draw(text, at: CGPoint(x: anchorRight ? h.x - 8 : h.x + 8, y: 10 + row), anchor: anchorRight ? .topTrailing : .topLeading)
                    row += 16
                }
            }
        }
    }
}

// MARK: - Vue

struct CalcToolView: View {
    @ObservedObject var s: CalcStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ToolHeader(tool: .calc)
                Spacer()
                Picker("Mode", selection: $s.mode) {
                    ForEach(CalcMode.allCases) { m in Label(m.title, systemImage: m.icon).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
                .tourTarget("calc.modes")
            }
            switch s.mode {
            case .graph:
                HSplitView {
                    sidePanel.frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
                    VStack(spacing: 10) {
                        graphToolbar
                        graph.tourTarget("calc.content")
                        bottomPanel.frame(height: 236)
                    }
                    .frame(minWidth: 480)
                    .padding(.leading, 10)
                }
                .onAppear { s.installMonitor() }
                .onDisappear { s.removeMonitor() }
            case .scientific:
                ScrollView { ScientificCalcView().frame(maxWidth: .infinity) }.tourTarget("calc.content")
            case .programmer:
                ScrollView { ProgrammerCalcView().frame(maxWidth: .infinity) }.tourTarget("calc.content")
            }
        }
        .padding(20)
    }

    // MARK: Panneau de gauche

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Fonctions").font(.headline)
                        Spacer()
                        Button { s.addFunction() } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.borderless).help("Nouvelle fonction")
                    }
                    ForEach($s.functions) { $f in
                        FunctionRow(s: s, f: $f)
                    }
                    if !s.variables.isEmpty {
                        Text("Paramètres").font(.headline).padding(.top, 6)
                        ForEach($s.variables) { $v in
                            VariableRow(v: $v) { s.variables.removeAll { $0.id == v.id } }
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: .infinity)
            Divider()
            tape
        }
    }

    private var tape: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Calculs").font(.headline)
                Spacer()
                Button { withAnimation { s.showKeypad.toggle() } } label: { Image(systemName: "keyboard") }
                    .buttonStyle(.borderless).help("Clavier de symboles")
                if !s.tape.isEmpty {
                    Button { withAnimation { s.tape = [] } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Effacer l'historique")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .trailing, spacing: 8) {
                        if s.tape.isEmpty {
                            Text("Ex. : 2^10, ln(2)·3, f(2), f'(1), a = 3, g(x) = sin(2x)…")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(s.tape) { e in
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(e.input).font(.callout.monospaced()).foregroundStyle(.secondary)
                                Text(e.result).font(.body.monospaced().weight(.semibold))
                                    .foregroundStyle(e.isError ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .contextMenu {
                                if let v = e.value { Button("Copier le résultat") { s.copy(MathFormat.fr(v), what: "Résultat") } }
                                if !e.latex.isEmpty {
                                    Button("Copier en LaTeX") { s.copy(e.latex) }
                                    Button("Insérer dans le document LaTeX") { s.sendToLatex("$" + e.latex + "$") }
                                }
                                Button("Réutiliser") { s.input = e.input }
                            }
                            .id(e.id)
                        }
                    }
                }
                .frame(height: 150)
                .onChange(of: s.tape.count) { _ in
                    if let last = s.tape.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if s.showKeypad { keypad.transition(.move(edge: .bottom).combined(with: .opacity)) }
            HStack {
                TextField("Calcul ou fonction…", text: $s.input)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { s.submit() }
                Button("=") { s.submit() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var keypad: some View {
        let keys: [(String, String)] = [("π", "π"), ("e", "e"), ("√", "√("), ("xⁿ", "^"), ("x²", "²"), ("|x|", "abs("),
                                        ("ln", "ln("), ("exp", "exp("), ("sin", "sin("), ("cos", "cos("), ("tan", "tan("), ("n!", "!"),
                                        ("(", "("), (")", ")"), ("x", "x"), ("ans", "ans")]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
            ForEach(keys.indices, id: \.self) { i in
                Button { s.input += keys[i].1 } label: {
                    Text(keys[i].0).font(.callout.monospaced()).frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Graphe

    private var graphToolbar: some View {
        HStack(spacing: 8) {
            Button { s.zoom(0.7) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoomer")
            Button { s.zoom(1 / 0.7) } label: { Image(systemName: "minus.magnifyingglass") }.help("Dézoomer")
            Button("Standard") { s.reset() }
            Button("Orthonormé") { s.orthonormal() }
            Button("Ajuster") { s.fitY() }.help("Cadrer verticalement sur les courbes")
            Spacer()
            Text("Molette : zoom · glisser : déplacer · clic : étudier un point").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            Menu {
                Button("Copier l'image du graphe") { s.copyImage() }
                Button("Copier en TikZ (pgfplots)") { s.copy(s.tikz(), what: "Code TikZ") }
                Button("Insérer le TikZ dans le document LaTeX") { s.sendToLatex(s.tikz() + "\n") }
            } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                .fixedSize()
        }
        .controlSize(.small)
    }

    private var studyMarks: [GraphMark] {
        guard let f = s.selected, f.visible, let fn = s.compiled[f.id]?.fn else { return [] }
        var marks: [GraphMark] = []
        let c = s.color(f)
        if s.tab == .study {
            for r in MathAnalysis.roots(fn, from: s.view.xMin, to: s.view.xMax) { marks.append(GraphMark(x: r, y: 0, color: c, filled: false)) }
            if let d = s.derivativeFn(f) {
                for r in MathAnalysis.roots(d, from: s.view.xMin, to: s.view.xMax) { marks.append(GraphMark(x: r, y: fn(r), color: c)) }
            }
        }
        if let a = s.studyX { marks.append(GraphMark(x: a, y: fn(a), color: .primary)) }
        return marks
    }

    private var tangent: (fn: MathEngine.Fn, color: Color)? {
        guard s.showTangent, let a = s.studyX, let f = s.selected, let fn = s.compiled[f.id]?.fn, let d = s.derivativeFn(f) else { return nil }
        let y0 = fn(a), slope = d(a)
        guard y0.isFinite, slope.isFinite else { return nil }
        return ({ x in slope * (x - a) + y0 }, s.color(f))
    }

    private var graph: some View {
        GeometryReader { geo in
            GraphCanvas(view: s.view, curves: s.curves, hover: s.hover, marks: studyMarks, tangent: tangent)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): s.hover = p
                    case .ended: s.hover = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { g in
                            if s.dragOrigin == nil { s.dragOrigin = s.view }
                            guard let o = s.dragOrigin else { return }
                            let dx = -Double(g.translation.width / max(geo.size.width, 1)) * o.width
                            let dy = Double(g.translation.height / max(geo.size.height, 1)) * o.height
                            s.view = o.shifted(dx, dy)
                            s.hover = g.location
                        }
                        .onEnded { _ in s.dragOrigin = nil }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { m in
                            if s.zoomOrigin == nil { s.zoomOrigin = s.view }
                            guard let o = s.zoomOrigin else { return }
                            s.view = o.zoomed(1 / Double(max(m, 0.05)), x: o.xMin + o.width / 2, y: o.yMin + o.height / 2)
                        }
                        .onEnded { _ in s.zoomOrigin = nil }
                )
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { t in
                        s.studyX = MathAnalysis.clean(s.dataX(t.location.x))
                        s.studyText = GraphCanvas.label(s.studyX ?? 0)
                        s.tab = .study
                    }
                )
                .onAppear { s.size = geo.size }
                .onChange(of: geo.size) { s.size = $0 }
        }
        .frame(minHeight: 260)
    }

    // MARK: Panneau du bas

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $s.tab) {
                    ForEach(CalcStore.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                if s.tab != .values, s.functions.count > 1 {
                    Picker("Fonction", selection: Binding(get: { s.selected?.id ?? UUID() }, set: { s.selectedID = $0 })) {
                        ForEach(s.functions) { f in Text("\(f.name)(x)").tag(f.id) }
                    }
                    .frame(width: 150)
                }
            }
            Group {
                switch s.tab {
                case .values: valuesTab
                case .limits: limitsTab
                case .study: studyTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
    }

    private var valuesTab: some View {
        let fs = s.functions.filter { $0.visible && s.compiled[$0.id]?.fn != nil }.prefix(4)
        let xs = s.tableXs
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Départ")
                TextField("", text: $s.tableStart).textFieldStyle(.roundedBorder).frame(width: 70)
                Text("Pas")
                TextField("", text: $s.tableStep).textFieldStyle(.roundedBorder).frame(width: 70)
                Spacer()
                Button("Copier en LaTeX") { s.copy(s.tableLatex(), what: "Tableau LaTeX") }
                    .disabled(fs.isEmpty)
            }
            .controlSize(.small)
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("x").bold()
                        ForEach(Array(fs)) { f in Text("\(f.name)(x)").bold().foregroundStyle(s.color(f)) }
                    }
                    Divider()
                    ForEach(xs, id: \.self) { x in
                        GridRow {
                            Text(GraphCanvas.label(x)).foregroundStyle(.secondary)
                            ForEach(Array(fs)) { f in
                                let y = s.compiled[f.id]?.fn?(x) ?? .nan
                                Text(y.isFinite ? GraphCanvas.label((y * 1e5).rounded() / 1e5) : "—")
                            }
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                .padding(.trailing, 10)
            }
        }
    }

    private var limitsTab: some View {
        let f = s.selected
        let fn = f.flatMap { s.compiled[$0.id]?.fn }
        let a = s.point(s.limitPoint)
        let result = (fn != nil && a != nil) ? MathAnalysis.limit(fn!, at: a!) : nil
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("x tend vers")
                    TextField("0, 2, pi/2, +inf, -inf", text: $s.limitPoint).textFieldStyle(.roundedBorder).frame(width: 130)
                }
                HStack(spacing: 6) {
                    ForEach(["-inf", "0", "1", "+inf"], id: \.self) { p in
                        Button(p.replacingOccurrences(of: "inf", with: "∞")) { s.limitPoint = p }.controlSize(.small)
                    }
                }
                if let r = result {
                    Text(r.verdict).font(.title3.bold()).foregroundStyle(f.map { s.color($0) } ?? .primary)
                    if !r.detail.isEmpty { Text(r.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    Text("Estimation numérique : ça t'indique le résultat, mais il faut toujours le justifier sur la copie 😉")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(fn == nil ? "Choisis une fonction valide." : "Point illisible.").foregroundStyle(.secondary)
                }
            }
            .frame(width: 270, alignment: .leading)
            if let r = result {
                ScrollView {
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 2) {
                        GridRow {
                            Text(a?.isInfinite == true ? "x" : "h").bold()
                            if a?.isInfinite != true || a! < 0 { Text(a?.isInfinite == true ? "f(x)" : "f(a − h)").bold() }
                            if a?.isInfinite != true || a! > 0 { Text(a?.isInfinite == true ? "f(x)" : "f(a + h)").bold() }
                        }
                        ForEach(r.rows) { row in
                            GridRow {
                                Text(MathFormat.fr(row.x, digits: 3)).foregroundStyle(.secondary)
                                if let l = row.left { Text(l.isFinite ? MathFormat.fr(l, digits: 9) : "—") }
                                if let rr = row.right { Text(rr.isFinite ? MathFormat.fr(rr, digits: 9) : "—") }
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
    }

    private var studyTab: some View {
        let f = s.selected
        let fn = f.flatMap { s.compiled[$0.id]?.fn }
        let d = f.flatMap { s.derivativeFn($0) }
        let dNode = f.flatMap { try? s.derivativeNode($0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let f = f, let fn = fn {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(f.name)'(x) =").bold()
                        Text(dNode.map { MathFormat.text($0) } ?? "—").font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        if let dl = s.derivativeLatex(f) {
                            Button("LaTeX") { s.copy(dl) }.controlSize(.small)
                        }
                        Button("Tracer \(f.name)'") { s.addDerivative(f) }.controlSize(.small)
                    }
                    HStack {
                        Text("Point a =")
                        TextField("clique sur le graphe", text: $s.studyText)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                            .onSubmit { s.studyX = s.point(s.studyText) }
                        Toggle("Tangente", isOn: $s.showTangent).toggleStyle(.checkbox)
                        Spacer()
                    }
                    if let a = s.studyX {
                        let y = fn(a), slope = d?(a) ?? .nan
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                            GridRow { Text("\(f.name)(a)").foregroundStyle(.secondary); Text(GraphCanvas.label(y)).monospacedDigit() }
                            GridRow { Text("\(f.name)'(a)").foregroundStyle(.secondary); Text(GraphCanvas.label(slope)).monospacedDigit() }
                            if y.isFinite, slope.isFinite {
                                let b = y - slope * a
                                let tangentText = "y = \(GraphCanvas.label(slope))x" + (b >= 0 ? " + " : " − ") + GraphCanvas.label(Swift.abs(b))
                                GridRow {
                                    Text("Tangente").foregroundStyle(.secondary)
                                    HStack {
                                        Text(tangentText).monospacedDigit().textSelection(.enabled)
                                        Button("LaTeX") {
                                            s.copy("y = " + MathFormat.latexNumber((slope * 1e6).rounded() / 1e6) + "x "
                                                   + (b >= 0 ? "+ " : "- ") + MathFormat.latexNumber((Swift.abs(b) * 1e6).rounded() / 1e6))
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    let roots = MathAnalysis.roots(fn, from: s.view.xMin, to: s.view.xMax)
                    let crit = d.map { MathAnalysis.roots($0, from: s.view.xMin, to: s.view.xMax) } ?? []
                    let infl = d.flatMap { dd -> [Double]? in
                        let h = 1e-4
                        return MathAnalysis.roots({ (dd($0 + h) - dd($0 - h)) / (2 * h) }, from: s.view.xMin, to: s.view.xMax, samples: 600)
                    } ?? []
                    Text("Dans la fenêtre visible :").font(.caption).foregroundStyle(.secondary)
                    studyLine("Annulations", roots.map { "x = " + MathAnalysis.nice(MathAnalysis.clean($0)) })
                    studyLine("Extremums", crit.map { x -> String in
                        let before = d?(x - 1e-4) ?? 0, after = d?(x + 1e-4) ?? 0
                        let kind = before > 0 && after < 0 ? "max" : (before < 0 && after > 0 ? "min" : "palier")
                        return "\(kind) en x = \(MathAnalysis.nice(MathAnalysis.clean(x))) (\(MathAnalysis.nice(fn(x))))"
                    })
                    studyLine("Inflexions", infl.map { "x = " + MathAnalysis.nice(MathAnalysis.clean($0)) })
                } else {
                    Text("Choisis une fonction valide.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func studyLine(_ title: String, _ items: [String]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(items.isEmpty ? "aucun" : items.prefix(8).joined(separator: " · "))
                .font(.callout.monospacedDigit()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FunctionRow: View {
    @ObservedObject var s: CalcStore
    @Binding var f: CalcFunction

    var body: some View {
        let compiled = s.compiled[f.id]
        let isSelected = s.selected?.id == f.id
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button { f.visible.toggle() } label: {
                    Circle()
                        .fill(f.visible ? s.color(f) : Color.clear)
                        .overlay(Circle().stroke(s.color(f), lineWidth: 2))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(f.visible ? "Masquer" : "Afficher")
                Text("\(f.name)(x) =").font(.body.monospaced()).foregroundStyle(.secondary)
                TextField("x^2 - 1", text: $f.expr)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                Menu {
                    Button("Tracer la dérivée \(f.name)'") { s.addDerivative(f) }
                    Divider()
                    if let l = s.latex(f) {
                        Button("Copier en LaTeX") { s.copy(l) }
                        Button("Copier entre $…$") { s.copy("$" + l + "$") }
                        Button("Insérer dans le document LaTeX") { s.sendToLatex("$" + l + "$") }
                        if let dl = s.derivativeLatex(f) { Button("Copier la dérivée en LaTeX") { s.copy(dl) } }
                    }
                    Divider()
                    Menu("Couleur") {
                        ForEach(0..<CalcStore.colors.count, id: \.self) { i in
                            Button(["Bleu", "Rouge", "Vert", "Violet", "Orange", "Bleu-vert", "Rose", "Marron"][i]) { f.colorIndex = i }
                        }
                    }
                    Button("Supprimer", role: .destructive) { s.remove(f) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { if let l = s.latex(f) { s.copy(l) } } label: {
                    Text("TeX").font(.caption.bold())
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(compiled?.node == nil)
                .help("Copier la formule en LaTeX")
            }
            if let e = compiled?.error {
                Text(e).font(.caption).foregroundStyle(Color.red).padding(.leading, 22)
            } else if let n = compiled?.node {
                Text(MathFormat.latex(n)).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    .padding(.leading, 22).help("Formule LaTeX")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? s.color(f).opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? s.color(f).opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { s.selectedID = f.id }
    }
}

struct VariableRow: View {
    @Binding var v: CalcVariable
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(v.name) = \(MathFormat.fr((v.value * 100).rounded() / 100))").font(.body.monospaced().bold())
                Spacer()
                Button(action: remove) { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
            }
            HStack(spacing: 6) {
                Text(MathFormat.fr(v.min)).font(.caption2).foregroundStyle(.secondary)
                Slider(value: $v.value, in: v.min...max(v.max, v.min + 0.01))
                Text(MathFormat.fr(v.max)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}
