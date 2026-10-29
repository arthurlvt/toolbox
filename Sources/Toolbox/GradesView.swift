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

/// Une matière (EC) dans une UE : son propre coefficient et ses épreuves.
struct GradeSubject: Codable, Identifiable, Equatable {
    var id = UUID()
    var code = ""
    var name: String
    var weight = "1"
    var items: [GradeItem] = [GradeItem(name: "CC1"), GradeItem(name: "CC2")]
}

/// Une UE : soit directement des épreuves (`items`), soit un groupe de matières (`subjects`).
struct GradeUnit: Codable, Identifiable, Equatable {
    var id = UUID()
    var code = ""
    var name: String
    var credits = "6"
    var items: [GradeItem] = []
    var subjects: [GradeSubject] = []
    var carried = false     // UE acquise l'année d'avant (redoublement)
    var inAverage = true    // false : UE d'ouverture, sport, PIX… (hors moyenne du semestre)

    init(id: UUID = UUID(), code: String = "", name: String, credits: String = "6", items: [GradeItem] = [],
         subjects: [GradeSubject] = [], carried: Bool = false, inAverage: Bool = true) {
        self.id = id; self.code = code; self.name = name; self.credits = credits
        self.items = items; self.subjects = subjects; self.carried = carried; self.inAverage = inAverage
    }

    enum CodingKeys: String, CodingKey { case id, code, name, credits, items, subjects, carried, inAverage }

