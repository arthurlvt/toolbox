import Foundation
import SQLite3

// MARK: - Petite enveloppe SQLite

final class SQLiteDB {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw PDFToolError.commandFailed("base SQLite impossible à ouvrir : \(path)")
        }
        try exec("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(db) }

    var lastError: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw PDFToolError.commandFailed("SQLite : \(message)")
        }
    }

    enum Value {
        case text(String?)
        case int(Int)
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PDFToolError.commandFailed("SQLite : \(lastError)")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s?): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .text(nil): sqlite3_bind_null(stmt, idx)
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            }
        }
        return stmt
    }

    @discardableResult
    func run(_ sql: String, _ params: [Value] = []) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw PDFToolError.commandFailed("SQLite : \(lastError)") }
        return Int(sqlite3_last_insert_rowid(db))
    }

    func query(_ sql: String, _ params: [Value] = []) throws -> [[String: String]] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                if let text = sqlite3_column_text(stmt, c) { row[name] = String(cString: text) }
            }
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Banque d'annales

public struct RegistryEntry: Codable {
    public var original: String          // copie du dépôt dans originaux/
    public var nom: String               // nom du fichier déposé
    public var etat: String              // range, a_verifier, doublon, rejete, en_cours
    public var qualite: Int              // 0 photo, 1 scan, 2 PDF textuel, 3 document texte
    public var confiance: Double
    public var sorties: [String] = []    // PDF propres produits
    public var date: String
}

public struct BankSearchResult: Identifiable {
    public let id: Int
    public let niveau: String
    public let matiere: String
    public let annee: String
    public let session: String
    public let numero: String
    public let extrait: String
    public let notions: String
    public let statut: String
    public let pdf: String
}

/// La banque : un dossier rangé + un registre des empreintes + une base SQLite
/// (même schéma que annalyse/base.py, avec en plus le .tex et le PDF propre de chaque sujet).
///
///   <banque>/originaux/            copies des fichiers déposés (jamais modifiés)
///   <banque>/ranges/<etab>/<niveau>/<matiere>/<annee>_<session>.pdf (+ .tex, annales.cls)
///   <banque>/a_verifier/           sujets à relire (métadonnées incomplètes, doute de l'IA…)
///   <banque>/rejets/               documents rejetés par le contrôle de crédibilité
///   <banque>/doublons/             versions moins bonnes d'un sujet déjà présent
///   <banque>/textes/<empreinte>.txt  texte extrait (pour repérer les doublons de contenu)
///   <banque>/registre.json, annalyse.db
public final class AnnalesBank {
    public let root: URL
    let db: SQLiteDB
    private(set) var registry: [String: RegistryEntry] = [:]

    public init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        for sub in ["originaux", "ranges", "a_verifier", "rejets", "doublons", "textes", ".travail"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        db = try SQLiteDB(path: root.appendingPathComponent("annalyse.db").path)
        try db.exec(Self.schema)
        try migrate()
        if let data = try? Data(contentsOf: registryURL),
           let r = try? JSONDecoder().decode([String: RegistryEntry].self, from: data) {
            registry = r
        }
    }

    var registryURL: URL { root.appendingPathComponent("registre.json") }
    public func url(_ sub: String) -> URL { root.appendingPathComponent(sub) }

