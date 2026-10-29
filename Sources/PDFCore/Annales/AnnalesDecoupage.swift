import Foundation
import PDFKit

/// Phase 4 — Découpage d'un fichier en blocs de pages (sujets, corrigés, copies,
/// variantes), puis de chaque sujet en exercices. Port fidèle de annalyse/decoupage.py
/// et annalyse/doubles.py.

public struct Exercice: Codable {
    public var numero: String          // "1", "2"… ou "bonus"
    public var texte: String
}

public enum BlocRole: String, Codable {
    case sujet, corrige = "corrigé", copie, variante
}

public struct Bloc: Codable {
    public var premierePage: Int       // à partir de 1
    public var dernierePage: Int
    public var texte: String
    public var role: BlocRole = .sujet
    public var manuscrit = false
    public var session: String?
    public var version: String?
    public var formatNumerotation: String?
    public var exercices: [Exercice] = []

    public var pagesLabel: String {
        premierePage == dernierePage ? "p.\(premierePage)" : "p.\(premierePage)-\(dernierePage)"
    }
    public var pageRange: ClosedRange<Int> { premierePage...dernierePage }

    /// « CC1 », « CC1_corrige », « CC1_variante_B », « CC2_corrige_manuscrit »…
    public var nom: String {
        let roles: [BlocRole: String] = [.sujet: "", .corrige: "corrige", .copie: "copie", .variante: "variante"]
        var morceaux = [session ?? "sujet", roles[role] ?? ""]
        if manuscrit { morceaux.append("manuscrit") }
        if let v = version { morceaux.append(v) }
        return morceaux.filter { !$0.isEmpty }.joined(separator: "_")
    }
}

// MARK: - Similarité (doubles.py)

public enum Similarity {
    public static let tailleShingle = 3
    public static let seuilDoublon = 0.7       // Jaccard >= 0.7 : même sujet complet
    public static let seuilInclusion = 0.8     // l'un est contenu dans l'autre
    static let reMot = Rx("[a-z0-9]+")

    public static func shingles(_ texte: String, k: Int = tailleShingle) -> Set<String> {
        let mots = reMot.all(AnnalesText.normaliser(texte)).compactMap { $0[0] }
        guard mots.count >= k else { return [] }
        var result = Set<String>()
        for i in 0...(mots.count - k) { result.insert(mots[i..<(i + k)].joined(separator: " ")) }
        return result
    }

    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    public static func inclusion(_ a: Set<String>, _ b: Set<String>) -> Double {
        let smaller = min(a.count, b.count)
        return smaller == 0 ? 0 : Double(a.intersection(b).count) / Double(smaller)
    }
}

// MARK: - Découpage

