import Foundation

/// Ce que le formulaire de dépôt déclare (champs vides = « laisser deviner »).
public struct DeclaredInfo: Codable, Equatable {
    public var etablissement = ""
    public var niveau = ""
    public var matiere = ""
    public var formation = ""
    public var anneeUniv = ""
    public var session = ""
    public var enseignant = ""
    public var deposePar = ""
    public var typeDocument = ""      // cours, td, tp, examen (vide = examen par défaut pour une annale)

    public init() {}

    func value(_ field: String) -> String? {
        let v: String
        switch field {
        case "etablissement": v = etablissement
        case "niveau": v = niveau
        case "matiere": v = matiere
        case "formation": v = formation
        case "annee_univ": v = anneeUniv
        case "session": v = session
        default: v = ""
        }
        let t = v.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

/// Phase 2 — Identification. Port fidèle de annalyse/metadata.py.
public struct AnnaleMetadata: Codable {
    public var matiere: String?
    public var anneeUniv: String?           // "2024-2025"
    public var niveau: String?              // L1 … M2
    public var etablissement: String?       // clé de etablissements.yaml
    public var formation: String?
    public var sessions: [String] = []      // ["CC1", "CC2"] si plusieurs sujets
    public var raisonsDoute: [String] = []
    public var sources: [String: String] = [:]

    public var session: String? { sessions.isEmpty ? nil : sessions.joined(separator: "+") }
    public var nbSujets: Int { max(1, sessions.count) }
    public var complet: Bool {
        niveau != nil && matiere != nil && anneeUniv != nil && !sessions.isEmpty && raisonsDoute.isEmpty
    }
}

public enum AnnalesMetadataDetector {
    static let tailleEnTete = 1500
    static let scoreMinimum = 3
    static let mois: [String: Int] = ["janvier": 1, "fevrier": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6,
                                      "juillet": 7, "aout": 8, "septembre": 9, "octobre": 10, "novembre": 11,
                                      "decembre": 12]
    static let moisOrdre = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout",
                            "septembre", "octobre", "novembre", "decembre"]

    static func entete(_ texte: String) -> String { AnnalesText.normaliser(AnnalesText.debut(texte, tailleEnTete)) }

    // MARK: Niveau

    static let reNiveau: [(Rx, String)] = [
        (Rx(#"\bl([123])\s*-?\s*s[1-6]\b"#), "L"),
        (Rx(#"\bl([123])\b(?=\s*(?:-|–)?\s*(?:informatique|info|maths?|mathematiques|physique|miashs|portail))"#), "L"),
        (Rx(#"\blicences?\s+(?:[a-z\-/]+\s+){0,2}([123])\b"#), "L"),
        (Rx(#"\bmaster\s*([12])\b"#), "M"),
        (Rx(#"\bm([12])\b(?=\s*(?:informatique|info|ilsen|ia|syrius|miashs))"#), "M"),
    ]
    static let reSemestre = Rx(#"\bs([1-6])\b"#)

    public static func niveau(_ texte: String) -> String? {
        for ligne in entete(texte).components(separatedBy: "\n") {
            for (motif, prefixe) in reNiveau {
                if let m = motif.first(ligne), let n = m[1] { return prefixe + n }
            }
            if ligne.contains("licence") || ligne.contains("portail"),
               let m = reSemestre.first(ligne), let s = m[1], let k = Int(s) {
                return "L\((k + 1) / 2)"          // S1-S2 : L1, S3-S4 : L2, S5-S6 : L3
            }
        }
        return nil
    }

    // MARK: Formation

    static let formations: [(Rx, String)] = [
        (Rx(#"info-maths?-physique|maths?-info|math-physique"#), "Info-Maths-Physique"),
        (Rx(#"\bmiashs\b"#), "MIASHS"),
        (Rx(#"\bilsen\b"#), "Informatique – ILSEN"),
        (Rx(#"\bsyrius\b"#), "Informatique – SYRIUS"),
        (Rx(#"\b(?:master|m)\s*[12]?\s*(?:informatique\s*)?(?:-\s*)?ia\b"#), "Informatique – IA"),
        (Rx(#"licences? (?:de )?mathematiques"#), "Mathématiques"),
        (Rx(#"\binformatique\b"#), "Informatique"),
    ]

    public static func formation(_ texte: String) -> String? {
        let t = entete(texte)
        return formations.first { $0.0.test(t) }?.1
    }

    // MARK: Établissement

    public static func etablissement(_ texte: String, _ config: AnnalesConfig) -> String? {
        let t = entete(texte)
        var trouves: [(Int, String)] = []
        for e in config.etablissements {
            for motif in e.motifs {
                if let m = Rx(#"\b"# + Rx.escape(motif) + #"\b"#).first(t) { trouves.append((m.location, e.key)) }
            }
        }
        return trouves.min { $0.0 < $1.0 }?.1
    }

    // MARK: Matière

    public static func scores(_ texte: String, _ matieres: [MatiereRule]) -> [(MatiereRule, Int)] {
        let t = AnnalesText.normaliser(texte)
        return matieres.map { m in
            let titres = m.titres.reduce(0) { $0 + occurrences($1, in: t) }
            let mots = m.mots.reduce(0) { $0 + occurrences($1, in: t) }
            return (m, 10 * titres + mots)
        }
    }

    /// Nombre d'occurrences sans chevauchement (comme str.count en Python).
    static func occurrences(_ needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    public static func matiere(_ texte: String, _ matieres: [MatiereRule]) -> MatiereRule? {
        guard !matieres.isEmpty else { return nil }
        let s = scores(texte, matieres)
        // max() en Python garde le premier en cas d'égalité
        var best = s[0]
        for item in s.dropFirst() where item.1 > best.1 { best = item }
        return best.1 >= scoreMinimum ? best.0 : nil
    }

    // MARK: Année universitaire

    static let reAnneeUniv = Rx(#"\b(20\d\d)\s*[/\-–]\s*(20\d\d)\b"#)
    static let reDateLettres = Rx(#"\b(\d{1,2})\s+("# + moisOrdre.joined(separator: "|") + #")\s*,?\s+(20\d\d)\b"#)
    static let reDateChiffres = Rx(#"\b(\d{1,2})/(\d{1,2})/(20\d\d)\b"#)

    static func anneeDepuisDate(mois: Int, annee: Int) -> String {
        mois >= 9 ? "\(annee)-\(annee + 1)" : "\(annee - 1)-\(annee)"
    }

    public static func anneeUniv(_ texte: String) -> String? {
        for m in reAnneeUniv.all(AnnalesText.normaliser(texte)) {
            if let a = m[1].flatMap(Int.init), let b = m[2].flatMap(Int.init), b == a + 1 { return "\(a)-\(b)" }
        }
        let t = entete(texte)
        if let m = reDateLettres.first(t), let nom = m[2], let mo = mois[nom], let an = m[3].flatMap(Int.init) {
            return anneeDepuisDate(mois: mo, annee: an)
        }
        if let m = reDateChiffres.first(t), let mo = m[2].flatMap(Int.init), let an = m[3].flatMap(Int.init) {
            return anneeDepuisDate(mois: mo, annee: an)
        }
        return nil
    }

    // MARK: Session

    static let reglesSession: [(Rx, (Rx.Match) -> String)] = [
        (Rx(#"\bcc\s?(\d)\b"#), { "CC" + ($0[1] ?? "") }),
        (Rx(#"\bcontrole (?:continu )?n\s*°?\s*(\d)\b"#), { "CC" + ($0[1] ?? "") }),
        (Rx(#"\b(?:premier|1er|1ere|1re) (?:controle|examen|cc)\b"#), { _ in "CC1" }),
        (Rx(#"\b(?:deuxieme|second|seconde|2nd|2nde|2e|2eme) (?:controle|examen|cc)\b"#), { _ in "CC2" }),
        (Rx(#"\b(?:troisieme|3e|3eme) (?:controle|examen|cc)\b"#), { _ in "CC3" }),
        (Rx(#"\bepreuve de substitution\b"#), { _ in "SUBSTITUTION" }),
        (Rx(#"\brattrapage\b|\bseconde session\b|\bsession 2\b"#), { _ in "RATTRAPAGE" }),
        (Rx(#"\bexamen (?:terminal|final)\b"#), { _ in "EXAM" }),
    ]
    static let reControleSansNumero = Rx(#"\bcontrole (?:des|de) connaissances\b"#)

    /// Toutes les sessions trouvées, dans l'ordre d'apparition, sans doublon.
    public static func sessions(_ texte: String) -> [String] {
        let t = AnnalesText.normaliser(texte)
        var trouvees: [(Int, String)] = []        // (position, session) — trié comme en Python
        for (motif, session) in reglesSession {
            for m in motif.all(t) { trouvees.append((m.location, session(m))) }
        }
        var result: [String] = []
        for (_, s) in trouvees.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) where !result.contains(s) {
            result.append(s)
        }
        if result.isEmpty && reControleSansNumero.test(t) { result = ["CC"] }
        return result
    }

    // MARK: Tout ensemble

    static func combiner(_ champ: String, _ detecte: String?, _ declare: String?, _ meta: inout AnnaleMetadata) -> String? {
        if let d = detecte, let decl = declare {
            if d == decl {
                meta.sources[champ] = "détecté = déclaré"
            } else {
                meta.raisonsDoute.append("\(champ) : déclaré \(decl), lu dans le sujet \(d)")
                meta.sources[champ] = "détecté (en désaccord avec la déclaration)"
            }
            return d
        }
        if let d = detecte { meta.sources[champ] = "détecté"; return d }
        if let decl = declare { meta.sources[champ] = "déclaré"; return decl }
        return nil
    }

    public static func detect(_ texte: String, config: AnnalesConfig, declared: DeclaredInfo = DeclaredInfo()) -> AnnaleMetadata {
        var meta = AnnaleMetadata()

        // 0. établissement : lu, déclaré, ou celui du BDE par défaut
        meta.etablissement = combiner("etablissement", etablissement(texte, config), declared.value("etablissement"), &meta)
        if meta.etablissement == nil, let def = config.defaultEtablissement {
            meta.etablissement = def
            meta.sources["etablissement"] = "par défaut"
        }

        // 1. niveau, puis 2. matière parmi celles de ce niveau
        meta.niveau = combiner("niveau", niveau(texte), declared.value("niveau"), &meta)
        let matiereLue: String?
        if let n = meta.niveau {
            matiereLue = matiere(texte, config.matieres(of: n))?.key
        } else if let m = matiere(texte, config.matieres) {
            matiereLue = m.key
            meta.niveau = m.niveau
            meta.sources["niveau"] = "déduit de la matière"
        } else {
            matiereLue = nil
        }
        meta.matiere = combiner("matiere", matiereLue, declared.value("matiere"), &meta)
        meta.formation = declared.value("formation") ?? formation(texte)
        meta.anneeUniv = combiner("annee_univ", anneeUniv(texte), declared.value("annee_univ"), &meta)

        var lues = sessions(texte)
        let declaree = declared.value("session")
        if lues == ["CC"] && declaree != nil { lues = [] }
        let session = combiner("session", lues.isEmpty ? nil : lues.joined(separator: "+"), declaree, &meta)
        meta.sessions = session.map { $0.components(separatedBy: "+") } ?? []

        if meta.niveau == nil { meta.raisonsDoute.append("niveau inconnu (L1 ? M2 ?)") }
        if meta.matiere == nil { meta.raisonsDoute.append("matière non reconnue") }
        if meta.anneeUniv == nil { meta.raisonsDoute.append("année universitaire introuvable") }
        if meta.sessions.isEmpty {
            meta.raisonsDoute.append("session introuvable")
        } else if meta.sessions == ["CC"] {
            meta.raisonsDoute.append("contrôle sans numéro (CC1 ? CC2 ?)")
        }
        return meta
    }

    // MARK: Affichage

    /// « CC1 » → « Contrôle continu n°1 » (pour l'en-tête LaTeX).
    public static func sessionLatex(_ s: String) -> String {
        if s.hasPrefix("CC"), let n = Int(s.dropFirst(2)) {
            return "Contrôle continu n\\textsuperscript{o}\\,\(n)"
        }
        switch s {
        case "CC": return "Contrôle continu"
        case "EXAM": return "Examen terminal"
        case "RATTRAPAGE": return "Rattrapage"
        case "SUBSTITUTION": return "Épreuve de substitution"
        default: return AnnalesText.latexEscape(s)
        }
    }

    public static func sessionLabel(_ s: String) -> String {
        if s.hasPrefix("CC"), let n = Int(s.dropFirst(2)) { return "Contrôle continu n°\(n)" }
        switch s {
        case "CC": return "Contrôle continu"
        case "EXAM": return "Examen terminal"
        case "RATTRAPAGE": return "Rattrapage"
        case "SUBSTITUTION": return "Épreuve de substitution"
        default: return s
        }
    }
}
