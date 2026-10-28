import Foundation

/// Tests des calculs sensibles, lancés par `Toolbox --selftest` (et par build.sh après chaque compilation).
/// Pas de XCTest : il n'est pas fourni avec les seuls outils en ligne de commande d'Apple.
enum SelfTest {
    private static var passed = 0
    private static var failed: [String] = []

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed.append(name + (detail().isEmpty ? "" : " → " + detail())) }
    }

    private static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { Swift.abs(a - b) <= tol * max(1, Swift.abs(b)) }

    static func run() -> Int32 {
        math()
        analysis()
        grades()
        planning()
        headphone()
        print("Toolbox --selftest : \(passed) réussi\(passed > 1 ? "s" : ""), \(failed.count) échec\(failed.count > 1 ? "s" : "")")
        for f in failed { print("  ✗ " + f) }
        return failed.isEmpty ? 0 : 1
    }

    // MARK: Calculatrice

    private static func value(_ expr: String, x: Double = 0) -> Double? {
        guard let n = try? MathEngine.parse(expr, userFunctions: ["f", "g"]) else { return nil }
        return try? MathEngine.evaluate(n, env: MathEnv(), x: x)
    }

    private static func math() {
        let cases: [(String, Double, Double)] = [
            ("2x", 3, 6), ("3(x+1)", 1, 6), ("x²", 4, 16), ("-x^2", 2, -4), ("2^3^2", 0, 512),
            ("|x-3|", 1, 2), ("3!", 0, 6), ("sqrt(16)", 0, 4), ("√9", 0, 3), ("ln(e)", 0, 1),
            ("sin(pi/2)", 0, 1), ("sin 2x", Double.pi / 4, 1), ("x sin x", Double.pi / 2, Double.pi / 2),
            ("2,5x", 2, 5), ("1/2x", 4, 2), ("x^(1/3)", -8, -2), ("exp(0)+cos 0", 0, 2),
        ]
        for (e, x, want) in cases {
            let got = value(e, x: x)
            check("calcul « \(e) » en x = \(x)", got.map { near($0, want) } ?? false, "obtenu \(got.map { "\($0)" } ?? "erreur"), attendu \(want)")
        }
        check("erreur sur parenthèse manquante", (try? MathEngine.parse("(x+1")) == nil)
        check("erreur sur symbole inconnu", (try? MathEngine.parse("x $ 2")) == nil)

        // dérivées exactes (simplifiées)
        let derivs: [(String, String)] = [("x^2", "2x"), ("sin(x)", "cos(x)"), ("3x + 5", "3")]
        for (e, want) in derivs {
            let got = (try? MathEngine.parse(e)).flatMap { try? MathEngine.derivative($0, env: MathEnv()) }.map { MathFormat.text(MathEngine.simplify($0)) }
            check("dérivée de \(e)", got == want, "obtenu \(got ?? "erreur"), attendu \(want)")
        }
        // dérivée évaluée : (x ln x)' = ln x + 1
        if let n = try? MathEngine.parse("x ln(x)"), let d = try? MathEngine.derivative(n, env: MathEnv()),
           let v = try? MathEngine.evaluate(d, env: MathEnv(), x: M_E) {
            check("dérivée de x ln x en e", near(v, 2), "obtenu \(v)")
        } else {
            check("dérivée de x ln x", false, "erreur")
        }

        // LaTeX
        let tex: [(String, String)] = [("x^2", "x^{2}"), ("1/2", "\\frac{1}{2}"), ("sqrt(x)", "\\sqrt{x}"), ("e^x", "\\mathrm{e}^{x}")]
        for (e, want) in tex {
            let got = (try? MathEngine.parse(e)).map { MathFormat.latex($0) }
            check("LaTeX de \(e)", got == want, "obtenu \(got ?? "erreur"), attendu \(want)")
        }
        check("forme exacte 1/3", MathFormat.exactGuess(1.0 / 3) == "1/3", MathFormat.exactGuess(1.0 / 3) ?? "nil")
        check("forme exacte √2/2", MathFormat.exactGuess(2.0.squareRoot() / 2) == "√2/2", MathFormat.exactGuess(2.0.squareRoot() / 2) ?? "nil")
        check("affichage 2,5", MathFormat.fr(2.5) == "2,5", MathFormat.fr(2.5))
    }

    private static func analysis() {
        func fn(_ e: String) -> MathEngine.Fn? { (try? MathEngine.parse(e)).flatMap { try? MathEngine.compile($0, env: MathEnv()) } }
        if let f = fn("sin(x)/x") {
            let r = MathAnalysis.limit(f, at: 0)
            check("lim sin(x)/x en 0 = 1", r.verdict.hasSuffix(": 1"), r.verdict)
        }
        if let f = fn("1/x") {
            let r = MathAnalysis.limit(f, at: 0)
            check("pas de limite de 1/x en 0", r.verdict.hasPrefix("Pas de limite"), r.verdict)
        }
        if let f = fn("(2x+1)/(x-3)") {
            let r = MathAnalysis.limit(f, at: .infinity)
            check("lim (2x+1)/(x-3) en +∞ = 2", r.verdict.hasSuffix(": 2"), r.verdict)
        }
        if let f = fn("x^2 - 2x - 3") {
            let roots = MathAnalysis.roots(f, from: -10, to: 10).map(MathAnalysis.clean)
            check("racines de x² - 2x - 3", roots.count == 2 && near(roots[0], -1, 1e-6) && near(roots[1], 3, 1e-6), "\(roots)")
        }
        if let f = fn("tan(x)") {
            let roots = MathAnalysis.roots(f, from: 1, to: 2)
            check("tan : pas de fausse racine à l'asymptote", roots.isEmpty, "\(roots)")
        }
    }

    // MARK: Notes et ECTS

    private static func grades() {
        let rules = GradeRules()
        let u = GradeUnit(name: "Analyse", credits: "6", items: [GradeItem(name: "CC1", weight: "1", note: "8"), GradeItem(name: "CC2", weight: "2")])
        let r = GradeCalc.unit(u, rules: rules, simulate: false)
        check("note nécessaire (8 au CC1 coef 1, CC2 coef 2)", r.needed.map { near($0, 11) } ?? false, "\(String(describing: r.needed))")
        check("moyenne provisoire", r.average.map { near($0, 8) } ?? false)

        let rattrapage = GradeUnit(name: "Algo", credits: "6", items: [GradeItem(name: "Exam", weight: "1", note: "7", resit: "12")])
        check("rattrapage : meilleure note", GradeCalc.unit(rattrapage, rules: rules, simulate: false).average.map { near($0, 12) } ?? false)

        func unit(_ name: String, _ note: String) -> GradeUnit {
            GradeUnit(name: name, credits: "6", items: [GradeItem(name: "Exam", weight: "1", note: note)])
        }
        let s1 = GradeSemester(name: "S1", units: [unit("A", "12"), unit("B", "8")])
        let year = GradeYear(name: "L1", semesters: [s1])
        let y = GradeCalc.year(year, simulate: false)
        let sr = y.semesters[s1.id]
        check("semestre à 10 validé par compensation", sr?.validated == true, "moyenne \(String(describing: sr?.average))")
        check("UE à 8 compensée", sr?.units[s1.units[1].id]?.status == .compensated)
        check("12 ECTS acquis", near(y.acquired, 12), "\(y.acquired)")

        var strict = GradeRules()
        strict.floor = "9"
        let y2 = GradeCalc.year(GradeYear(name: "L1", semesters: [s1], rules: strict), simulate: false)
        check("note plancher 9 : pas de compensation", y2.semesters[s1.id]?.units[s1.units[1].id]?.status == .failed)

        let s2 = GradeSemester(name: "S1", units: [unit("A", "12"), GradeUnit(name: "B", credits: "6", items: [GradeItem(name: "Exam", weight: "1")])])
        let y3 = GradeCalc.year(GradeYear(name: "L1", semesters: [s2]), simulate: false)
        check("note nécessaire pour valider le semestre", y3.semesters[s2.id]?.needed.map { near($0, 8) } ?? false,
              "\(String(describing: y3.semesters[s2.id]?.needed))")
    }

    // MARK: Planning

    private static func planning() {
        let r = ShiftParser.ranges(in: ShiftParser.normalize("sam. 31 oct. 2026, 11:30 – 14:30"))
        check("créneau 11:30 – 14:30", r.count == 1 && r[0].2 == 690 && r[0].3 == 870, "\(r)")
        let split = ShiftParser.ranges(in: ShiftParser.normalize("Ven 7/11 9h-12h 18h-22h"))
        check("coupure 9h-12h 18h-22h", split.count == 2 && split[1].2 == 1080 && split[1].3 == 1320, "\(split)")
        let night = ShiftParser.ranges(in: ShiftParser.normalize("Mercredi 5 novembre 18h → 1h"))
        check("fermeture après minuit", night.first.map { $0.3 - $0.2 == 7 * 60 } ?? false, "\(night)")
        let d = ShiftParser.dates(in: ShiftParser.normalize("sam. 31 oct. 2026"))
        check("date « sam. 31 oct. »", d.first.map { $0.2.day == 31 && $0.2.month == 10 && $0.2.weekday == 5 } ?? false, "\(d.map { $0.2 })")
        check("« mars » n'est pas « mardi »", ShiftParser.dates(in: "3 mars").first?.2.weekday == nil)

        // capture de l'app McDo : trois créneaux le même jour → une journée, deux pauses, 8 h 15 payées
        let text = """
        sam. 31 oct. 2026
        Quart de travail McDonald's SENAS
        sam. 31 oct. 2026, 11:30 – 14:30
        Quart de travail McDonald's SENAS
        sam. 31 oct. 2026, 18:45 – 21:00
        Quart de travail McDonald's SENAS
        sam. 31 oct. 2026, 15:00 – 18:00
        """
        let found = ShiftParser.parse(ShiftParser.tokens(fromText: text), name: nil, weekStart: nil, breakFor: { _ in 0 })
        check("3 créneaux lus", found.drafts.count == 3, "\(found.drafts.count)")
        let merged = PlanningStore.mergeByDay(found.drafts)
        check("regroupés en 1 journée", merged.count == 1, "\(merged.count)")
        if let m = merged.first {
            check("2 pauses (14:30–15:00, 18:00–18:45)", m.gaps.count == 2 && m.gapMinutes == 75, "\(m.gaps)")
            check("8 h 15 payées", m.paidMinutes == 495, "\(m.paidMinutes)")
            let s = WorkShift(start: m.start, end: m.end, breakMinutes: m.gaps.isEmpty ? m.breakMinutes : m.gapMinutes)
            check("8 h 15 une fois enregistré", s.paidMinutes == 495, "\(s.paidMinutes)")
        }

        // réparation de l'ancienne minute en trop
        let ref = Date(timeIntervalSinceReferenceDate: 815135400)
        let json: [String: Any] = [
            "id": UUID().uuidString, "start": ref.timeIntervalSinceReferenceDate, "end": ref.timeIntervalSinceReferenceDate + 570 * 60,
            "breakMinutes": 77, "note": "",
            "pauses": [["start": ref.timeIntervalSinceReferenceDate + 180 * 60, "end": ref.timeIntervalSinceReferenceDate + 210 * 60],
                       ["start": ref.timeIntervalSinceReferenceDate + 390 * 60, "end": ref.timeIntervalSinceReferenceDate + 435 * 60]],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json), let s = try? JSONDecoder().decode(WorkShift.self, from: data) {
            check("ancien shift réparé (77 → 75 min de pause)", s.breakMinutes == 75 && s.paidMinutes == 495, "\(s.breakMinutes), \(s.paidMinutes)")
        } else {
            check("décodage d'un shift", false, "erreur")
        }
    }

    // MARK: Casque

    private static func headphone() {
        let crc = HeadphoneStore.crc16([0x55, 0x60, 0x01, 0x07, 0xC0, 0x00, 0x00, 0x01])
        check("CRC de la demande de batterie (ac df)", crc == 0xDFAC, String(format: "%04x", crc))
    }
}
