import SwiftUI
import AppKit
import PDFCore

// MARK: - Modèle (les nombres sont gardés tels que tapés : « 12,5 », « 0.5 »…)

struct GradeItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var weight = "1"
    var note = ""
    var resit = ""          // session 2 / rattrapage
    var simulated = ""      // note imaginée en mode simulation
}

struct GradeUnit: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var credits = "6"
    var items: [GradeItem] = []
    var carried = false     // UE acquise l'année d'avant (redoublement)
}

struct GradeSemester: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var units: [GradeUnit] = []
}

struct GradeRules: Codable, Equatable {
    var pass = 10.0
    var semesterCompensation = true
    var yearCompensation = true
    var floor = ""          // note plancher pour pouvoir compenser (vide = aucune)
    var resitBest = true    // rattrapage : meilleure des deux notes (sinon il remplace)
}

struct GradeYear: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var semesters: [GradeSemester]
    var rules = GradeRules()
}

// MARK: - Calculs

enum GradeStatus {
    case acquired, compensated, failed, pending, carried

    var label: String {
        switch self {
        case .acquired: return "Acquise"
        case .compensated: return "Compensée"
        case .failed: return "Non acquise"
        case .pending: return "En cours"
        case .carried: return "Acquise l'an dernier"
        }
    }

    var color: Color {
        switch self {
        case .acquired, .carried: return .green
        case .compensated: return .teal
        case .failed: return .red
        case .pending: return .secondary
        }
    }

    var counts: Bool { self == .acquired || self == .compensated || self == .carried }
}

struct UnitResult {
    var average: Double?
    var complete: Bool
    var sum: Double            // Σ coef × note (épreuves notées)
    var done: Double           // Σ coef notés
    var remaining: Double      // Σ coef restants
    var total: Double
    var remainingCount: Int
    var needed: Double?        // moyenne à avoir sur ce qui reste pour atteindre la barre
    var maxPossible: Double
    var credits: Double
    var status = GradeStatus.pending
}

struct SemesterResult {
    var average: Double?       // provisoire tant que tout n'est pas noté
    var complete: Bool
    var a: Double              // moyenne finale = a + b × (note moyenne sur ce qui reste)
    var b: Double
    var credits: Double
    var acquired: Double
    var validated: Bool
    var needed: Double?
    var remainingCount: Int
    var units: [UUID: UnitResult]
}

struct YearResult {
    var average: Double?
    var complete: Bool
    var validated: Bool
    var needed: Double?
    var credits: Double
    var acquired: Double
    var remainingCount: Int
    var semesters: [UUID: SemesterResult]
}

