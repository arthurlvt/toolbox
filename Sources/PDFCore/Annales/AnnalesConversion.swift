import Foundation

public enum Verdict: String, Codable, CaseIterable {
    case ok = "OK", doute = "DOUTE", rejet = "REJET"

    public var label: String {
        switch self {
        case .ok: return "Crédible"
        case .doute: return "Doute"
        case .rejet: return "Rejeté"
        }
    }
}

public struct ConversionSettings {
    public var model: String
    public var useImages = true          // si le modèle sait lire les images
    public var numCtx = 16384
    public var temperature = 0.1
    public var repairAttempts = 2
    public var engine: LatexEngine = .pdflatex

    public init(model: String) { self.model = model }
}

public struct ConversionResult {
    public var tex: String
    public var verdict: Verdict
    public var motifs: [String]
    public var compiled: Bool
    public var pdf: URL?
    public var texURL: URL?
    public var log: String
    public var attempts: Int
}

/// Phase 5 — Mise au propre par l'IA, avec le modèle modele_annale.tex comme consignes.
public enum AnnalesConversion {

    // MARK: Prompts

    // Le gabarit de modele_annale.tex contient des valeurs et des exercices d'EXEMPLE.
    // Un petit modèle les recopie au lieu de transcrire l'original : on n'envoie donc que
    // les consignes (commentaires) et un squelette vide.
    static let repereGabarit = "À PARTIR D'ICI"
    static let squelette = #"""

    % ---------------------------------------------------------------------
    %  SQUELETTE À REMPLIR (ne contient volontairement AUCUN exemple)
    % ---------------------------------------------------------------------
    \documentclass[examen]{annales}   % cours | td | tp | examen (+ ,corrige si l'original contient des corrections)
    % Les métadonnées (matière, session, formation, année, enseignant, provenance…) sont
    % ajoutées automatiquement : ne les écris pas. N'écris les lignes suivantes QUE si
    % l'information est lisible sur l'original, avec exactement ce qui y est écrit :
    % \titre{…}  \dateexamen{…}  \duree{…}  \documents{…}  \consignes{…}  \objectif{…}
    \begin{document}
    % Ici : la transcription FIDÈLE et COMPLÈTE de l'original, exercice par exercice,
    % avec les environnements exercice / question / sousquestion / bloc / correction.
    \end{document}
    """#

    /// Consignes du modèle (tout ce qui précède le gabarit) + squelette sans exemple.
    public static func prepareTemplate(_ template: String) -> String {
        guard let r = template.range(of: repereGabarit) else { return template }
        let head = template[..<r.lowerBound]
        let cut = head.range(of: "\n", options: .backwards)?.lowerBound ?? head.startIndex
        return String(template[..<cut]) + "\n" + squelette
    }

    static func systemPrompt(template: String) -> String {
        """
        Tu es l'IA de conversion de la banque d'annales « Annalyse ». Le fichier ci-dessous \
        contient TOUTES tes consignes (en commentaires) puis le gabarit à suivre. Respecte-les \
        à la lettre, en particulier le contrôle de crédibilité (section 10) et la fidélité (section 8).

        Format de ta réponse : UNIQUEMENT le contenu du fichier .tex, sans explication, sans \
        balises Markdown. Les deux premières lignes sont le verdict :
        % VERDICT-CREDIBILITE: OK | DOUTE | REJET
        % MOTIFS: ...
        Puis \\documentclass[...]{annales} et le document complet jusqu'à \\end{document}.
        Ne recopie pas les commentaires de consignes.
        Transcris UNIQUEMENT ce qui est écrit dans le document fourni : n'invente aucun exercice, \
        aucune date, aucune durée, aucune consigne. Si un passage est illisible, utilise \\illisible.

        ===== DÉBUT DU FICHIER modele_annale.tex =====
        \(prepareTemplate(template))
        ===== FIN DU FICHIER modele_annale.tex =====
        """
    }

    static func userPrompt(metadata: [String: String], texte: String, withImages: Bool) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        Métadonnées du formulaire de dépôt (JSON) :
        \(json)

        \(withImages ? "Les images jointes sont les pages de l'original : elles font foi. Le texte ci-dessous vient de l'OCR et peut contenir des erreurs (formules surtout)." : "Texte de l'original (extrait automatiquement, peut contenir des erreurs d'OCR) :")

        ===== DÉBUT DU DOCUMENT =====
        \(texte)
        ===== FIN DU DOCUMENT =====

        Rends maintenant le fichier .tex complet.
        """
    }