    // les anciens fichiers (sans code / matières) se relisent sans rien perdre
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "UE"
        credits = try c.decodeIfPresent(String.self, forKey: .credits) ?? "6"
        items = try c.decodeIfPresent([GradeItem].self, forKey: .items) ?? []
        subjects = try c.decodeIfPresent([GradeSubject].self, forKey: .subjects) ?? []
        carried = try c.decodeIfPresent(Bool.self, forKey: .carried) ?? false
        inAverage = try c.decodeIfPresent(Bool.self, forKey: .inAverage) ?? true
    }
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
    var resit = true        // une session de rattrapage existe
    var resitBest = true    // rattrapage : meilleure des deux notes (sinon il remplace)

    init() {}

    enum CodingKeys: String, CodingKey { case pass, semesterCompensation, yearCompensation, floor, resit, resitBest }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pass = try c.decodeIfPresent(Double.self, forKey: .pass) ?? 10
        semesterCompensation = try c.decodeIfPresent(Bool.self, forKey: .semesterCompensation) ?? true
        yearCompensation = try c.decodeIfPresent(Bool.self, forKey: .yearCompensation) ?? true
        floor = try c.decodeIfPresent(String.self, forKey: .floor) ?? ""
        resit = try c.decodeIfPresent(Bool.self, forKey: .resit) ?? true
        resitBest = try c.decodeIfPresent(Bool.self, forKey: .resitBest) ?? true
    }
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
    var subjects: [UUID: UnitResult] = [:]
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
        if rules.resit, let r = num(i.resit) {
            if let first = g, rules.resitBest { g = max(first, r) } else { g = r }
        }
        if g == nil, simulate { g = num(i.simulated) }
        return g
    }

    static func unit(_ u: GradeUnit, rules: GradeRules, simulate: Bool) -> UnitResult {
        let credits = max(0, num(u.credits) ?? 0)
        guard !u.subjects.isEmpty else { return items(u.items, credits: credits, rules: rules, simulate: simulate) }
        // UE à matières : moyenne des matières pondérée par leur coefficient
        var subs: [UUID: UnitResult] = [:]
        for sub in u.subjects { subs[sub.id] = items(sub.items, credits: 0, rules: rules, simulate: simulate) }
        var ws = u.subjects.map { max(0, num($0.weight) ?? 1) }
        if ws.reduce(0, +) == 0 { ws = u.subjects.map { _ in 1 } }
        let W = ws.reduce(0, +)
        var a = 0.0, b = 0.0, pn = 0.0, pd = 0.0, count = 0, complete = true
        for (sub, w) in zip(u.subjects, ws) {
            guard let r = subs[sub.id] else { continue }
            a += w * (r.sum / r.total)
            b += w * (r.remaining / r.total)
            if let avg = r.average { pn += w * avg; pd += w }
            count += r.remainingCount
            complete = complete && r.complete
        }
        a /= W; b /= W
        return UnitResult(average: pd > 0 ? pn / pd : nil, complete: complete, sum: a, done: 1 - b, remaining: b, total: 1,
                          remainingCount: count, needed: complete || b == 0 ? nil : (rules.pass - a) / b,
                          maxPossible: a + 20 * b, credits: credits, subjects: subs)
    }

    /// Une liste d'épreuves pondérées (UE simple ou matière).
    static func items(_ list: [GradeItem], credits: Double, rules: GradeRules, simulate: Bool) -> UnitResult {
        if list.isEmpty {
            return UnitResult(average: nil, complete: false, sum: 0, done: 0, remaining: 1, total: 1, remainingCount: 1,
                              needed: rules.pass, maxPossible: 20, credits: credits)
        }
        var pairs = list.map { (w: max(0, num($0.weight) ?? 1), g: grade($0, rules: rules, simulate: simulate)) }
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
        var inAverageIDs = Set<UUID>()
        for s in y.semesters {
            var rs: [UUID: UnitResult] = [:]
            for u in s.units { rs[u.id] = unit(u, rules: rules, simulate: simulate) }
            // UE reportées sans note : ne pèsent pas dans la moyenne
            let counted = s.units.filter { $0.inAverage && !($0.carried && rs[$0.id]?.average == nil) }
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
            let complete = s.units.allSatisfy { u in u.carried || !u.inAverage || rs[u.id]?.complete == true } && !counted.isEmpty
            let validated = complete && a >= rules.pass - 1e-9 && counted.allSatisfy { rs[$0.id].map(floorOK) ?? true }
            for u in s.units where u.inAverage { inAverageIDs.insert(u.id) }
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
        let yearValidated = yearComplete && A >= rules.pass - 1e-9
            && units.filter { inAverageIDs.contains($0.key) }.values.allSatisfy(floorOK)

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
                } else if r.complete && !u.inAverage {
                    r.status = .failed          // hors moyenne : pas de compensation
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
                var nu = GradeUnit(code: u.code, name: u.name, credits: u.credits, inAverage: u.inAverage)
                let status = r.semesters[s.id]?.units[u.id]?.status
                if carry, let st = status, st.counts {
                    let keep: (GradeItem) -> GradeItem = { var i = $0; i.id = UUID(); i.simulated = ""; return i }
                    nu.items = u.items.map(keep)
                    nu.subjects = u.subjects.map { var x = $0; x.id = UUID(); x.items = x.items.map(keep); return x }
                    nu.carried = true
                } else {
                    let blank: (GradeItem) -> GradeItem = { GradeItem(name: $0.name, weight: $0.weight) }
                    nu.items = u.items.map(blank)
                    nu.subjects = u.subjects.map { GradeSubject(code: $0.code, name: $0.name, weight: $0.weight, items: $0.items.map(blank)) }
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

    // MARK: Maquette L1 Informatique (CERI, Avignon Université)

    static func l1InfoAvignon() -> [GradeSemester] {
        func ue(_ code: String, _ name: String, _ subs: [(String, String)]) -> GradeUnit {
            GradeUnit(code: code, name: name, credits: "", subjects: subs.map { GradeSubject(code: $0.0, name: $0.1) })
        }
        func extra(_ code: String, _ name: String) -> GradeUnit {
            GradeUnit(code: code, name: name, credits: "0", items: [GradeItem(name: "Note")], inAverage: false)
        }
        let s1 = GradeSemester(name: "S1", units: [
            ue("S-U06-0151", "Mener un raisonnement logique", [
                ("S-E02-6502", "Bases de mathématiques"),
                ("S-E02-6504", "Bases de la programmation, support Python"),
                ("S-E06-6508", "Fondement de l'informatique")]),
            ue("S-U06-0152", "Analyser et structurer un processus algorithmique", [
                ("S-E06-0151", "Bases de la programmation, support C/C++"),
                ("S-E06-6506", "Analyse 1"),
                ("S-E02-6508", "AMS Analyse et programmation")]),
            ue("S-U06-0153", "Maîtriser son environnement d'apprentissage en informatique", [
                ("S-E06-0152", "Anglais"),
                ("S-E06-0153", "Méthodologie de travail pour l'informatique")]),
            extra("S-L02-0101", "UE d'ouverture"),
            extra("T-U13-9201", "UEO SUAPS : sport"),
            extra("S-L02-0003", "UE de renforcement"),
        ])
        let s2 = GradeSemester(name: "S2", units: [
            ue("S-U06-0154", "Modéliser les objets et les systèmes pour la réalisation des tâches", [
                ("S-E06-0154", "Algèbre et programmation"),
                ("S-E06-0155", "Initiation à la programmation orientée objet"),
                ("S-E06-0156", "AMS Programmation orientée objet")]),
            ue("S-U06-0155", "Maîtriser les outils pour comprendre le fonctionnement des ordinateurs", [
                ("S-E06-0157", "Mathématiques discrètes"),
                ("S-E06-6517", "Structure des ordinateurs")]),
            ue("S-U06-0156", "Évoluer dans un environnement client-serveur", [
                ("S-E06-0158", "Conception web"),
                ("S-E06-0159", "Introduction aux systèmes d'exploitation"),
                ("S-E06-0160", "Anglais")]),
            extra("S-L06-0002", "UE d'ouverture"),
            extra("T-U12-9254", "UEO PIX 2"),
            extra("T-U12-9252", "UEO PIX 1"),
            extra("S-L02-0004", "UE de renforcement"),
        ])
        return [s1, s2]
    }

    func loadL1Template() {
        guard let i = index else { return }
        let hasData = years[i].semesters.contains { !$0.units.isEmpty }
        if hasData, !confirmDestructive("Remplacer les UE de « \(years[i].name) » ?",
                                        "Les UE et les notes déjà saisies dans cette année seront remplacées par la maquette de la L1 Informatique (CERI).",
                                        button: "Remplacer") { return }
        withAnimation {
            years[i].semesters = Self.l1InfoAvignon()
            years[i].rules.resit = false
            years[i].rules.semesterCompensation = true
            years[i].rules.yearCompensation = true
        }
        ToastCenter.shared.show("Maquette L1 chargée : renseigne les crédits (ECTS) des UE et les coefficients des matières ✓", seconds: 5)
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
                Divider()
                Button("Charger la maquette L1 Informatique (CERI)") { g.loadL1Template() }
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
            Toggle("Il existe une session de rattrapage", isOn: $rules.resit)
            if rules.resit {
                Toggle("Rattrapage : garder la meilleure note", isOn: $rules.resitBest)
            }
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
                Menu {
                    Button("UE avec plusieurs matières") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            sem.units.append(GradeUnit(name: "Nouvelle UE", subjects: [GradeSubject(name: "Matière 1"), GradeSubject(name: "Matière 2")]))
                        }
                    }
                    Button("UE simple (épreuves directement)") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            sem.units.append(GradeUnit(name: "Nouvelle UE", items: [GradeItem(name: "CC1"), GradeItem(name: "CC2")]))
                        }
                    }
                    Button("UE hors moyenne (ouverture, sport, PIX…)") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            sem.units.append(GradeUnit(name: "UE d'ouverture", credits: "0", items: [GradeItem(name: "Note")], inAverage: false))
                        }
                    }
                } label: { Label("UE", systemImage: "plus") }
                .fixedSize()
                Menu {
                    Button("Supprimer \(sem.name)", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if sem.units.isEmpty {
                Text("Ajoute tes UE avec « + UE », ou « Importer mes matières » en haut pour partir de tes dossiers de cours.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // UE à matières : pleine largeur, matières côte à côte
            ForEach($sem.units) { $u in
                if !u.subjects.isEmpty { card($u) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach($sem.units) { $u in
                    if u.subjects.isEmpty { card($u) }
                }
            }
        }
    }
}

extension SemesterSection {
    func card(_ u: Binding<GradeUnit>) -> some View {
        let id = u.wrappedValue.id
        return UnitCard(g: g, u: u, result: result?.units[id], rules: rules) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { sem.units.removeAll { $0.id == id } }
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
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Code UE", text: $u.code)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textFieldStyle(.plain)
                    TextField("Nom de l'UE", text: $u.name).font(.headline).textFieldStyle(.plain)
                }
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
                    if !u.inAverage {
                        Text("hors moyenne").font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                    if r.status == .pending {
                        let t = GradeCalc.neededText(r.needed, count: r.remainingCount, pass: rules.pass, maxPossible: r.maxPossible)
                        Text(t.0).font(.caption).foregroundStyle(t.1).lineLimit(2)
                    }
                }
            }
            if u.subjects.isEmpty {
                ItemsGrid(g: g, items: $u.items, rules: rules).disabled(u.carried)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach($u.subjects) { $sub in
                        SubjectBox(g: g, sub: $sub, result: result?.subjects[sub.id], rules: rules) {
                            withAnimation { u.subjects.removeAll { $0.id == sub.id } }
                        }
                        .disabled(u.carried)
                    }
                }
            }
            HStack(spacing: 12) {
                if u.subjects.isEmpty {
                    Button { withAnimation { u.items.append(GradeItem(name: "CC\(u.items.count + 1)")) } } label: {
                        Label("Épreuve", systemImage: "plus")
                    }
                    .buttonStyle(.borderless).disabled(u.carried)
                }
                Button { withAnimation { addSubject() } } label: { Label("Matière", systemImage: "plus.rectangle.on.rectangle") }
                    .buttonStyle(.borderless).disabled(u.carried)
                    .help("Découper l'UE en matières (EC), chacune avec son coefficient et ses épreuves")
                Spacer()
                Menu {
                    Toggle("Compte dans la moyenne du semestre", isOn: $u.inAverage)
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
        .opacity(u.carried ? 0.75 : (u.inAverage ? 1 : 0.85))
    }

    /// Première matière : les épreuves déjà notées de l'UE y sont déplacées.
    private func addSubject() {
        if u.subjects.isEmpty {
            let hasNotes = u.items.contains { !$0.note.isEmpty || !$0.resit.isEmpty }
            u.subjects = [GradeSubject(name: hasNotes ? u.name : "Matière 1",
                                       items: u.items.isEmpty ? [GradeItem(name: "CC1"), GradeItem(name: "CC2")] : u.items)]
            u.items = []
        } else {
            u.subjects.append(GradeSubject(name: "Matière \(u.subjects.count + 1)"))
        }
    }
}

/// Une matière (EC) dans une UE.
struct SubjectBox: View {
    @ObservedObject var g: GradesStore
    @Binding var sub: GradeSubject
    let result: UnitResult?
    let rules: GradeRules
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Code", text: $sub.code)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).textFieldStyle(.plain)
                    TextField("Matière", text: $sub.name).font(.callout.weight(.semibold)).textFieldStyle(.plain)
                }
                Text("coef").font(.caption2).foregroundStyle(.secondary)
                TextField("1", text: $sub.weight).textFieldStyle(.roundedBorder).frame(width: 36).multilineTextAlignment(.trailing)
                Text(result?.average.map { GradeCalc.fmt($0) } ?? "—")
                    .font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(GradeCalc.color(result?.average, pass: rules.pass))
                    .frame(minWidth: 42, alignment: .trailing)
                Menu {
                    Button("Ajouter une épreuve") { withAnimation { sub.items.append(GradeItem(name: "CC\(sub.items.count + 1)")) } }
                    Divider()
                    Button("Supprimer la matière", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            ItemsGrid(g: g, items: $sub.items, rules: rules)
            Button { withAnimation { sub.items.append(GradeItem(name: "CC\(sub.items.count + 1)")) } } label: {
                Label("Épreuve", systemImage: "plus")
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

/// Tableau des épreuves : nom, coef, note, rattrapage (si la licence en a un).
struct ItemsGrid: View {
    @ObservedObject var g: GradesStore
    @Binding var items: [GradeItem]
    let rules: GradeRules

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                Text("Épreuve"); Text("Coef"); Text("Note")
                if rules.resit { Text("Ratt.").help("Session 2 / rattrapage") }
                Text("")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach($items) { $it in
                GridRow {
                    TextField("CC1", text: $it.name).textFieldStyle(.roundedBorder)
                    TextField("1", text: $it.weight).textFieldStyle(.roundedBorder).frame(width: 44)
                    noteField($it)
                    if rules.resit {
                        TextField("", text: $it.resit).textFieldStyle(.roundedBorder).frame(width: 52)
                    }
                    Button { withAnimation { items.removeAll { $0.id == it.id } } } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
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