enum GradeCalc {
    static func num(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    static func fmt(_ v: Double) -> String { MathFormat.fr((v * 100).rounded() / 100) }

    static func grade(_ i: GradeItem, rules: GradeRules, simulate: Bool) -> Double? {
        var g = num(i.note)
        if let r = num(i.resit) {
            if let first = g, rules.resitBest { g = max(first, r) } else { g = r }
        }
        if g == nil, simulate { g = num(i.simulated) }
        return g
    }

    static func unit(_ u: GradeUnit, rules: GradeRules, simulate: Bool) -> UnitResult {
        let credits = max(0, num(u.credits) ?? 0)
        if u.items.isEmpty {
            return UnitResult(average: nil, complete: false, sum: 0, done: 0, remaining: 1, total: 1, remainingCount: 1,
                              needed: rules.pass, maxPossible: 20, credits: credits)
        }
        var pairs = u.items.map { (w: max(0, num($0.weight) ?? 1), g: grade($0, rules: rules, simulate: simulate)) }
        if pairs.allSatisfy({ $0.w == 0 }) { pairs = pairs.map { (w: 1, g: $0.g) } }
        var sum = 0.0, done = 0.0, remaining = 0.0, count = 0
        for p in pairs {
            if let g = p.g { sum += p.w * g; done += p.w } else if p.w > 0 { remaining += p.w; count += 1 }
        }
        let total = done + remaining
        let complete = remaining == 0
        return UnitResult(average: done > 0 ? sum / done : nil, complete: complete, sum: sum, done: done, remaining: remaining,
                          total: total, remainingCount: count,
                          needed: complete ? nil : (rules.pass * total - sum) / remaining,
                          maxPossible: total > 0 ? (sum + 20 * remaining) / total : 20, credits: credits)
    }

    static func year(_ y: GradeYear, simulate: Bool) -> YearResult {
        let rules = y.rules
        let floor = num(rules.floor)
        func floorOK(_ r: UnitResult) -> Bool { floor.map { (r.average ?? 0) >= $0 } ?? true }

        var sems: [UUID: SemesterResult] = [:]
        var units: [UUID: UnitResult] = [:]
        for s in y.semesters {
            var rs: [UUID: UnitResult] = [:]
            for u in s.units { rs[u.id] = unit(u, rules: rules, simulate: simulate) }
            // UE reportées sans note : ne pèsent pas dans la moyenne
            let counted = s.units.filter { !($0.carried && rs[$0.id]?.average == nil) }
            var weights = counted.map { rs[$0.id]?.credits ?? 0 }
            if weights.reduce(0, +) == 0 { weights = counted.map { _ in 1 } }
            let wsum = weights.reduce(0, +)
            var a = 0.0, b = 0.0, provNum = 0.0, provDen = 0.0, remainingCount = 0
            for (u, w) in zip(counted, weights) {
                guard let r = rs[u.id], r.total > 0 else { continue }
                a += w * (r.sum / r.total)
                b += w * (r.remaining / r.total)
                if let avg = r.average { provNum += w * avg; provDen += w }
                remainingCount += r.remainingCount
            }
            if wsum > 0 { a /= wsum; b /= wsum }
            let complete = s.units.allSatisfy { u in u.carried || rs[u.id]?.complete == true } && !s.units.isEmpty
            let validated = complete && a >= rules.pass - 1e-9 && rs.values.allSatisfy(floorOK)
            sems[s.id] = SemesterResult(average: provDen > 0 ? provNum / provDen : nil, complete: complete, a: a, b: b,
                                        credits: s.units.reduce(0) { $0 + (rs[$1.id]?.credits ?? 0) }, acquired: 0,
                                        validated: validated, needed: complete || b == 0 ? nil : (rules.pass - a) / b,
                                        remainingCount: remainingCount, units: rs)
            rs.forEach { units[$0.key] = $0.value }
        }

        // année
        let semList = y.semesters.compactMap { s in sems[s.id].map { (s, $0) } }
        var ws = semList.map { $0.1.credits }
        if ws.reduce(0, +) == 0 { ws = semList.map { _ in 1 } }
        let W = ws.reduce(0, +)
        var A = 0.0, B = 0.0, pn = 0.0, pd = 0.0
        for ((_, r), w) in zip(semList, ws) {
            A += w * r.a; B += w * r.b
            if let avg = r.average { pn += w * avg; pd += w }
        }
        if W > 0 { A /= W; B /= W }
        let yearComplete = !semList.isEmpty && semList.allSatisfy { $0.1.complete }
        let yearValidated = yearComplete && A >= rules.pass - 1e-9 && units.values.allSatisfy(floorOK)

        // statuts et crédits
        var acquiredTotal = 0.0
        for s in y.semesters {
            guard var sr = sems[s.id] else { continue }
            var acquired = 0.0
            for u in s.units {
                guard var r = sr.units[u.id] else { continue }
                if u.carried {
                    r.status = .carried
                } else if r.complete, let avg = r.average, avg >= rules.pass - 1e-9 {
                    r.status = .acquired
                } else if r.complete {
                    let compensated = ((rules.semesterCompensation && sr.validated) || (rules.yearCompensation && yearValidated)) && floorOK(r)
                    r.status = compensated ? .compensated : .failed
                } else {
                    r.status = .pending
                }
                if r.status.counts { acquired += r.credits }
                sr.units[u.id] = r
            }
            sr.acquired = acquired
            acquiredTotal += acquired
            sems[s.id] = sr
        }
        return YearResult(average: pd > 0 ? pn / pd : nil, complete: yearComplete, validated: yearValidated,
                          needed: yearComplete || B == 0 ? nil : (rules.pass - A) / B,
                          credits: semList.reduce(0) { $0 + $1.1.credits }, acquired: acquiredTotal,
                          remainingCount: semList.reduce(0) { $0 + $1.1.remainingCount }, semesters: sems)
    }

    /// Phrase sur ce qu'il reste à faire.
    static func neededText(_ needed: Double?, count: Int, pass: Double, maxPossible: Double? = nil) -> (String, Color) {
        guard let n = needed else { return ("", .secondary) }
        let what = count > 1 ? "les \(count) épreuves restantes" : "l'épreuve restante"
        if n <= 0 { return ("Déjà assuré, même avec 0 sur \(what) ✓", .green) }
        if n > 20 { return ("Plus atteignable seul (max \(fmt(maxPossible ?? 0))) : compte sur la compensation", .red) }
        let color: Color = n <= pass ? .green : (n <= 14 ? .orange : .red)
        return ("Il te faut \(fmt(n)) de moyenne sur \(what)", color)
    }

    static func color(_ avg: Double?, pass: Double) -> Color {
        guard let a = avg else { return .secondary }
        return a >= pass ? .green : (a >= pass - 2 ? .orange : .red)
    }
}

// MARK: - Stockage

final class GradesStore: ObservableObject {
    static let shared = GradesStore()

