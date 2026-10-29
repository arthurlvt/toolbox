import Foundation

/// Un exercice de la banque prêt à être recopié dans un sujet d'entraînement.
public struct ComposeItem {
    public let id: Int
    public let numero: String
    public let texte: String
    public let tex: String?        // .tex du sujet d'origine
    public let rang: Int           // position de l'exercice dans son sujet (0…)
    public let nbExercices: Int    // nombre d'exercices de ce sujet
    public let niveau: String
    public let matiere: String
    public let annee: String
    public let session: String

    public var source: String {
        [niveau, matiere, annee, session.isEmpty ? "" : "session \(session)", numero.isEmpty ? "" : "exercice \(numero)"]
            .filter { !$0.isEmpty && $0 != "?" }.joined(separator: ", ")
    }
}

public struct ComposeResult {
    public let tex: URL
    public let pdf: URL?
    public let log: String
    public let fromLatex: Int      // exercices repris tels quels du .tex d'origine
    public let fromText: Int       // exercices reconstruits à partir du texte brut
}

extension AnnalesBank {

    // MARK: Choix des exercices

    /// Tire au hasard `count` exercices d'une matière, parmi ceux tagués avec l'une des notions
    /// (toutes les notions si la liste est vide). Un seul exercice par sujet tant que c'est possible.
    public func pickExercises(matiere: String, niveau: String?, notions: [String], count: Int,
                              excluding: Set<Int> = []) throws -> [Int] {
        var conditions = ["s.matiere = ?", "s.role IN ('sujet', 'variante')"]
        var params: [SQLiteDB.Value] = [.text(matiere)]
        if let n = niveau, !n.isEmpty { conditions.append("s.niveau = ?"); params.append(.text(n)) }
        if !notions.isEmpty {
            conditions.append("e.id IN (SELECT exercice_id FROM tag WHERE notion IN (\(notions.map { _ in "?" }.joined(separator: ", "))))")
            params += notions.map { .text($0) }
        }
        let rows = try db.query("""
            SELECT e.id, e.sujet_id FROM exercice e JOIN sujet s ON s.id = e.sujet_id
            WHERE \(conditions.joined(separator: " AND ")) ORDER BY random()
            """, params)
        var chosen: [Int] = []
        var usedSujets = Set<String>()
        var leftovers: [Int] = []
        for r in rows {
            guard let id = Int(r["id"] ?? ""), !excluding.contains(id) else { continue }
            let sujet = r["sujet_id"] ?? ""
            if usedSujets.contains(sujet) { leftovers.append(id); continue }
            usedSujets.insert(sujet)
            chosen.append(id)
            if chosen.count == count { return chosen }
        }
        return chosen + leftovers.prefix(count - chosen.count)
    }

    public func composeItems(_ ids: [Int]) throws -> [ComposeItem] {
        guard !ids.isEmpty else { return [] }
        let rows = try db.query("""
            SELECT e.id, e.numero, e.texte, s.tex, s.niveau, s.matiere, s.annee_univ, s.session,
                   (SELECT COUNT(*) FROM exercice e2 WHERE e2.sujet_id = e.sujet_id AND e2.id < e.id) AS rang,
                   (SELECT COUNT(*) FROM exercice e3 WHERE e3.sujet_id = e.sujet_id) AS nb
            FROM exercice e JOIN sujet s ON s.id = e.sujet_id
            WHERE e.id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))
            """, ids.map { .int($0) })
        let byID = Dictionary(rows.compactMap { r -> (Int, ComposeItem)? in
            guard let id = Int(r["id"] ?? "") else { return nil }
            return (id, ComposeItem(id: id, numero: r["numero"] ?? "", texte: r["texte"] ?? "", tex: r["tex"],
                                    rang: Int(r["rang"] ?? "0") ?? 0, nbExercices: Int(r["nb"] ?? "0") ?? 0,
                                    niveau: r["niveau"] ?? "", matiere: r["matiere"] ?? "",
                                    annee: r["annee_univ"] ?? "", session: r["session"] ?? ""))
        }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }   // l'ordre choisi par l'utilisateur
    }

    // MARK: Fabrication du sujet

