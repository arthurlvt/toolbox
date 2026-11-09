import Foundation
import AppKit
import SwiftUI
import PDFKit
import PDFCore

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
        latexTemplates()
        pdfEditor()
        todayMerge()
        translations()
        clipTools()
        print("Toolbox --selftest : \(passed) réussi\(passed > 1 ? "s" : ""), \(failed.count) échec\(failed.count > 1 ? "s" : "")")
        for f in failed { print("  ✗ " + f) }
        return failed.isEmpty ? 0 : 1
    }

    // MARK: Couleurs & presse-papiers

    private static func clipTools() {
        let blue = RGBColor(hex: "#1A73E8")
        check("couleur : hex lu et réécrit", blue?.hex == "#1A73E8")
        check("couleur : hex court", RGBColor(hex: "#fa0")?.hex == "#FFAA00")
        check("couleur : rgb()", RGBColor.parse("rgb(26, 115, 232)")?.hex == "#1A73E8")
        check("couleur : nombres seuls", RGBColor.parse("26 115 232")?.hex == "#1A73E8")
        check("couleur : hsl()", RGBColor.parse("hsl(0, 100%, 50%)")?.hex == "#FF0000")
        check("couleur : SwiftUI", RGBColor.parse("Color(red: 1.0, green: 0.0, blue: 0.0)")?.hex == "#FF0000")
        check("couleur : \\definecolor", RGBColor.parse("\\definecolor{x}{HTML}{1A73E8}")?.hex == "#1A73E8")
        check("couleur : texte non reconnu", RGBColor.parse("bonjour") == nil)
        if let b = blue {
            let h = b.hsl
            check("couleur : HSL", abs(h.h - 214) < 1 && abs(h.s - 0.81) < 0.01 && abs(h.l - 0.506) < 0.01, "\(h)")
            check("couleur : aller-retour HSL", RGBColor.fromHSL(h.h, h.s, h.l).hex == "#1A73E8")
            check("couleur : complémentaire", b.rotated(180).hsl.h.rounded() == ((h.h + 180).truncatingRemainder(dividingBy: 360)).rounded())
            check("couleur : format LaTeX", b.formats(latexName: "bleu").contains { $0.1 == "\\definecolor{bleu}{HTML}{1A73E8}" })
        }
        check("couleur : contraste noir/blanc = 21", abs(RGBColor.black.contrast(with: .white) - 21) < 0.01)
        check("couleur : texte lisible sur jaune = noir", RGBColor(r: 1, g: 0.9, b: 0.2).readableText == .black)

        func tr(_ t: TextTransform, _ s: String) -> String { (try? t.run(s)) ?? "ERREUR" }
        check("texte : recoller un PDF", tr(.joinLines, "Une phrase cou-\npée en deux\nlignes.\n\nNouveau paragraphe.") == "Une phrase coupée en deux lignes.\n\nNouveau paragraphe.")
        check("texte : début de phrase", tr(.sentence, "BONJOUR. ÇA VA ? oui") == "Bonjour. Ça va ? Oui")
        check("texte : sans accents", tr(.noAccents, "Élève œuvre façade") == "Eleve oeuvre facade")
        check("texte : nom de fichier", tr(.slug, "Analyse 1 – TD n°3") == "analyse-1-td-n-3")
        check("texte : camelCase", tr(.camel, "nombre de pages") == "nombreDePages")
        check("texte : lignes uniques", tr(.uniqueLines, "a\nb\na") == "a\nb")
        check("texte : Base64 aller-retour", tr(.base64Decode, tr(.base64Encode, "Été 2026")) == "Été 2026")
        check("texte : JSON invalide refusé", (try? TextTransform.jsonPretty.run("{pas du json")) == nil)
        check("texte : guillemets droits", tr(.straightQuotes, "il dit «\u{00A0}oui\u{00A0}» et “non”") == "il dit \"oui\" et \"non\"")
        check("texte : guillemets français", tr(.frenchQuotes, "il dit \"oui\"") == "il dit «\u{00A0}oui\u{00A0}»")
    }

    // MARK: Traduction anglaise

    private static func translations() {
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            check("traduction : en.lproj/Localizable.strings dans l'appli", false, "fichier absent ou illisible")
            return
        }
        check("traduction : \(dict.count) textes en anglais", dict.count > 500)
        // un % de format en trop ou en moins ferait planter l'affichage
        let spec = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:@|l?l?d|l?f|s)")
        func count(_ s: String) -> Int { spec.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
        let wrong = dict.filter { count($0.key) != count($0.value) }.map { $0.key }
        check("traduction : mêmes %@ / %lld dans la clé et la traduction", wrong.isEmpty, wrong.prefix(3).joined(separator: " | "))
        check("traduction : titres d'outils", dict["Éditer un PDF"] == "Edit a PDF" && dict["Notes & ECTS"] == "Grades & ECTS")
    }

    // MARK: Accueil : même cours dans plusieurs calendriers

    private static func todayMerge() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func ev(_ id: String, _ title: String, _ start: Date, _ color: Color, _ loc: String = "") -> DayEvent {
            DayEvent(id: id, title: title, start: start, end: start.addingTimeInterval(5400), allDay: false, location: loc, color: color)
        }
        let list: [(event: DayEvent, calendar: String)] = [
            (ev("1", "ANALYSE 1 - CM", t0, .blue), "Moi"),
            (ev("2", "Analyse 1  -  CM", t0, .yellow, "AT02"), "Ami 1"),
            (ev("3", "ANALYSE 1 - CM", t0, .orange), "Ami 2"),
            (ev("4", "ANALYSE 1 - TD", t0, .yellow), "Ami 1"),
            (ev("5", "ANALYSE 1 - CM", t0.addingTimeInterval(86400), .blue), "Moi"),
        ]
        let m = DayEvent.merged(list)
        check("accueil : cours identiques regroupés", m.count == 3, "\(m.count) lignes")
        check("accueil : une couleur par calendrier", m.first?.colors.count == 3)
        check("accueil : salle reprise d'un doublon", m.first?.location == "AT02")
        check("accueil : TD d'un autre groupe gardé à part", m.contains { $0.title == "ANALYSE 1 - TD" })
    }

    // MARK: Éditeur de PDF

    private static func pdfEditor() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-selftest-edit-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("source.pdf")
        // une page avec deux mots : SECRET (à cacher) et GARDE (à garder)
        do {
            try PageDrawing.rewrite(to: src) { w in
                w.page(size: CGSize(width: 400, height: 300)) { ctx in
                    PageDrawing.drawText("SECRET", in: ctx, at: CGPoint(x: 40, y: 200), size: 24, color: CGColor(gray: 0, alpha: 1), anchor: .left)
                    PageDrawing.drawText("GARDE", in: ctx, at: CGPoint(x: 40, y: 100), size: 24, color: CGColor(gray: 0, alpha: 1), anchor: .left)
                }
            }
        } catch { check("éditeur : PDF de test", false, error.localizedDescription); return }
        guard let doc = PDFDocument(url: src), let page = doc.page(at: 0) else { check("éditeur : PDF de test lisible", false); return }

        let text = PDFAnnotation(bounds: CGRect(x: 200, y: 40, width: 150, height: 30), forType: .freeText, withProperties: nil)
        text.contents = "AJOUT"
        text.font = NSFont(name: "Helvetica", size: 16)
        text.fontColor = .black
        text.color = .clear
        page.addAnnotation(text)
        let link = PDFAnnotation(bounds: CGRect(x: 40, y: 95, width: 100, height: 30), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/toolbox")
        page.addAnnotation(link)

        let out1 = dir.appendingPathComponent("vectoriel.pdf")
        let r1 = try? PDFEdit.flatten(doc, to: out1)
        let s1 = PDFDocument(url: out1)?.page(at: 0)?.string ?? ""
        check("éditeur : texte ajouté intégré à la page", s1.contains("AJOUT"), s1)
        check("éditeur : texte d'origine conservé", s1.contains("SECRET") && s1.contains("GARDE"), s1)
        check("éditeur : page restée vectorielle sans cache", r1?.redactedPages == 0)
        let links1 = PDFDocument(url: out1)?.page(at: 0)?.annotations.filter { PDFEdit.kind($0) == "Link" } ?? []
        check("éditeur : lien gardé dans la copie", links1.contains { ($0.url ?? ($0.action as? PDFActionURL)?.url)?.absoluteString == "https://example.com/toolbox" }, "\(links1.count) lien(s)")
        check("éditeur : lien gardé au même endroit", links1.first.map { abs($0.bounds.minX - 40) < 1 && abs($0.bounds.minY - 95) < 1 } ?? false,
              "\(links1.first?.bounds ?? .zero)")

        let cover = PDFAnnotation(bounds: CGRect(x: 30, y: 190, width: 200, height: 40), forType: .square, withProperties: nil)
        cover.color = .white
        cover.interiorColor = .white
        cover.userName = EditStore.redactTag
        page.addAnnotation(cover)
        let out2 = dir.appendingPathComponent("cache.pdf")
        let r2 = try? PDFEdit.flatten(doc, to: out2, redact: { $0.userName == EditStore.redactTag })
        let s2 = PDFDocument(url: out2)?.page(at: 0)?.string ?? ""
        check("éditeur : texte sous le cache vraiment supprimé", !s2.contains("SECRET"), s2)
        check("éditeur : texte ajouté toujours là avec un cache", s2.contains("AJOUT"), s2)
        check("éditeur : page avec cache recréée", r2?.redactedPages == 1)

        // polices pour réécrire un texte
        check("polices : préfixe de sous-ensemble retiré", PDFFonts.baseName("ABCDEF+Calibri-Bold") == "Calibri-Bold")
        check("polices : nom sans préfixe inchangé", PDFFonts.baseName("Helvetica") == "Helvetica")
        check("polices : Times New Roman gras retrouvée",
              PDFFonts.installed("ABCDEF+TimesNewRomanPS-BoldMT", size: 12).map { $0.familyName == "Times New Roman" && NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
        check("polices : LaTeX chasse fixe → Menlo", PDFFonts.lookalike("XYZABC+CMTT10", size: 10).familyName == "Menlo")
        check("polices : LaTeX romain → serif", PDFFonts.lookalike("CMR10", size: 10).familyName == "Times New Roman")
        check("polices : Calibri → sans serif", PDFFonts.lookalike("Calibri", size: 10).familyName == "Helvetica")
        check("polices : couverture des lettres", PDFFonts.covers(NSFont(name: "Helvetica", size: 12)!, "Été 2026 !"))

        let blank = PDFEdit.blankPage(size: CGSize(width: 300, height: 500))
        check("éditeur : page blanche à la bonne taille", blank.map { PageDrawing.displaySize($0) == CGSize(width: 300, height: 500) } ?? false)
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

        // UE à matières (EC) : moyenne des matières pondérée par leur coefficient
        let groupe = GradeUnit(name: "UE", credits: "6", subjects: [
            GradeSubject(name: "A", weight: "2", items: [GradeItem(name: "CC1", note: "12"), GradeItem(name: "CC2", note: "12")]),
            GradeSubject(name: "B", weight: "1", items: [GradeItem(name: "CC1", note: "6")])])
        check("UE à matières : (2×12 + 1×6) / 3 = 10", GradeCalc.unit(groupe, rules: rules, simulate: false).average.map { near($0, 10) } ?? false)
        var groupe2 = groupe
        groupe2.subjects[1].items = [GradeItem(name: "CC1")]
        check("UE à matières : il faut 6 en B", GradeCalc.unit(groupe2, rules: rules, simulate: false).needed.map { near($0, 6) } ?? false,
              "\(String(describing: GradeCalc.unit(groupe2, rules: rules, simulate: false).needed))")

        // UE hors moyenne (ouverture, sport, PIX)
        let horsMoyenne = GradeUnit(name: "UEO", credits: "0", items: [GradeItem(name: "Note", note: "2")], inAverage: false)
        let s3 = GradeSemester(name: "S1", units: [unit("A", "12"), horsMoyenne])
        let y4 = GradeCalc.year(GradeYear(name: "L1", semesters: [s3]), simulate: false)
        check("UE hors moyenne ignorée", y4.semesters[s3.id]?.average.map { near($0, 12) } ?? false && y4.semesters[s3.id]?.validated == true)

        // pas de rattrapage
        var sansRatt = GradeRules()
        sansRatt.resit = false
        check("sans rattrapage, la note de session 2 est ignorée", GradeCalc.unit(rattrapage, rules: sansRatt, simulate: false).average.map { near($0, 7) } ?? false)

        // compensation entre semestres
        let sa = GradeSemester(name: "S1", units: [unit("A", "8")]), sb = GradeSemester(name: "S2", units: [unit("B", "12")])
        let y5 = GradeCalc.year(GradeYear(name: "L1", semesters: [sa, sb]), simulate: false)
        check("S1 à 8 compensé par S2 à 12", y5.validated && y5.semesters[sa.id]?.units[sa.units[0].id]?.status == .compensated)

        // anciens fichiers (sans code ni matières) relus sans perte
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Algo","credits":"6","items":[],"carried":false}"#
        let decoded = try? JSONDecoder().decode(GradeUnit.self, from: Data(old.utf8))
        check("ancien format de notes relu", decoded?.name == "Algo" && decoded?.inAverage == true && decoded?.subjects.isEmpty == true)
        // exemple complet de S1 (notes fictives) : moyenne 9,07, semestre non validé, 11 crédits (C/C++ 5 + UE 0153 4 + sport 2)
        var l1 = GradeYear(name: "L1", semesters: GradesStore.l1InfoAvignon())
        l1.rules.resit = false
        l1.rules.subjectCredits = true
        let notesS1 = ["S-E02-6502": "8", "S-E02-6504": "7", "S-E06-6508": "9", "S-E06-0151": "13", "S-E06-6506": "6",
                       "S-E02-6508": "8", "S-E06-0152": "11", "S-E06-0153": "14"]
        for ui in l1.semesters[0].units.indices {
            for si in l1.semesters[0].units[ui].subjects.indices {
                let code = l1.semesters[0].units[ui].subjects[si].code
                l1.semesters[0].units[ui].subjects[si].items = [GradeItem(name: "Note", note: notesS1[code] ?? "")]
            }
            if l1.semesters[0].units[ui].code == "T-U13-9201" { l1.semesters[0].units[ui].items = [GradeItem(name: "Résultat", note: "obt.")] }
        }
        l1.semesters.removeLast()
        let rl1 = GradeCalc.year(l1, simulate: false)
        let s1r = rl1.semesters[l1.semesters[0].id]
        check("S1 complet : moyenne 9,07", s1r?.average.map { near($0, 9.07, 0.01) } ?? false, "\(String(describing: s1r?.average))")
        check("S1 complet : 11 crédits obtenus", s1r.map { near($0.acquired, 11) } ?? false, "\(String(describing: s1r?.acquired))")
        check("maquette : 28 crédits d'UE + 2 de sport au S1", s1r.map { near($0.credits, 30) } ?? false)
        check("maquette L1 : 3 UE à matières par semestre",
              GradesStore.l1InfoAvignon().allSatisfy { $0.units.filter { !$0.subjects.isEmpty }.count == 3 })
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

    // MARK: Modèles LaTeX

    private static func latexTemplates() {
        for kind in LatexDocKind.allCases {
            let v = LatexDocTemplates.Values(kind: kind, matiere: "Analyse 1", number: 4, theme: "Limites & continuité",
                                             fullTitle: "\(kind.title) 4 -- Limites", author: "Arthur", formation: "Licence 1 Informatique",
                                             enseignant: "", objectif: "50 % du cours", annee: "2026--2027", corrige: true, language: "C")
            let t = LatexDocTemplates.document(v)
            let open = t.filter { $0 == "{" }.count - t.components(separatedBy: "\\{").count + 1
            let close = t.filter { $0 == "}" }.count - t.components(separatedBy: "\\}").count + 1
            check("modèle \(kind.title) : document complet", t.contains("\\begin{document}") && t.hasSuffix("\\end{document}"))
            check("modèle \(kind.title) : accolades équilibrées", open == close, "\(open) { pour \(close) }")
            check("modèle \(kind.title) : pas d'interpolation oubliée", !t.contains("\\#("))
        }
        // documents administratifs (informations fictives)
        let me = AdminFields(name: "Camille Martin", address: "12 rue des Lilas\nBât. B", cityLine: "84000 Avignon", phone: "06 00 00 00 00",
                             email: "camille@example.com", birthDate: "1er janvier 2006", birthPlace: "Marseille", studentID: "1234567",
                             school: "Avignon Université – L1 Informatique")
        check("administratif : ville tirée du code postal", me.city == "Avignon")
        for t in AdminType.allCases {
            var v = LatexDocTemplates.Values(kind: .admin, matiere: "", number: 1, theme: "relevé de notes & attestation", fullTitle: t.title,
                                             author: "", formation: "", enseignant: "", objectif: "", annee: "2026--2027", corrige: false, language: "C")
            v.adminType = t.rawValue
            v.me = me
            v.mandataire = "Alex Durand"
            let tex = LatexDocTemplates.document(v)
            let open = tex.filter { $0 == "{" }.count - tex.components(separatedBy: "\\{").count + 1
            let close = tex.filter { $0 == "}" }.count - tex.components(separatedBy: "\\}").count + 1
            check("administratif \(t.title) : complet", tex.contains("\\begin{document}") && tex.hasSuffix("\\end{document}"))
            check("administratif \(t.title) : accolades équilibrées", open == close, "\(open) { pour \(close) }")
            check("administratif \(t.title) : mes informations", tex.contains("Camille Martin") && tex.contains("\\newcommand{\\maville}{Avignon}"))
            check("administratif \(t.title) : texte échappé", tex.contains("\\&") && !tex.contains("notes & attestation"))
        }

        let lib = LatexLibrary.all
        check("bibliothèque LaTeX : \(lib.count) symboles et formules", lib.count > 200)
        check("bibliothèque : recherche « xor »", !LatexLibrary.search("xor").isEmpty)
        check("bibliothèque : recherche « dérivée produit »", LatexLibrary.search("dérivée produit").contains { $0.latex.contains("u'v") })
        check("paquet amssymb détecté", LatexLibraryState.hasPackage("amssymb", in: "\\documentclass{article}\n\\usepackage{amsmath, amssymb}"))
        check("paquet amssymb manquant repéré", !LatexLibraryState.hasPackage("amssymb", in: "\\documentclass{article}\n\\usepackage{amsmath}"))
        // suppression : dossier entier seulement s'il ne contient que le document
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("toolbox-selftest-\(UUID().uuidString)/TD4", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tex = dir.appendingPathComponent("TD4.tex")
        for n in ["TD4.tex", "TD4.pdf", "TD4.aux"] { try? "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        let doc = LatexDocsStore.Doc(url: tex, kind: "td", title: "TD 4", matiere: "", modified: Date(), createdByToolbox: true)
        check("suppression : dossier dédié entier", LatexDocsStore.targets(for: doc).wholeFolder)
        try? "x".write(to: dir.appendingPathComponent("sujet.pdf"), atomically: true, encoding: .utf8)
        let t2 = LatexDocsStore.targets(for: doc)
        check("suppression : le sujet PDF est gardé", !t2.wholeFolder && t2.items.count == 3 && !t2.items.contains { $0.lastPathComponent == "sujet.pdf" },
              t2.items.map { $0.lastPathComponent }.joined(separator: ", "))
        try? fm.removeItem(at: dir.deletingLastPathComponent())
        let answer = "Voici :\n```latex\n\\documentclass{article}\n\\begin{document}\nx\n\\end{document}\n```\nBonne journée"
        check("IA : document extrait du bloc ```latex", LatexDocGenerator.extractDocument(answer) == "\\documentclass{article}\n\\begin{document}\nx\n\\end{document}\n",
              LatexDocGenerator.extractDocument(answer) ?? "nil")
        check("IA : réponse sans document refusée", LatexDocGenerator.extractDocument("Désolé, je ne peux pas.") == nil)
        check("IA : titre court", LatexDocGenerator.shortTitle("une fiche de révision sur les suites, deux colonnes, avec tableau") == "Une fiche de révision sur les suites",
              LatexDocGenerator.shortTitle("une fiche de révision sur les suites, deux colonnes, avec tableau"))
        check("profil : « McDonald's Sénas » → calendrier Macdo", AppProfile.shortName("McDonald's Sénas") == "Macdo")
        check("profil : « Carrefour Cavaillon » → Carrefour", AppProfile.shortName("Carrefour Cavaillon") == "Carrefour")
        // calculatrice scientifique (les réglages de l'utilisateur sont remis comme avant)
        let saved = ["sci.deg", "prog.bits", "prog.signed", "prog.base"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        let sci = SciCalc()
        sci.degrees = true
        check("scientifique : sin(30) = 0,5 en degrés", (try? sci.value(of: "sin(30")).map { near($0, 0.5) } ?? false)
        sci.degrees = false
        check("scientifique : 2,5×(3+1 = 10 (parenthèse fermée toute seule)", (try? sci.value(of: "2,5×(3+1")).map { near($0, 10) } ?? false)
        check("scientifique : 50% = 0,5", (try? sci.value(of: "50%")).map { near($0, 0.5) } ?? false)
        check("scientifique : 8^(1/3 = 2", (try? sci.value(of: "8^(1/3")).map { near($0, 2) } ?? false)
        // calculatrice programmeur
        let pc = ProgCalc()
        pc.bits = 8; pc.signed = true
        pc.value = 0xFF
        check("programmeur : 0xFF signé sur 8 bits = −1", pc.text(pc.value, base: .dec) == "-1", pc.text(pc.value, base: .dec))
        pc.value = 200; pc.op("+"); pc.value = 100; pc.equals()
        check("programmeur : 200 + 100 sur 8 bits = 44 (débordement)", pc.value == 44, "\(pc.value)")
        pc.bits = 32; pc.signed = false
        pc.value = 0b1100; pc.op("XOR"); pc.value = 0b1010; pc.equals()
        check("programmeur : 1100 XOR 1010 = 0110", pc.value == 0b0110, "\(pc.value)")
        check("programmeur : affichage binaire groupé", pc.text(0xA5, base: .bin) == "1010 0101", pc.text(0xA5, base: .bin))
        // archives
        check("archive : nom de base de TP3.tar.gz", ArchiveTool.baseName(URL(fileURLWithPath: "/tmp/TP3.tar.gz")) == "TP3")
        check("archive : motifs zip pour .git", ArchiveTool.zipPatterns([".git"]).contains("*/.git/*"))
        // visite guidée : la bulle reste dans la fenêtre, même pour un bouton collé au bord
        let win = CGSize(width: 1200, height: 780)
        for r in [CGRect(x: 1150, y: 10, width: 40, height: 24), CGRect(x: 10, y: 740, width: 60, height: 30), CGRect(x: 0, y: 0, width: 220, height: 780)] {
            let g = TourOverlay.place(lens: TourOverlay.lens(for: r), size: win)
            check("visite : bulle dans la fenêtre pour \(Int(r.minX)),\(Int(r.minY))",
                  g.origin.x >= 0 && g.origin.y >= 0 && g.origin.x + TourOverlay.groupSize.width <= win.width && g.origin.y + TourOverlay.groupSize.height <= win.height)
        }
        check("visite : commence et finit au centre", TourStore.buildSteps().first?.target == nil && TourStore.buildSteps().last?.target == nil)
        check("échappement LaTeX", LatexDocTemplates.esc("50 % & C#") == "50 \\% \\& C\\#", LatexDocTemplates.esc("50 % & C#"))
    }
}