    @Published var years: [GradeYear] = [] { didSet { if years != oldValue { save() } } }
    @Published var yearID: UUID? { didSet { UserDefaults.standard.set(yearID?.uuidString, forKey: "grades.year") } }
    @Published var simulate = false
    @Published var showRules = false

    var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/Notes.json")
    }

    init() {
        if let data = try? Data(contentsOf: file), let y = try? JSONDecoder().decode([GradeYear].self, from: data), !y.isEmpty {
            years = y
        } else {
            years = [Self.template()]
        }
        let saved = UserDefaults.standard.string(forKey: "grades.year").flatMap(UUID.init(uuidString:))
        yearID = years.contains { $0.id == saved } ? saved : years.last?.id
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(years) { try? data.write(to: file, options: .atomic) }
    }

    static func academicYear(_ date: Date = Date(), offset: Int = 0) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        let start = (c.year ?? 2026) - ((c.month ?? 9) < 8 ? 1 : 0) + offset
        return "\(start)-\(start + 1)"
    }

    static func template() -> GradeYear {
        GradeYear(name: "L1 Informatique " + academicYear(),
                  semesters: [GradeSemester(name: "S1"), GradeSemester(name: "S2")])
    }

    var index: Int? { years.firstIndex { $0.id == yearID } ?? (years.isEmpty ? nil : years.count - 1) }
    var current: GradeYear? { index.map { years[$0] } }

    func result(simulate: Bool? = nil) -> YearResult? {
        current.map { GradeCalc.year($0, simulate: simulate ?? self.simulate) }
    }

    func newYear(carry: Bool) {
        guard let cur = current else { years.append(Self.template()); yearID = years.last?.id; return }
        let r = GradeCalc.year(cur, simulate: false)
        var y = GradeYear(name: cur.name.replacingOccurrences(of: Self.academicYear(), with: Self.academicYear(offset: 1)),
                          semesters: [], rules: cur.rules)
        if y.name == cur.name { y.name = cur.name + " (nouvelle)" }
        for s in cur.semesters {
            var ns = GradeSemester(name: s.name)
            for u in s.units {
                var nu = GradeUnit(name: u.name, credits: u.credits)
                let status = r.semesters[s.id]?.units[u.id]?.status
                if carry, let st = status, st.counts {
                    nu.items = u.items.map { var i = $0; i.id = UUID(); i.simulated = ""; return i }
                    nu.carried = true
                } else {
                    nu.items = u.items.map { GradeItem(name: $0.name, weight: $0.weight) }
                }
                ns.units.append(nu)
            }
            y.semesters.append(ns)
        }
        withAnimation { years.append(y) }
        yearID = y.id
        ToastCenter.shared.show(carry ? "Nouvelle année créée : les UE validées sont reportées ✓" : "Nouvelle année créée ✓")
    }

    func deleteCurrentYear() {
        guard let i = index, years.count > 1 else { return }
        years.remove(at: i)
        yearID = years.last?.id
    }

    func importCourses(into semester: UUID) {
        guard let yi = index, let si = years[yi].semesters.firstIndex(where: { $0.id == semester }) else { return }
        let existing = Set(years[yi].semesters.flatMap { $0.units.map { CourseLibrary.fold($0.name) } })
        let cs = CoursesStore.shared
        var added = 0
        for c in cs.courses {
            let name = cs.name(c)
            guard !existing.contains(CourseLibrary.fold(name)) else { continue }
            years[yi].semesters[si].units.append(GradeUnit(name: name, items: [GradeItem(name: "CC1"), GradeItem(name: "CC2")]))
            added += 1
        }
        ToastCenter.shared.show(added == 0 ? "Toutes tes matières sont déjà là." : "\(added) matière\(added > 1 ? "s" : "") ajoutée\(added > 1 ? "s" : "") : vérifie les crédits ✓")
    }
}