    static let schema = """
    CREATE TABLE IF NOT EXISTS sujet (
        id INTEGER PRIMARY KEY,
        empreinte TEXT NOT NULL, original TEXT, fichier TEXT, pages TEXT NOT NULL,
        role TEXT DEFAULT 'sujet', manuscrit INTEGER DEFAULT 0,
        etablissement TEXT, niveau TEXT, formation TEXT, matiere TEXT, annee_univ TEXT,
        session TEXT, version TEXT, statut TEXT DEFAULT 'pre_rempli',
        tex TEXT, pdf TEXT, verdict TEXT, motifs TEXT,
        UNIQUE (empreinte, pages)
    );
    CREATE TABLE IF NOT EXISTS exercice (
        id INTEGER PRIMARY KEY,
        sujet_id INTEGER NOT NULL REFERENCES sujet(id) ON DELETE CASCADE,
        numero TEXT, texte TEXT,
        UNIQUE (sujet_id, numero)
    );
    CREATE TABLE IF NOT EXISTS tag (
        exercice_id INTEGER NOT NULL REFERENCES exercice(id) ON DELETE CASCADE,
        notion TEXT NOT NULL, source TEXT NOT NULL,
        PRIMARY KEY (exercice_id, notion)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS exercice_fts USING fts5(
        texte, content='exercice', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER IF NOT EXISTS exercice_ai AFTER INSERT ON exercice BEGIN
        INSERT INTO exercice_fts(rowid, texte) VALUES (new.id, new.texte);
    END;
    CREATE TRIGGER IF NOT EXISTS exercice_ad AFTER DELETE ON exercice BEGIN
        INSERT INTO exercice_fts(exercice_fts, rowid, texte) VALUES ('delete', old.id, old.texte);
    END;
    """

    /// Colonnes ajoutées après coup (base créée par la version Python, par exemple).
    func migrate() throws {
        let existing = Set(try db.query("PRAGMA table_info(sujet)").compactMap { $0["name"] })
        let wanted = ["etablissement", "niveau", "formation", "tex", "pdf", "verdict", "motifs"]
        for col in wanted where !existing.contains(col) {
            try db.exec("ALTER TABLE sujet ADD COLUMN \(col) TEXT")
        }
    }

    // MARK: Registre

    public func entry(_ sha: String) -> RegistryEntry? { registry[sha] }