    static func repairPrompt(tex: String, errors: [String], truncated: Bool) -> String {
        let problem = truncated
            ? "Le fichier est incomplet (il manque la fin, \\end{document})."
            : "La compilation avec pdflatex échoue :\n" + errors.prefix(12).joined(separator: "\n")
        return """
        \(problem)

        Corrige UNIQUEMENT ce qui pose problème, sans changer le contenu de l'énoncé, \
        et rends le fichier .tex COMPLET corrigé (verdict compris), sans aucune explication.

        ===== FICHIER À CORRIGER =====
        \(tex)
        """
    }

    // MARK: Lecture de la réponse

    /// Retire les balises ```latex éventuelles et le bavardage autour du fichier.
    public static func extractTeX(_ response: String) -> String {
        var t = response
        if let fence = Rx(#"```(?:latex|tex)?\s*\n([\s\S]*?)```"#).first(t), let inner = fence[1] {
            t = inner
        } else if t.hasPrefix("```") {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        }
        // Garder à partir du verdict (ou de \documentclass)
        let ns = t as NSString
        var start = ns.range(of: "% VERDICT").location
        if start == NSNotFound { start = ns.range(of: "%VERDICT").location }
        if start == NSNotFound { start = ns.range(of: "\\documentclass").location }
        if start != NSNotFound && start > 0 { t = ns.substring(from: start) }
        if let end = t.range(of: "\\end{document}", options: .backwards) {
            t = String(t[..<end.upperBound]) + "\n"
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func parseVerdict(_ tex: String) -> (Verdict, [String]) {
        let head = String(tex.prefix(1500))
        let verdict: Verdict
        if let m = Rx(#"VERDICT-CREDIBILITE\s*:\s*(OK|DOUTE|REJET)"#, .caseInsensitive).first(head),
           let v = m[1]?.uppercased(), let parsed = Verdict(rawValue: v) {
            verdict = parsed
        } else {
            return (.doute, ["verdict de crédibilité absent de la réponse de l'IA"])
        }
        var motifs: [String] = []
        if let m = Rx(#"MOTIFS\s*:\s*(.*)"#, .caseInsensitive).first(head), let line = m[1] {
            motifs = line.components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.lowercased() != "aucun" }
        }
        return (verdict, motifs)
    }

    // MARK: Contrôle de fidélité

    // L'IA peut se tromper en étant sûre d'elle (verdict « OK » sur un texte inventé) :
    // on vérifie nous-mêmes que la transcription ressemble à l'original.
    static let seuilPrecision = 0.5   // part des mots transcrits présents dans l'original
    static let seuilRappel = 0.4      // part des mots de l'original retrouvés dans la transcription
    static let reCommande = Rx(#"\\[a-zA-Z@]+\*?"#)
    static let reCommentaire = Rx(#"(?<!\\)%[^\n]*"#)
    static let reMot4 = Rx("[a-z]{4,}")

    /// Texte d'un .tex sans commandes ni commentaires (corps + valeurs du préambule).
    public static func texteDeTex(_ tex: String) -> String {
        var t = Rx(#"\\documentclass(\[[^\]]*\])?\{[^}]*\}"#).replace(tex, with: " ")
        t = reCommentaire.replace(t, with: " ")
        t = Rx(#"\\begin\{lstlisting\}(\[[^\]]*\])?"#).replace(t, with: " ")
        t = reCommande.replace(t, with: " ")
        return Rx(#"[{}$\\&_^\[\]]"#).replace(t, with: " ")
    }

    static func mots(_ texte: String) -> Set<String> {
        Set(reMot4.all(AnnalesText.normaliser(texte)).compactMap { $0[0] })
    }

    /// Motifs de doute si la transcription ne correspond pas à l'original (vide = rien à signaler).
    public static func controleFidelite(_ tex: String, source: String, template: String = "",
                                        metadonnees: String = "") -> [String] {
        var motifs: [String] = []
        let produits = mots(texteDeTex(tex)).union(mots(metadonnees))
        let originaux = mots(source)
        if !produits.isEmpty && !originaux.isEmpty {
            let communs = Double(produits.intersection(originaux).count)
            let precision = communs / Double(produits.count)
            let rappel = communs / Double(originaux.count)
            if precision < seuilPrecision {
                motifs.append("seulement \(Int(precision * 100)) % du texte transcrit se retrouve dans l'original (contenu inventé ?)")
            }
            if rappel < seuilRappel {
                motifs.append("seulement \(Int(rappel * 100)) % de l'original se retrouve dans la transcription (passages manquants ?)")
            }
        }
        if !template.isEmpty, let g = template.range(of: repereGabarit),
           let body = template.range(of: "\\begin{document}", range: g.upperBound..<template.endIndex) {
            let exemples = Similarity.shingles(texteDeTex(String(template[body.lowerBound...])))
            let copies = exemples.intersection(Similarity.shingles(texteDeTex(tex))).subtracting(Similarity.shingles(source))
            if copies.count >= 8 { motifs.append("la transcription contient les exercices d'exemple du gabarit") }
        }
        return motifs
    }

    static let infosAVerifier = ["titre", "dateexamen", "duree", "documents", "consignes", "objectif"]

    /// Supprime \\dateexamen, \\duree… dont le contenu n'apparaît pas dans l'original.
    public static func retirerInfosInventees(_ tex: String, source: String) -> String {
        guard let begin = tex.range(of: "\\begin{document}") else { return tex }
        let originaux = mots(source)
        let compactSource = AnnalesText.normaliser(source).filter { !$0.isWhitespace }
        let chiffresSource = Set(Rx(#"\d+"#).all(source).compactMap { $0[0] })
        let ligne = Rx(#"^[ \t]*\\("# + infosAVerifier.joined(separator: "|") + #")\{(.*)\}[ \t]*(%.*)?$"#)
        var lignes = String(tex[..<begin.lowerBound]).components(separatedBy: "\n")
        lignes = lignes.filter { l in
            guard let m = ligne.first(l), let cmd = m[1], let valeur = m[2] else { return true }
            let sansCommandes = reCommande.replace(valeur, with: " ")
            if cmd == "dateexamen" || cmd == "duree" {
                let compact = AnnalesText.normaliser(sansCommandes).filter { !$0.isWhitespace }
                return !compact.isEmpty && compactSource.contains(compact)
            }
            let nombres = Set(Rx(#"\d+"#).all(valeur).compactMap { $0[0] })
            if !nombres.isEmpty && !nombres.isSubset(of: chiffresSource) { return false }
            let lus = mots(sansCommandes)
            if !lus.isEmpty && Double(lus.intersection(originaux).count) / Double(lus.count) < 0.5 { return false }
            return true
        }
        return lignes.joined(separator: "\n") + String(tex[begin.lowerBound...])
    }

    // MARK: Nettoyage et métadonnées

    static let validTypes = ["cours", "td", "tp", "examen"]

    // MARK: Habitudes Markdown d'un petit modèle, corrigées avant compilation

    static let envTitres = ["exercice", "exercicebonus"]     // {Titre} -> [barème][Titre]
    static let envTexte = ["question", "sousquestion"]       // {texte} -> texte dans le corps
    static let unicodeLatex: [(String, String)] = [
        ("→", "$\\to$"), ("←", "$\\leftarrow$"), ("⇒", "$\\Rightarrow$"), ("⇔", "$\\Leftrightarrow$"),
        ("≤", "$\\leqslant$"), ("≥", "$\\geqslant$"), ("≠", "$\\neq$"), ("×", "$\\times$"),
        ("∈", "$\\in$"), ("∞", "$\\infty$"), ("≈", "$\\approx$"), ("−", "-"),
        ("“", "``"), ("”", "''"), ("’", "'"),
    ]

    /// Position (UTF-16) de l'accolade qui ferme celle ouverte en `i`.
    static func closingBrace(_ u: [UInt16], _ i: Int) -> Int? {
        let open: UInt16 = 123, close: UInt16 = 125, backslash: UInt16 = 92
        var depth = 0
        for j in i..<u.count {
            let prev: UInt16 = j > 0 ? u[j - 1] : 0
            if u[j] == open && prev != backslash {
                depth += 1
            } else if u[j] == close && prev != backslash {
                depth -= 1
                if depth == 0 { return j }
            }
        }
        return nil
    }

    /// \begin{exercice}[5 points]{Titre} -> \begin{exercice}[5 points][Titre] ;
    /// \begin{question}[2 points]{Texte} -> \begin{question}[2 points] puis Texte dans le corps.
    public static func corrigerArguments(_ tex: String) -> String {
        let rx = Rx(#"\\begin\{("# + (envTitres + envTexte).joined(separator: "|") + #")\}((?:\[[^\]]*\])*)[ \t]*\{"#)
        let ns = tex as NSString
        let units = Array(tex.utf16)
        var out = ""
        var pos = 0
        for m in rx.all(tex) {
            guard m.location >= pos, let whole = m[0] else { continue }
            let openIdx = m.location + (whole as NSString).length - 1
            guard let close = closingBrace(units, openIdx) else { continue }
            let env = m[1] ?? ""
            let options = m[2] ?? ""
            let contenu = ns.substring(with: NSRange(location: openIdx + 1, length: close - openIdx - 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out += ns.substring(with: NSRange(location: pos, length: m.location - pos))
            if envTitres.contains(env) && options.filter({ $0 == "[" }).count <= 1 && !contenu.contains("\n") {
                out += "\\begin{\(env)}\(options.isEmpty ? "[]" : options)[\(contenu)]"
            } else {
                out += "\\begin{\(env)}\(options)\n\(contenu)"
            }
            pos = close + 1
        }
        return out + ns.substring(from: pos)
    }

    static func echapperCode(_ code: String) -> String {
        var out = ""
        for c in code {
            switch c {
            case "_", "&", "%", "#", "$", "{", "}": out += "\\\(c)"
            default: out.append(c)
            }
        }
        return out
    }

    static func replaceMatches(_ s: String, _ rx: Rx, _ f: (Rx.Match) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var pos = 0
        for m in rx.all(s) {
            guard let whole = m[0] else { continue }
            out += ns.substring(with: NSRange(location: pos, length: m.location - pos)) + f(m)
            pos = m.location + (whole as NSString).length
        }
        return out + ns.substring(from: pos)
    }

    /// Échappe _ et # hors du mode mathématique (les blocs de code sont laissés intacts).
    static func escapeSegment(_ s: String) -> String {
        let c = Array(s)
        var out = ""
        var inMath = false
        var i = 0
        while i < c.count {
            let ch = c[i]
            let prev: Character = i > 0 ? c[i - 1] : " "
            if ch == "\\", i + 1 < c.count, "[]()".contains(c[i + 1]) {
                inMath = "[(".contains(c[i + 1])
                out.append(ch)
                out.append(c[i + 1])
                i += 2
                continue
            }
            if ch == "\\", i + 1 < c.count, !c[i + 1].isLetter {
                // \\ (saut de ligne), \$, \_, \# … : symbole de contrôle, recopié tel quel
                out.append(ch)
                out.append(c[i + 1])
                i += 2
                continue
            }
            if ch == "$" && prev != "\\" {
                inMath.toggle()
            } else if (ch == "_" || ch == "#") && prev != "\\" && !inMath {
                out.append("\\")
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    public static func echapperHorsMaths(_ tex: String) -> String {
        guard let r = tex.range(of: "\\begin{document}") else { return tex }
        let head = String(tex[..<r.lowerBound])
        let body = String(tex[r.lowerBound...])
        let ns = body as NSString
        let blocks = Rx(#"(?s)\\begin\{(?:lstlisting|verbatim)\}.*?\\end\{(?:lstlisting|verbatim)\}"#
                        + #"|\\(?:label|ref|eqref|url|href|input|include|includegraphics|cite)(?:\[[^\]]*\])?\{[^}]*\}"#).all(body)
        var out = ""
        var pos = 0
        for b in blocks {
            guard let whole = b[0] else { continue }
            let len = (whole as NSString).length
            out += escapeSegment(ns.substring(with: NSRange(location: pos, length: b.location - pos)))
            out += ns.substring(with: NSRange(location: b.location, length: len))
            pos = b.location + len
        }
        out += escapeSegment(ns.substring(from: pos))
        return head + out
    }

    /// `code`, **gras**, caractères Unicode inconnus de pdflatex, _ non échappés…
    public static func corrigerMarkdown(_ input: String) -> String {
        let tex = corrigerArguments(input)
        let start = tex.range(of: "\\begin{document}")?.lowerBound ?? tex.startIndex
        let head = String(tex[..<start])
        var corps = String(tex[start...])
        corps = Rx(#"(?s)```[a-zA-Z]*\n(.*?)```"#).replace(corps, with: "\\\\begin{lstlisting}\n$1\\\\end{lstlisting}")
        corps = replaceMatches(corps, Rx("`([^`\\n]+)`")) { m in "\\code{" + echapperCode(m[1] ?? "") + "}" }
        corps = Rx(#"\*\*([^*\n]+)\*\*"#).replace(corps, with: "\\\\textbf{$1}")
        for (u, l) in unicodeLatex { corps = corps.replacingOccurrences(of: u, with: l) }
        return echapperHorsMaths(head + corps)
    }

    /// Retire les commandes interdites par le modèle (section 9) et remet la bonne classe.
    public static func sanitize(_ input: String, defaultType: String) -> String {
        var t = input
        let rules: [(String, String, NSRegularExpression.Options)] = [
            (#"(?m)^[ \t]*\\usepackage(\[[^\]]*\])?\{[^}]*\}[^\n]*\n?"#, "", []),
            (#"\\(newpage|clearpage|pagebreak|vfill|maketitle|tableofcontents)\b(\[[^\]]*\])?"#, "", []),
            (#"\\vspace\*?\{[^}]*\}"#, "", []),
            (#"\\color\{[^}]*\}"#, "", []),
            (#"\\textcolor\{[^}]*\}"#, "", []),
            (#"\$\$([\s\S]+?)\$\$"#, "\\\\[$1\\\\]", []),
        ]
        for (pattern, template, options) in rules {
            t = Rx(pattern, options).replace(t, with: template)
        }
        t = corrigerMarkdown(t)
        // Classe : toujours « annales », avec une option de type valide.
        let docclass = Rx(#"\\documentclass(\[([^\]]*)\])?\{([^}]*)\}"#)
        if let m = docclass.first(t) {
            let options = (m[2] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var type = options.first { validTypes.contains($0) } ?? defaultType
            if !validTypes.contains(type) { type = "examen" }
            var opts = [type]
            if options.contains("corrige") { opts.append("corrige") }
            if options.contains("exercices-entiers") { opts.append("exercices-entiers") }
            let replacement = "\\\\documentclass[" + opts.joined(separator: ",") + "]{annales}"
            t = docclass.re.stringByReplacingMatches(in: t, range: NSRange(location: m.location, length: (m[0]! as NSString).length),
                                                     withTemplate: replacement)
        } else {
            t = "\\documentclass[\(defaultType)]{annales}\n" + t
        }
        return t
    }

    static let managed = ["matiere", "session", "formation", "universite", "anneeuniv", "enseignant",
                          "original", "empreinte", "deposepar", "datedepot", "identifiant",
                          "verification", "diffusion", "relecture"]

    /// Remplace les métadonnées du préambule par les nôtres (détectées / déclarées) :
    /// elles font autorité sur ce que l'IA a pu écrire. Les champs vides sont omis
    /// (la classe affiche alors « non renseigné »).
    public static func injectMetadata(_ tex: String, fields: [(String, String)]) -> String {
        guard let beginDoc = tex.range(of: "\\begin{document}") else { return tex }
        var preamble = String(tex[..<beginDoc.lowerBound])
        let body = String(tex[beginDoc.lowerBound...])
        let names = fields.map { $0.0 }
        let remove = Rx(#"(?m)^[ \t]*\\("# + names.joined(separator: "|") + #")\{.*\}[ \t]*(%.*)?\n?"#)
        preamble = remove.replace(preamble, with: "")
        preamble = Rx(#"(?m)^% -+ Métadonnées \(remplies par [^)]*\) -+\n"#).replace(preamble, with: "")
        let block = "% ---------- Métadonnées (remplies par Toolbox) ----------\n"
            + fields.filter { !$0.1.isEmpty }.map { "\\\($0.0){\($0.1)}" }.joined(separator: "\n") + "\n"
        if let dc = Rx(#"\\documentclass[^\n]*\n"#).first(preamble), let line = dc[0] {
            let ns = preamble as NSString
            let insertAt = dc.location + (line as NSString).length
            preamble = ns.substring(to: insertAt) + block + ns.substring(from: insertAt)
        } else {
            preamble = block + preamble
        }
        return preamble + body
    }

    /// Ajoute \titre{…} si l'IA n'en a pas mis.
    static func ensureTitle(_ tex: String, title: String) -> String {
        guard !title.isEmpty, !tex.contains("\\titre{"),
              let dc = Rx(#"\\documentclass[^\n]*\n"#).first(tex), let line = dc[0] else { return tex }
        let ns = tex as NSString
        let at = dc.location + (line as NSString).length
        return ns.substring(to: at) + "\\titre{\(title)}\n" + ns.substring(from: at)
    }

    // MARK: Conversion complète

    /// Conversion + compilation, avec jusqu'à `repairAttempts` aller-retours pour corriger les erreurs.
    public static func convert(client: OllamaClient, settings: ConversionSettings, template: String,
                               metadata: [String: String], texte: String, images: [String],
                               fields: (Verdict, [String]) -> [(String, String)], title: String, defaultType: String,
                               workDir: URL, baseName: String, latexFolder: URL,
                               log: @escaping (String) -> Void) async throws -> ConversionResult {
        let options: [String: Any] = ["temperature": settings.temperature, "num_ctx": settings.numCtx, "num_predict": -1]
        let system = OllamaMessage(role: "system", content: systemPrompt(template: template))
        let user = OllamaMessage(role: "user", content: userPrompt(metadata: metadata, texte: texte, withImages: !images.isEmpty),
                                 images: images)

        log("IA : retranscription en cours avec \(settings.model)…")
        var tokens = 0
        let raw = try await client.chat(model: settings.model, messages: [system, user], options: options) { _ in
            tokens += 1
            if tokens % 400 == 0 { log("IA : \(tokens) morceaux reçus…") }
        }
        var tex = extractTeX(raw)
        var (verdict, motifs) = parseVerdict(tex)
        log("Crédibilité (selon l'IA) : \(verdict.label)" + (motifs.isEmpty ? "" : " — " + motifs.joined(separator: " ; ")))
        if verdict == .rejet {
            return ConversionResult(tex: tex, verdict: .rejet, motifs: motifs, compiled: false, pdf: nil,
                                    texURL: nil, log: "", attempts: 1)
        }

        // Contrôle de fidélité fait par nous : une relance si l'IA a transcrit autre chose que l'original.
        let texteMeta = metadata.values.joined(separator: " ")
        var ecarts = controleFidelite(tex, source: texte, template: template, metadonnees: texteMeta)
        if !ecarts.isEmpty {
            log("Fidélité douteuse : " + ecarts.joined(separator: " ; ") + " — nouvel essai")
            let relance = OllamaMessage(
                role: "user",
                content: "Ta transcription ne correspond pas au document fourni (" + ecarts.joined(separator: " ; ")
                    + "). Recommence en transcrivant UNIQUEMENT le document ci-dessous, sans aucun exemple du gabarit.\n\n"
                    + userPrompt(metadata: metadata, texte: texte, withImages: !images.isEmpty),
                images: images)
            let nouveau = extractTeX(try await client.chat(model: settings.model, messages: [system, relance], options: options))
            let nouveauxEcarts = controleFidelite(nouveau, source: texte, template: template, metadonnees: texteMeta)
            if nouveau.contains("\\documentclass") && nouveauxEcarts.count <= ecarts.count {
                tex = nouveau
                ecarts = nouveauxEcarts
                (verdict, motifs) = parseVerdict(tex)
            }
        }
        if !ecarts.isEmpty {
            log("Fidélité douteuse : " + ecarts.joined(separator: " ; "))
            motifs += ecarts
            if verdict == .ok { verdict = .doute }
        }
        tex = retirerInfosInventees(tex, source: texte)

        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let texURL = workDir.appendingPathComponent(baseName + ".tex")
        var attempts = 0
        var lastLog = ""
        while true {
            attempts += 1
            tex = ensureTitle(injectMetadata(sanitize(tex, defaultType: defaultType), fields: fields(verdict, motifs)), title: title)
            try tex.write(to: texURL, atomically: true, encoding: .utf8)
            let truncated = !tex.contains("\\end{document}") || !tex.contains("\\begin{document}")
            var errors: [String] = []
            if !truncated {
                log("Compilation (essai \(attempts))…")
                let result = try Latex.compile(texURL, engine: settings.engine, texInputs: [latexFolder])
                lastLog = result.log
                if result.success, FileManager.default.fileExists(atPath: result.pdf.path) {
                    log("Compilation réussie.")
                    return ConversionResult(tex: tex, verdict: verdict, motifs: motifs, compiled: true,
                                            pdf: result.pdf, texURL: texURL, log: lastLog, attempts: attempts)
                }
                errors = errorContext(Latex.parseIssues(result.log).filter { !$0.isWarning }, tex: tex)
                if errors.isEmpty { errors = ["(erreur sans message clair ; fin du journal) " + String(result.log.suffix(800))] }
                log("Erreurs de compilation : \(errors.count)")
            } else {
                log("Le fichier rendu par l'IA est incomplet.")
            }
            guard attempts <= settings.repairAttempts else { break }
            log("IA : correction des erreurs (\(attempts)/\(settings.repairAttempts))…")
            let repair = OllamaMessage(role: "user", content: repairPrompt(tex: tex, errors: errors, truncated: truncated))
            let fixed = try await client.chat(model: settings.model, messages: [system, repair], options: options)
            let candidate = extractTeX(fixed)
            if candidate.contains("\\documentclass") {
                tex = candidate
                // Verdict absent de la 1re réponse mais présent dans la réparation : on le relit.
                let absent = motifs.contains { $0.contains("verdict de crédibilité absent") }
                if absent && tex.prefix(1500).contains("VERDICT-CREDIBILITE") {
                    let (v, m) = parseVerdict(tex)
                    motifs = motifs.filter { !$0.contains("verdict de crédibilité absent") } + m
                    verdict = (v == .ok && !ecarts.isEmpty) ? .doute : v
                }
            }
        }
        return ConversionResult(tex: tex, verdict: verdict, motifs: motifs, compiled: false, pdf: nil,
                                texURL: texURL, log: lastLog, attempts: attempts)
    }

    /// « main.tex:42: Undefined control sequence » + la ligne fautive, pour aider le modèle.
    static func errorContext(_ issues: [LatexIssue], tex: String) -> [String] {
        let lines = tex.components(separatedBy: "\n")
        return issues.prefix(10).map { issue in
            var s = "ligne \(issue.line.map(String.init) ?? "?") : \(issue.message)"
            if let n = issue.line, n >= 1, n <= lines.count {
                s += "\n    → " + lines[n - 1].trimmingCharacters(in: .whitespaces)
            }
            return s
        }
    }
}