// MARK: - Vue

struct GradesToolView: View {
    @ObservedObject var g: GradesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .grades)
            if let yi = g.index {
                let year = $g.years[yi]
                let result = GradeCalc.year(g.years[yi], simulate: g.simulate)
                toolbar(year)
                summary(result, rules: g.years[yi].rules)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(year.semesters) { $sem in
                            SemesterSection(g: g, sem: $sem, result: result.semesters[sem.id], rules: g.years[yi].rules,
                                            remove: { year.wrappedValue.semesters.removeAll { $0.id == sem.id } })
                        }
                        Button {
                            withAnimation { year.wrappedValue.semesters.append(GradeSemester(name: "S\(year.wrappedValue.semesters.count + 1)")) }
                        } label: { Label("Ajouter un semestre", systemImage: "plus") }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(20)
    }

    private func toolbar(_ year: Binding<GradeYear>) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { g.yearID ?? UUID() }, set: { g.yearID = $0 })) {
                ForEach(g.years) { y in Text(y.name).tag(y.id) }
            }
            .labelsHidden().frame(width: 230)
            TextField("Nom de l'année", text: year.name).textFieldStyle(.roundedBorder).frame(width: 220)
            Menu {
                Button("Nouvelle année (UE validées reportées)") { g.newYear(carry: true) }
                Button("Nouvelle année (même maquette, sans notes)") { g.newYear(carry: false) }
                if g.years.count > 1 {
                    Divider()
                    Button("Supprimer cette année", role: .destructive) { g.deleteCurrentYear() }
                }
            } label: { Label("Année", systemImage: "calendar.badge.plus") }
                .fixedSize()
            Spacer()
            Menu {
                ForEach(year.wrappedValue.semesters) { s in
                    Button("Dans \(s.name)") { g.importCourses(into: s.id) }
                }
            } label: { Label("Importer mes matières", systemImage: "books.vertical") }
                .fixedSize()
                .help("Crée une UE par matière de « Mes cours »")
            Toggle(isOn: $g.simulate) { Label("Simulation", systemImage: "wand.and.stars") }
                .toggleStyle(.button)
                .help("Imagine tes prochaines notes pour voir le résultat")
            Button { g.showRules.toggle() } label: { Label("Règles", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $g.showRules) { RulesPopover(rules: year.rules).padding(16).frame(width: 340) }
        }
    }

    private func summary(_ r: YearResult, rules: GradeRules) -> some View {
        HStack(spacing: 14) {
            ECTSRing(acquired: r.acquired, total: r.credits).frame(width: 92, height: 92)
            statTile("Moyenne de l'année", r.average, rules: rules, provisional: !r.complete)
            ForEach(g.current?.semesters ?? []) { s in
                if let sr = r.semesters[s.id] {
                    statTile("Moyenne \(s.name)", sr.average, rules: rules, provisional: !sr.complete,
                             footer: "\(GradeCalc.fmt(sr.acquired))/\(GradeCalc.fmt(sr.credits)) ECTS")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if r.complete {
                    Text(r.validated ? "Année validée 🎉" : (r.acquired > 0 ? "Année non validée : \(GradeCalc.fmt(r.acquired)) ECTS gardés" : "Année non validée"))
                        .font(.headline).foregroundStyle(r.validated ? Color.green : Color.red)
                } else {
                    let t = GradeCalc.neededText(r.needed, count: r.remainingCount, pass: rules.pass)
                    Text("Pour valider l'année").font(.caption).foregroundStyle(.secondary)
                    Text(t.0).font(.callout.weight(.semibold)).foregroundStyle(t.1).fixedSize(horizontal: false, vertical: true)
                }
                if g.simulate {
                    Label("Simulation : les notes violettes sont imaginaires", systemImage: "wand.and.stars")
                        .font(.caption).foregroundStyle(Color.purple)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }

    private func statTile(_ title: String, _ v: Double?, rules: GradeRules, provisional: Bool, footer: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(v.map { GradeCalc.fmt($0) } ?? "—")
                .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(GradeCalc.color(v, pass: rules.pass))
            Text(footer ?? (provisional ? "provisoire" : "définitive")).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 110, alignment: .leading)
    }
}

struct ECTSRing: View {
    let acquired: Double
    let total: Double

    var body: some View {
        let p = total > 0 ? min(1, acquired / total) : 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 9)
            Circle().trim(from: 0, to: p)
                .stroke(AngularGradient(gradient: Gradient(colors: [.teal, .green]), center: .center), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: p)
            VStack(spacing: 0) {
                Text(GradeCalc.fmt(acquired)).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                Text("/ \(GradeCalc.fmt(total)) ECTS").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

struct RulesPopover: View {
    @Binding var rules: GradeRules

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Règles de validation").font(.headline)
            Toggle("Compensation entre les UE d'un semestre", isOn: $rules.semesterCompensation)
            Toggle("Compensation entre S1 et S2 (à l'année)", isOn: $rules.yearCompensation)
            Toggle("Rattrapage : garder la meilleure note", isOn: $rules.resitBest)
            HStack {
                Text("Note plancher pour compenser")
                TextField("aucune", text: $rules.floor).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            Text("Vérifie les règles exactes dans les modalités de contrôle des connaissances (MCC) de ta licence : elles changent d'une fac à l'autre.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SemesterSection: View {
    @ObservedObject var g: GradesStore
    @Binding var sem: GradeSemester
    let result: SemesterResult?
    let rules: GradeRules
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("S1", text: $sem.name).font(.title2.bold()).textFieldStyle(.plain).frame(width: 80)
                if let r = result {
                    Text(r.average.map { GradeCalc.fmt($0) } ?? "—")
                        .font(.title3.bold().monospacedDigit()).foregroundStyle(GradeCalc.color(r.average, pass: rules.pass))
                    Text("\(GradeCalc.fmt(r.acquired))/\(GradeCalc.fmt(r.credits)) ECTS").foregroundStyle(.secondary)
                    if r.complete {
                        Text(r.validated ? "Semestre validé ✓" : "Semestre non validé")
                            .font(.callout.weight(.semibold)).foregroundStyle(r.validated ? Color.green : Color.red)
                    } else {
                        let t = GradeCalc.neededText(r.needed, count: r.remainingCount, pass: rules.pass)
                        Text(t.0).font(.callout).foregroundStyle(t.1)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sem.units.append(GradeUnit(name: "Nouvelle UE", items: [GradeItem(name: "CC1"), GradeItem(name: "CC2")]))
                    }
                } label: { Label("UE", systemImage: "plus") }
                Menu {
                    Button("Supprimer \(sem.name)", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if sem.units.isEmpty {
                Text("Ajoute tes UE avec « + UE », ou « Importer mes matières » en haut pour partir de tes dossiers de cours.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach($sem.units) { $u in
                    UnitCard(g: g, u: $u, result: result?.units[u.id], rules: rules) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { sem.units.removeAll { $0.id == u.id } }
                    }
                }
            }
        }
    }
}

struct UnitCard: View {
    @ObservedObject var g: GradesStore
    @Binding var u: GradeUnit
    let result: UnitResult?
    let rules: GradeRules
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Nom de l'UE", text: $u.name).font(.headline).textFieldStyle(.plain)
                TextField("6", text: $u.credits).textFieldStyle(.roundedBorder).frame(width: 40).multilineTextAlignment(.trailing)
                Text("ECTS").font(.caption).foregroundStyle(.secondary)
                Text(result?.average.map { GradeCalc.fmt($0) } ?? "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(GradeCalc.color(result?.average, pass: rules.pass))
                    .frame(minWidth: 52, alignment: .trailing)
            }
            if let r = result {
                HStack(spacing: 6) {
                    Text(r.status.label).font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(r.status.color.opacity(0.15)))
                        .foregroundStyle(r.status.color)
                    if r.status == .pending {
                        let t = GradeCalc.neededText(r.needed, count: r.remainingCount, pass: rules.pass, maxPossible: r.maxPossible)
                        Text(t.0).font(.caption).foregroundStyle(t.1).lineLimit(2)
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    Text("Épreuve"); Text("Coef"); Text("Note"); Text("Ratt.").help("Session 2 / rattrapage"); Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach($u.items) { $it in
                    GridRow {
                        TextField("CC1", text: $it.name).textFieldStyle(.roundedBorder)
                        TextField("1", text: $it.weight).textFieldStyle(.roundedBorder).frame(width: 44)
                        noteField($it)
                        TextField("", text: $it.resit).textFieldStyle(.roundedBorder).frame(width: 52)
                        Button { withAnimation { u.items.removeAll { $0.id == it.id } } } label: {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .disabled(u.carried)
            HStack {
                Button { withAnimation { u.items.append(GradeItem(name: "CC\(u.items.count + 1)")) } } label: {
                    Label("Épreuve", systemImage: "plus")
                }
                .buttonStyle(.borderless).disabled(u.carried)
                Spacer()
                Menu {
                    Toggle("Acquise l'an dernier (report)", isOn: $u.carried)
                    Divider()
                    Button("Supprimer l'UE", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .font(.callout)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke((result?.status.color ?? .clear).opacity(result?.status == .pending ? 0 : 0.35)))
        .opacity(u.carried ? 0.75 : 1)
    }

    @ViewBuilder
    private func noteField(_ it: Binding<GradeItem>) -> some View {
        let value = GradeCalc.num(it.wrappedValue.note)
        if g.simulate && it.wrappedValue.note.trimmingCharacters(in: .whitespaces).isEmpty && it.wrappedValue.resit.isEmpty {
            TextField("?", text: it.simulated)
                .textFieldStyle(.roundedBorder).frame(width: 52)
                .foregroundStyle(Color.purple)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.purple.opacity(0.12)))
                .help("Note imaginée (simulation)")
        } else {
            TextField("", text: it.note)
                .textFieldStyle(.roundedBorder).frame(width: 52)
                .foregroundStyle(value.map { $0 > 20 || $0 < 0 } == true ? Color.red : Color.primary)
        }
    }
}

// MARK: - Widget d'accueil

struct GradesWidget: View {
    @ObservedObject var g = GradesStore.shared
    let open: () -> Void

    var body: some View {
        Card(title: "Notes & ECTS", icon: "chart.bar.doc.horizontal", tint: .green,
             accessory: AnyView(Button("Ouvrir", action: open).buttonStyle(.borderless))) {
            if let y = g.current {
                let r = GradeCalc.year(y, simulate: false)
                HStack(spacing: 14) {
                    ECTSRing(acquired: r.acquired, total: r.credits).frame(width: 74, height: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(r.average.map { GradeCalc.fmt($0) } ?? "—")
                                .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(GradeCalc.color(r.average, pass: y.rules.pass))
                            Text(r.complete ? "de moyenne" : "de moyenne (provisoire)").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(y.semesters) { s in
                            if let sr = r.semesters[s.id], !sr.complete, !s.units.isEmpty {
                                let t = GradeCalc.neededText(sr.needed, count: sr.remainingCount, pass: y.rules.pass)
                                Text("\(s.name) : " + t.0.prefix(1).lowercased() + String(t.0.dropFirst()))
                                    .font(.caption).foregroundStyle(t.1).lineLimit(2)
                            }
                        }
                        if y.semesters.allSatisfy({ $0.units.isEmpty }) {
                            Text("Ajoute tes UE pour suivre ta moyenne et tes crédits.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