public enum AnnalesDecoupage {
    static let lignesEnTete = 10
    static let reEnTeteComplet = Rx(#"\b(?:duree|documents?|calculatrices?|lisez)\b|^nom\s*:"#, .anchorsMatchLines)
    static let reCorrige = Rx(#"^[ \t]*(?:corrections?|corriges?|redaction possible|elements de (?:correction|reponse))\b"#, .anchorsMatchLines)
    static let reVersion = Rx(#"\b(?:version|sujet)\s+([a-d])\b"#)
    static let romains: [String: Int] = ["i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10]

    static let pasBareme = #"(?![ \t]*[:\-–][ \t]*\d+(?:[,.]\d+)?[ \t]*(?:pts?|points?)\b[ \t.]*$)"#
    static let ml: NSRegularExpression.Options = [.anchorsMatchLines]
    static let mli: NSRegularExpression.Options = [.anchorsMatchLines, .caseInsensitive]

    /// Formats de numérotation, du plus sûr au moins sûr (le groupe 1 capture le numéro).
    static let formats: [(nom: String, motif: Rx, explicite: Bool)] = [
        ("Exercice n", Rx(#"^[ \t]*exercice\s*(\d+)"# + pasBareme, mli), true),
        ("Question n", Rx(#"^[ \t]*question\s*(\d+)"# + pasBareme, mli), true),
        ("I) II) III)", Rx(#"^[ \t]*(I{1,3}|IV|VI{0,3}|IX|X)(?:[ \t ]*[).:\-–](?![ \t ]*\d)|[ \t]+(?=[A-ZÀ-Ý]))"#, ml), false),
        ("n puis titre", Rx(#"^[ \t]*(\d+)[ \t]*\n[ \t]*[A-ZÀ-Ý](?:[a-zà-ÿ'’]{3,}|[a-zà-ÿ'’]*[ \t]+[a-zà-ÿA-ZÀ-Ý])"#, ml), false),
        ("n. Titre", Rx(#"^[ \t]*(\d+)\.[ \t]+[A-ZÀ-Ý][a-zà-ÿ]+"#, ml), false),
        ("1a- 1-b", Rx(#"^[ \t]*(\d+)(?:[a-z][ \t]*-|[ \t]*-[ \t]*[a-z]\b)"#, ml), false),
    ]
    static let reBonus = Rx(#"^[ \t]*exercice\s+bonus"#, mli)

    // MARK: Exercices

    static func numero(_ valeur: String) -> Int? {
        let v = valeur.lowercased()
        return romains[v] ?? Int(v)
    }

    /// Les numéros apparaissent pour la première fois dans l'ordre 1, 2, 3… (ou k, k+1… si
    /// departLibre) et ne repartent jamais au début.
    static func suiteValide(_ numeros: [Int], departLibre: Bool) -> Bool {
        var premiers: [Int] = []
        for n in numeros where !premiers.contains(n) { premiers.append(n) }
        let depart = (departLibre && !premiers.isEmpty) ? premiers[0] : 1
        guard premiers == Array(depart..<(depart + premiers.count)) else { return false }
        var plusLoin = false
        for n in numeros {
            if n == depart && plusLoin { return false }
            plusLoin = plusLoin || n > depart
        }
        return true
    }

    public static func decouperExercices(_ texte: String) -> (String?, [Exercice]) {
        let ns = texte as NSString
        for format in formats {
            let trouves: [(Int, Int)] = format.motif.all(texte).compactMap { m in
                guard let g = m[1], let n = numero(g) else { return nil }
                return (m.location, n)
            }
            let numeros = trouves.map { $0.1 }
            var minimum = format.explicite ? 1 : 2
            if let first = numeros.first, first != 1 { minimum = 2 }
            if Set(numeros).count < minimum || !suiteValide(numeros, departLibre: format.explicite) { continue }

            var debuts: [(Int, String)] = []
            var vus = Set<Int>()
            for (position, n) in trouves where !vus.contains(n) {
                debuts.append((position, String(n)))
                vus.insert(n)
            }
            if let bonus = reBonus.first(texte), let last = debuts.last, bonus.location > last.0 {
                debuts.append((bonus.location, "bonus"))
            }
            var exercices: [Exercice] = []
            for (k, (position, n)) in debuts.enumerated() {
                let fin = k + 1 < debuts.count ? debuts[k + 1].0 : ns.length
                let morceau = ns.substring(with: NSRange(location: position, length: fin - position))
                exercices.append(Exercice(numero: n, texte: morceau.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return (format.nom, exercices)
        }
        return (nil, [])
    }

    // MARK: Blocs de pages

    static func hautDePage(_ page: String) -> String {
        let lignes = page.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return AnnalesText.normaliser(lignes.prefix(lignesEnTete).joined(separator: "\n"))
    }

    static func premierExercice(_ page: String) -> Int? {
        for format in formats.prefix(2) {
            if let m = format.motif.first(page), let g = m[1] { return Int(g) }
        }
        return nil
    }

    static func debutDeBloc(_ page: String, _ precedente: String, _ sessionCourante: String?) -> Bool {
        let haut = hautDePage(page)
        let s = AnnalesMetadataDetector.sessions(haut)
        if let first = s.first, first != sessionCourante || reEnTeteComplet.test(haut) || reCorrige.test(haut) {
            return true
        }
        return premierExercice(page) == 1 && (premierExercice(precedente) ?? 0) > 1
    }

    static let seuilPageNative = 150

    /// Pages scannées d'un PDF par ailleurs textuel, sans en-tête de sujet :
    /// corrigés ou annotations à la main (indices à partir de 0).
    static func pagesManuscrites(_ pdf: URL?, _ pages: [String]) -> Set<Int> {
        guard let pdf = pdf, pdf.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: pdf) else { return [] }
        var natives: [Bool] = []
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { natives.append(false); continue }
            let taille = (p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
            natives.append(taille >= seuilPageNative
                           || (taille >= AnnalesExtractor.seuilPageScannee && !AnnalesExtractor.pageHasImages(p)))
        }
        guard natives.contains(true), natives.count == pages.count else { return [] }
        var manuscrites = Set<Int>()
        var sujetScanneAvant = false
        for (i, native) in natives.enumerated() {
            if native { sujetScanneAvant = false; continue }
            let haut = hautDePage(pages[i])
            let enTeteFort = !AnnalesMetadataDetector.sessions(haut).isEmpty && reEnTeteComplet.test(haut)
            if enTeteFort && !reCorrige.test(haut) {
                sujetScanneAvant = true
            } else if !sujetScanneAvant {
                manuscrites.insert(i)
            }
        }
        return manuscrites
    }

    static func decouperEnBlocs(_ pages: [String], _ manuscrites: Set<Int>) -> [Bloc] {
        var blocs: [Bloc] = []
        var debut = 0
        var sessionCourante: String?
        guard !pages.isEmpty else { return [] }
        for i in 1...pages.count {
            let s = AnnalesMetadataDetector.sessions(hautDePage(pages[i - 1]))
            if let first = s.first, !manuscrites.contains(i - 1) { sessionCourante = first }
            let fin = i == pages.count
                || (manuscrites.contains(i) != manuscrites.contains(i - 1))
                || (!manuscrites.contains(i) && debutDeBloc(pages[i], pages[i - 1], sessionCourante))
            if fin {
                var bloc = Bloc(premierePage: debut + 1, dernierePage: i,
                                texte: pages[debut..<i].joined(separator: "\n"))
                bloc.manuscrit = manuscrites.contains(debut)
                blocs.append(bloc)
                debut = i
            }
        }
        return blocs
    }

    static let seuilCopie = 0.95
    static let seuilVariante = 0.5

    static func qualifier(_ input: [Bloc]) -> [Bloc] {
        var blocs = input
        var sujets: [Bloc] = []
        var sessionCourante: String?
        for k in blocs.indices {
            if blocs[k].manuscrit {
                blocs[k].role = .corrige
                blocs[k].session = sessionCourante
                continue
            }
            let haut = hautDePage(blocs[k].texte)
            let s = AnnalesMetadataDetector.sessions(haut)
            if let first = s.first { sessionCourante = first }
            blocs[k].session = sessionCourante
            blocs[k].version = reVersion.first(haut)?[1]?.uppercased()

            let a = Similarity.shingles(blocs[k].texte)
            var proche: Bloc?
            var meilleure = -1.0
            for sujet in sujets {
                let inc = Similarity.inclusion(a, Similarity.shingles(sujet.texte))
                if inc > meilleure { meilleure = inc; proche = sujet }
            }
            let b = proche.map { Similarity.shingles($0.texte) } ?? []
            if !s.isEmpty && reCorrige.test(haut) {
                blocs[k].role = .corrige
            } else if proche != nil && Similarity.jaccard(a, b) >= seuilCopie {
                blocs[k].role = .copie
            } else if let p = proche, Similarity.jaccard(a, b) >= seuilVariante && blocs[k].session == p.session {
                blocs[k].role = .variante
            } else if proche != nil && Similarity.inclusion(a, b) >= 0.7 && a.count > b.count {
                blocs[k].role = .corrige
            } else {
                blocs[k].role = .sujet
            }
            if blocs[k].role == .sujet || blocs[k].role == .variante {
                let (format, exercices) = decouperExercices(blocs[k].texte)
                blocs[k].formatNumerotation = format
                blocs[k].exercices = exercices
            }
            if blocs[k].role == .sujet { sujets.append(blocs[k]) }
        }
        return fusionner(blocs)
    }

    /// Recolle les morceaux consécutifs d'un même corrigé (ou d'une même copie).
    static func fusionner(_ blocs: [Bloc]) -> [Bloc] {
        var result: [Bloc] = []
        for bloc in blocs {
            if let prev = result.last, bloc.role == prev.role, bloc.role == .corrige || bloc.role == .copie,
               bloc.session == prev.session, bloc.version == nil || bloc.version == prev.version {
                result[result.count - 1].dernierePage = bloc.dernierePage
                result[result.count - 1].texte += "\n" + bloc.texte
            } else {
                result.append(bloc)
            }
        }
        return result
    }

    /// pdf (facultatif) : le PDF d'origine, pour repérer les pages manuscrites.
    public static func decouper(_ extraction: TextExtraction, pdf: URL?) -> [Bloc] {
        let pages = extraction.pages.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\n")) }
        return qualifier(decouperEnBlocs(pages, pagesManuscrites(pdf, pages)))
    }
}

// MARK: - Tags par mots-clés (tagging.py)

public enum AnnalesTagging {
    static let scoreTag = 2
    static let maxTags = 3
    private static var cache: [String: Rx] = [:]
    private static let lock = NSLock()

    /// Le mot ENTIER (+ pluriel) : « sin » ne compte pas dans « dessin », « suite » compte dans « suites ».
    static func motif(_ mot: String) -> Rx {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[mot] { return r }
        let alnum: (Character?) -> Bool = { c in c.map { $0.isLetter || $0.isNumber } ?? false }
        let debut = alnum(mot.first) ? "(?<![a-z0-9])" : ""
        let fin = alnum(mot.last) ? "(?:s|x)?(?![a-z0-9])" : ""
        let r = Rx(debut + Rx.escape(mot) + fin)
        cache[mot] = r
        return r
    }

    /// Notions d'un exercice, de la plus forte à la plus faible.
    public static func tags(_ texte: String, notions: [NotionRule]) -> [String] {
        guard !notions.isEmpty else { return [] }
        let t = AnnalesText.normaliser(texte)
        let scores = notions.enumerated().map { (i, n) in
            (index: i, name: n.name, score: n.mots.reduce(0) { $0 + motif($1).count(t) })
        }
        let classees = scores.filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        var retenues = classees.filter { $0.score >= scoreTag }.prefix(maxTags).map { $0.name }
        if retenues.isEmpty, let first = classees.first { retenues = [first.name] }
        return retenues
    }
}