    /// Les environnements exercice / exercicebonus d'un .tex, dans l'ordre.
    static func exerciseBlocks(_ tex: String) -> [String] {
        Rx(#"(?s)\\begin\{(exercice|exercicebonus)\}.*?\\end\{\1\}"#).all(tex).compactMap { $0[0] }
    }

    static func block(for item: ComposeItem) -> (String, Bool) {
        let mention = "{\\footnotesize\\itshape (Tiré de : \(AnnalesText.latexEscape(item.source)))}\\par\n"
        if let path = item.tex, let tex = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
            let blocks = exerciseBlocks(tex)
            if blocks.count == item.nbExercices, item.rang < blocks.count {
                let b = blocks[item.rang]
                // la mention de provenance juste après \begin{exercice}[…][…]
                let head = Rx(#"^\\begin\{(?:exercice|exercicebonus)\}(?:\[[^\]\n]*\]){0,2}"#).first(b)?[0] ?? ""
                let rest = String(String(b.dropFirst(head.count)).drop(while: { $0 == "\n" }))
                return (head + "\n" + mention + rest, true)
            }
        }
        // Repli : le texte brut extrait au dépôt.
        let titre = item.numero.isEmpty ? "" : "Exercice \(item.numero) d'origine"
        let corps = AnnalesText.latexEscape(item.texte)
            .components(separatedBy: "\n\n").joined(separator: "\n\n\\medskip\n")
        return ("\\begin{exercice}[][\(titre)]\n" + mention + corps + "\n\\end{exercice}", false)
    }

    /// Écrit (et compile) un sujet d'entraînement dans <banque>/entrainements/.
    public func compose(ids: [Int], titre: String, matiereNom: String, latexFolder: URL,
                        engine: LatexEngine = .pdflatex) throws -> ComposeResult {
        let items = try composeItems(ids)
        guard !items.isEmpty else { throw PDFToolError.commandFailed("aucun exercice à assembler") }

        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "yyyy-MM-dd_HH'h'mm"
            return f.string(from: Date())
        }()
        let slug = AnnalesText.normaliser(titre).split(separator: " ").prefix(6).joined(separator: "-")
        let dir = FileUtils.unique(url("entrainements").appendingPathComponent(stamp + (slug.isEmpty ? "" : "_" + slug)))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cls = latexFolder.appendingPathComponent("annales.cls")
        if fm.fileExists(atPath: cls.path) {
            try? fm.copyItem(at: cls, to: dir.appendingPathComponent("annales.cls"))
        }

        var fromLatex = 0, fromText = 0
        var body: [String] = []
        for item in items {
            let (b, ok) = Self.block(for: item)
            if ok { fromLatex += 1 } else { fromText += 1 }
            body.append(b)
        }
        let tex = """
        % Sujet d'entraînement composé par Toolbox à partir de la banque d'annales.
        \\documentclass[td]{annales}
        \\matiere{\(AnnalesText.latexEscape(matiereNom))}
        \\titre{\(AnnalesText.latexEscape(titre.isEmpty ? "Sujet d'entraînement" : titre))}
        \\begin{document}

        \(body.joined(separator: "\n\n"))

        \\end{document}

        """
        let texURL = dir.appendingPathComponent("sujet.tex")
        try tex.write(to: texURL, atomically: true, encoding: .utf8)

        var pdf: URL?
        var log = ""
        if let r = try? Latex.compile(texURL, engine: engine, texInputs: [latexFolder, dir]) {
            log = r.log
            if r.success { pdf = r.pdf }
        }
        return ComposeResult(tex: texURL, pdf: pdf, log: log, fromLatex: fromLatex, fromText: fromText)
    }

    // MARK: Ménage

    /// Supprime de la banque le sujet qui contient cet exercice : base, fichiers produits
    /// (mis à la corbeille) et registre, pour qu'un nouveau dépôt du même fichier soit retraité.
    @discardableResult
    public func deleteSujet(exerciceID: Int) throws -> String {
        guard let row = try db.query("""
            SELECT s.id, s.empreinte, s.pdf, s.tex, s.fichier, s.matiere, s.annee_univ FROM sujet s
            JOIN exercice e ON e.sujet_id = s.id WHERE e.id = ?
            """, [.int(exerciceID)]).first, let sujetID = Int(row["id"] ?? "") else {
            throw PDFToolError.commandFailed("sujet introuvable dans la base")
        }
        let fm = FileManager.default
        for key in ["pdf", "tex"] {
            if let p = row[key], !p.isEmpty, fm.fileExists(atPath: p) {
                try? fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            }
        }
        try db.run("DELETE FROM sujet WHERE id = ?", [.int(sujetID)])
        let sha = row["empreinte"] ?? ""
        let rest = Int(try db.query("SELECT COUNT(*) AS n FROM sujet WHERE empreinte = ?", [.text(sha)]).first?["n"] ?? "0") ?? 0
        if rest == 0, let e = registry[sha] {
            for p in e.sorties where fm.fileExists(atPath: p) {
                try? fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            }
            if !e.original.isEmpty, fm.fileExists(atPath: e.original) {
                try? fm.trashItem(at: URL(fileURLWithPath: e.original), resultingItemURL: nil)
            }
            try? fm.removeItem(at: url("textes/\(sha).txt"))
            forget(sha)
        }
        return [row["matiere"], row["annee_univ"]].compactMap { $0 }.joined(separator: " ")
    }

    /// Met tout le contenu de la banque à la corbeille (les sujets d'entraînement sont gardés).
    /// La banque est vide mais utilisable dès la prochaine ouverture.
    public static func reset(root: URL) throws -> Int {
        let fm = FileManager.default
        var moved = 0
        for name in ["originaux", "ranges", "a_verifier", "rejets", "doublons", "textes", ".travail",
                     "registre.json", "annalyse.db", "annalyse.db-wal", "annalyse.db-shm"] {
            let u = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: u.path) else { continue }
            if name == ".travail" {
                try? fm.removeItem(at: u)          // fichiers de travail : inutile de les garder
            } else {
                try fm.trashItem(at: u, resultingItemURL: nil)
                moved += 1
            }
        }
        return moved
    }
}