    public func record(_ sha: String, _ entry: RegistryEntry) {
        registry[sha] = entry
        if let data = try? JSONEncoder().encode(registry) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    /// Oublie un dépôt : un nouveau dépôt du même fichier sera retraité.
    public func forget(_ sha: String) {
        registry[sha] = nil
        if let data = try? JSONEncoder().encode(registry) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    public func saveText(_ sha: String, _ texte: String) {
        try? texte.write(to: url("textes/\(sha).txt"), atomically: true, encoding: .utf8)
    }

    /// Le dépôt déjà rangé qui ressemble le plus à ce texte (doublon de contenu).
    public func mostSimilar(to texte: String, excluding sha: String) -> (sha: String, jaccard: Double, inclusion: Double)? {
        let nouveau = Similarity.shingles(texte)
        var best: (String, Double, Double)?
        for (key, e) in registry where key != sha && (e.etat == "range" || e.etat == "a_verifier") {
            guard let other = try? String(contentsOf: url("textes/\(key).txt"), encoding: .utf8) else { continue }
            let s = Similarity.shingles(other)
            let j = Similarity.jaccard(nouveau, s), inc = Similarity.inclusion(nouveau, s)
            if best == nil || inc > best!.2 { best = (key, j, inc) }
        }
        return best.map { (sha: $0.0, jaccard: $0.1, inclusion: $0.2) }
    }

    /// Une meilleure version arrive : les sorties de l'ancienne partent dans doublons/.
    public func archiveAsDuplicate(_ sha: String, replacedBy: String) {
        guard var e = registry[sha] else { return }
        let fm = FileManager.default
        var moved: [String] = []
        for path in e.sorties {
            let src = URL(fileURLWithPath: path)
            let dst = FileUtils.unique(url("doublons").appendingPathComponent(src.lastPathComponent))
            if (try? fm.moveItem(at: src, to: dst)) != nil { moved.append(dst.path) }
            let texSrc = src.deletingPathExtension().appendingPathExtension("tex")
            try? fm.moveItem(at: texSrc, to: dst.deletingPathExtension().appendingPathExtension("tex"))
        }
        e.etat = "doublon"
        e.sorties = moved
        record(sha, e)
        _ = try? db.run("DELETE FROM sujet WHERE empreinte = ?", [.text(sha)])
    }

    // MARK: Base de données

    public struct SujetRecord {
        public var empreinte: String
        public var original: String
        public var fichier: String
        public var pages: String
        public var role: String
        public var manuscrit: Bool
        public var meta: AnnaleMetadata
        public var session: String?
        public var version: String?
        public var statut: String
        public var tex: String?
        public var pdf: String?
        public var verdict: String?
        public var motifs: String?
    }

    /// Insère ou met à jour un sujet ; ses anciens exercices sont remplacés.
    @discardableResult
    public func saveSujet(_ s: SujetRecord, exercices: [(Exercice, [String], String)]) throws -> Int {
        try db.run("""
            INSERT INTO sujet (empreinte, pages, original, fichier, role, manuscrit, etablissement, niveau,
                               formation, matiere, annee_univ, session, version, statut, tex, pdf, verdict, motifs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (empreinte, pages) DO UPDATE SET
                original = excluded.original, fichier = excluded.fichier, role = excluded.role,
                manuscrit = excluded.manuscrit, etablissement = excluded.etablissement, niveau = excluded.niveau,
                formation = excluded.formation, matiere = excluded.matiere, annee_univ = excluded.annee_univ,
                session = excluded.session, version = excluded.version, statut = excluded.statut,
                tex = excluded.tex, pdf = excluded.pdf, verdict = excluded.verdict, motifs = excluded.motifs
            """, [.text(s.empreinte), .text(s.pages), .text(s.original), .text(s.fichier), .text(s.role),
                  .int(s.manuscrit ? 1 : 0), .text(s.meta.etablissement), .text(s.meta.niveau),
                  .text(s.meta.formation), .text(s.meta.matiere), .text(s.meta.anneeUniv), .text(s.session),
                  .text(s.version), .text(s.statut), .text(s.tex), .text(s.pdf), .text(s.verdict), .text(s.motifs)])
        let id = Int(try db.query("SELECT id FROM sujet WHERE empreinte = ? AND pages = ?",
                                  [.text(s.empreinte), .text(s.pages)]).first?["id"] ?? "0") ?? 0
        try db.run("DELETE FROM exercice WHERE sujet_id = ?", [.int(id)])
        for (exercice, notions, source) in exercices {
            let exId = try db.run("INSERT INTO exercice (sujet_id, numero, texte) VALUES (?, ?, ?)",
                                  [.int(id), .text(exercice.numero), .text(exercice.texte)])
            for n in notions {
                try db.run("INSERT OR IGNORE INTO tag (exercice_id, notion, source) VALUES (?, ?, ?)",
                           [.int(exId), .text(n), .text(source)])
            }
        }
        return id
    }

    public func setStatut(pdf: String, statut: String, newPDF: String? = nil, newTex: String? = nil) throws {
        try db.run("UPDATE sujet SET statut = ?, pdf = COALESCE(?, pdf), tex = COALESCE(?, tex) WHERE pdf = ?",
                   [.text(statut), .text(newPDF), .text(newTex), .text(pdf)])
    }

    /// Recherche d'exercices (texte plein, accents ignorés) avec filtres.
    public func search(texte: String = "", niveau: String? = nil, matiere: String? = nil, notion: String? = nil,
                       enAttente: Bool = true, limite: Int = 200) throws -> [BankSearchResult] {
        var conditions = ["s.role IN ('sujet', 'variante')"]
        var params: [SQLiteDB.Value] = []
        var join = ""
        var extrait = "substr(e.texte, 1, 200)"
        if !enAttente { conditions.append("s.statut != 'en_attente'") }
        if let n = niveau, !n.isEmpty { conditions.append("s.niveau = ?"); params.append(.text(n)) }
        if let m = matiere, !m.isEmpty { conditions.append("s.matiere = ?"); params.append(.text(m)) }
        if let n = notion, !n.isEmpty {
            conditions.append("e.id IN (SELECT exercice_id FROM tag WHERE notion = ?)")
            params.append(.text(n))
        }
        let mots = AnnalesText.normaliser(texte).replacingOccurrences(of: "\"", with: " ")
            .split(separator: " ").filter { !$0.isEmpty }
        if !mots.isEmpty {
            join = "JOIN exercice_fts f ON f.rowid = e.id"
            conditions.append("exercice_fts MATCH ?")
            params.append(.text(mots.map { "\"\($0)\"" }.joined(separator: " ")))
            extrait = "snippet(exercice_fts, 0, '«', '»', '…', 18)"
        }
        params.append(.int(limite))
        let rows = try db.query("""
            SELECT e.id, s.niveau, s.matiere, s.annee_univ, s.session, s.statut, COALESCE(s.pdf, s.fichier) AS pdf,
                   e.numero, \(extrait) AS extrait,
                   (SELECT group_concat(notion, ', ') FROM tag WHERE exercice_id = e.id) AS notions
            FROM exercice e JOIN sujet s ON s.id = e.sujet_id \(join)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY s.niveau, s.matiere, s.annee_univ DESC, s.session, CAST(e.numero AS INTEGER)
            LIMIT ?
            """, params)
        return rows.map { r in
            BankSearchResult(id: Int(r["id"] ?? "0") ?? 0, niveau: r["niveau"] ?? "?", matiere: r["matiere"] ?? "?",
                             annee: r["annee_univ"] ?? "?", session: r["session"] ?? "?", numero: r["numero"] ?? "",
                             extrait: (r["extrait"] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " "),
                             notions: r["notions"] ?? "", statut: r["statut"] ?? "", pdf: r["pdf"] ?? "")
        }
    }

    /// Pour chaque notion d'une matière : nombre de sujets où elle tombe.
    public func stats(matiere: String, niveau: String?) throws -> (total: Int, rows: [(notion: String, sujets: Int, exercices: Int)]) {
        var filter = "s.matiere = ? AND s.role = 'sujet'"
        var params: [SQLiteDB.Value] = [.text(matiere)]
        if let n = niveau, !n.isEmpty { filter += " AND s.niveau = ?"; params.append(.text(n)) }
        let total = Int(try db.query("SELECT COUNT(*) AS n FROM sujet s WHERE \(filter)", params).first?["n"] ?? "0") ?? 0
        let rows = try db.query("""
            SELECT t.notion, COUNT(DISTINCT s.id) AS nb_sujets, COUNT(DISTINCT e.id) AS nb_exercices
            FROM tag t JOIN exercice e ON e.id = t.exercice_id JOIN sujet s ON s.id = e.sujet_id
            WHERE \(filter) GROUP BY t.notion ORDER BY nb_sujets DESC, nb_exercices DESC
            """, params)
        return (total, rows.map { (notion: $0["notion"] ?? "", sujets: Int($0["nb_sujets"] ?? "0") ?? 0,
                                   exercices: Int($0["nb_exercices"] ?? "0") ?? 0) })
    }

    public func summary() throws -> [(niveau: String, matiere: String, sujets: Int, enAttente: Int)] {
        let rows = try db.query("""
            SELECT niveau, matiere, COUNT(CASE WHEN role = 'sujet' THEN 1 END) AS sujets,
                   SUM(CASE WHEN statut = 'en_attente' THEN 1 ELSE 0 END) AS attente
            FROM sujet GROUP BY niveau, matiere ORDER BY niveau, matiere
            """)
        return rows.map { (niveau: $0["niveau"] ?? "?", matiere: $0["matiere"] ?? "?",
                           sujets: Int($0["sujets"] ?? "0") ?? 0, enAttente: Int($0["attente"] ?? "0") ?? 0) }
    }
}
