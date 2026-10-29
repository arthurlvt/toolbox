import Foundation
import PDFKit

public struct AnnalesSettings {
    public var annalyseRoot: URL         // dossier Annalyse (config/ et latex/)
    public var bankRoot: URL             // dossier de la banque
    public var conversion: ConversionSettings
    public var aiTagging = true
    public var compressOutput = true
    public var languages = ["fr-FR", "en-US"]

    public init(annalyseRoot: URL, bankRoot: URL, model: String) {
        self.annalyseRoot = annalyseRoot
        self.bankRoot = bankRoot
        self.conversion = ConversionSettings(model: model)
    }
}

public enum SubjectState: String, Codable {
    case range, aVerifier = "a_verifier", rejete, nonConverti = "non_converti", ignore

    public var label: String {
        switch self {
        case .range: return "Rangé"
        case .aVerifier: return "À vérifier"
        case .rejete: return "Rejeté"
        case .nonConverti: return "Original conservé"
        case .ignore: return "Ignoré"
        }
    }
}

/// Fiche JSON écrite à côté de chaque PDF produit (sert à la relecture et à la validation).
public struct SubjectFiche: Codable {
    public var empreinte: String
    public var original: String
    public var pages: String
    public var role: String
    public var session: String?
    public var version: String?
    public var meta: AnnaleMetadata
    public var declared: DeclaredInfo
    public var verdict: Verdict?
    public var motifs: [String]
    public var raisons: [String]
    public var etat: SubjectState
    public var compiled: Bool
    public var tags: [String: [String]]
    public var identifiant: String
    public var dateDepot: String
    public var typeDocument: String
}

public struct SubjectOutput: Identifiable {
    public let id = UUID()
    public var bloc: Bloc
    public var fiche: SubjectFiche
    public var pdf: URL?
    public var tex: URL?
    public var ficheURL: URL?

    public var title: String {
        var t = fiche.session.map(AnnalesMetadataDetector.sessionLabel) ?? "Sujet"
        if bloc.role == .corrige { t += " — corrigé" }
        if bloc.role == .variante { t += " — variante" }
        if let v = bloc.version { t += " \(v)" }
        return t + " (\(bloc.pagesLabel))"
    }
}

public struct DepositOutcome {
    public enum State { case identique, doublon, traite }
    public var state: State
    public var message: String
    public var meta: AnnaleMetadata?
    public var extraction: TextExtraction?
    public var blocs: [Bloc] = []
    public var subjects: [SubjectOutput] = []
}

/// Toute la chaîne d'Annalyse pour un dépôt : lecture → identification → doublons →
/// découpage → mise au propre par l'IA → compilation → tags → rangement + base.
public final class AnnalesPipeline {
    public let config: AnnalesConfig
    public let bank: AnnalesBank
    public var settings: AnnalesSettings
    public let client: OllamaClient

    public init(settings: AnnalesSettings, client: OllamaClient = OllamaClient()) throws {
        self.settings = settings
        self.config = try AnnalesConfig.load(root: settings.annalyseRoot)
        self.bank = try AnnalesBank(root: settings.bankRoot)
        self.client = client
        guard FileManager.default.fileExists(atPath: config.templateURL.path),
              FileManager.default.fileExists(atPath: config.classURL.path) else {
            throw PDFToolError.toolMissing("latex/modele_annale.tex ou latex/annales.cls introuvable dans \(settings.annalyseRoot.path)")
        }
    }

    static func qualite(_ kind: DepositKind?, _ extraction: TextExtraction) -> Int {
        switch kind {
        case .image: return 0
        case .document: return 3
        default: return extraction.confiance >= 100 ? 2 : 1
        }
    }

    static func originalLabel(_ kind: DepositKind?, _ extraction: TextExtraction) -> String {
        switch kind {
        case .image: return "photo"
        case .document: return "document texte"
        default: return extraction.confiance >= 100 && !extraction.toutesPagesImages ? "PDF officiel" : "scan"
        }
    }

    static func today() -> String {
        let df = DateFormatter()
        df.dateFormat = "dd/MM/yyyy"
        return df.string(from: Date())
    }

    // MARK: Traitement d'un dépôt

    public func process(_ file: URL, declared: DeclaredInfo, log: @escaping (String) -> Void) async throws -> DepositOutcome {
        let fm = FileManager.default
        let sha = try AnnalesText.empreinte(file)
        let short = String(sha.prefix(8))

        // Doublon exact
        if let e = bank.entry(sha), e.etat != "en_cours" {
            return DepositOutcome(state: .identique, message: "Déjà traité (\(e.nom), \(e.etat)) : ignoré.")
        }

        // Copie de l'original (jamais modifié)
        let copy = bank.url("originaux").appendingPathComponent("\(short)_\(file.lastPathComponent)")
        if !fm.fileExists(atPath: copy.path) { try fm.copyItem(at: file, to: copy) }
        let workDir = bank.url(".travail/\(short)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1. Lecture
        log("Lecture de \(file.lastPathComponent)…")
        let kind = DepositKind.of(file)
        let extraction = try AnnalesExtractor.extract(copy, sha: sha, languages: settings.languages)
        log("Texte lu : confiance \(Int(extraction.confiance)) %" +
            (extraction.aVerifier ? " — pages douteuses : \(extraction.pagesDouteuses.map(String.init).joined(separator: ", "))" : ""))
        let pdf = try AnnalesExtractor.workingPDF(for: copy, in: workDir)

        // 2. Identification
        var meta = AnnalesMetadataDetector.detect(extraction.texte, config: config, declared: declared)
        log("Identification : \(meta.etablissement ?? "?") · \(meta.niveau ?? "?") · \(meta.matiere ?? "?") · \(meta.anneeUniv ?? "?") · \(meta.session ?? "?")")
        if !meta.raisonsDoute.isEmpty { log("Doutes : " + meta.raisonsDoute.joined(separator: " ; ")) }
        bank.saveText(sha, extraction.texte)

        var entry = RegistryEntry(original: copy.path, nom: file.lastPathComponent, etat: "en_cours",
                                  qualite: Self.qualite(kind, extraction), confiance: extraction.confiance,
                                  sorties: [], date: Self.today())
        bank.record(sha, entry)

        // 3. Doublons de contenu
        if let similar = bank.mostSimilar(to: extraction.texte, excluding: sha), let old = bank.entry(similar.sha) {
            if similar.jaccard >= Similarity.seuilDoublon {
                let better = (entry.qualite, entry.confiance) > (old.qualite, old.confiance)
                if better {
                    bank.archiveAsDuplicate(similar.sha, replacedBy: sha)
                    log("Meilleure version que « \(old.nom) » : l'ancienne passe dans doublons/.")
                } else {
                    entry.etat = "doublon"
                    bank.record(sha, entry)
                    let msg = "Doublon de « \(old.nom) » (même sujet, version moins bonne) : non converti."
                    log(msg)
                    return DepositOutcome(state: .doublon, message: msg, meta: meta, extraction: extraction)
                }
            } else if similar.inclusion >= Similarity.seuilInclusion {
                meta.raisonsDoute.append("\(Int(similar.inclusion * 100)) % du contenu déjà présent dans « \(old.nom) »")
            }
        }

        // 4. Découpage
        var blocs = AnnalesDecoupage.decouper(extraction, pdf: pdf)
        if blocs.isEmpty {
            blocs = [Bloc(premierePage: 1, dernierePage: max(1, extraction.pages.count), texte: extraction.texte)]
        }
        log("Découpage : " + blocs.map(Self.describe).joined(separator: " · "))

        // 5 à 7. Pour chaque bloc : conversion, compilation, tags, rangement
        let template = try String(contentsOf: config.templateURL, encoding: .utf8)
        var conv = settings.conversion
        if conv.useImages {
            let caps = await client.capabilities(conv.model)
            conv.useImages = caps.contains("vision")
            log(conv.useImages ? "Le modèle lit les images : les pages originales lui sont envoyées."
                               : "Le modèle ne lit pas les images : conversion à partir du texte seul.")
        }
        let nbSujets = blocs.filter { $0.role == .sujet }.count
        var outputs: [SubjectOutput] = []

        for (k, bloc) in blocs.enumerated() {
            if bloc.role == .copie {
                log("\(bloc.pagesLabel) : copie du même sujet, ignorée.")
                continue
            }
            var session = (bloc.session == nil || bloc.session == "CC") ? meta.session : bloc.session
            if nbSujets == 1, let s = meta.session, !s.contains("+") { session = s }
            var named = bloc
            named.session = session
            let baseName = "\(meta.anneeUniv ?? "annee-inconnue")_\(named.nom)"
            let identifiant = Self.identifiant(meta: meta, sha: sha, index: blocs.count > 1 ? k + 1 : nil)
            let typeDocument = declared.typeDocument.isEmpty ? "examen" : declared.typeDocument

            var fiche = SubjectFiche(empreinte: sha, original: copy.path, pages: "\(bloc.premierePage)-\(bloc.dernierePage)",
                                     role: bloc.role.rawValue, session: session, version: bloc.version, meta: meta,
                                     declared: declared, verdict: nil, motifs: [], raisons: meta.raisonsDoute,
                                     etat: .aVerifier, compiled: false, tags: [:], identifiant: identifiant,
                                     dateDepot: Self.today(), typeDocument: typeDocument)
            if extraction.aVerifier { fiche.raisons.append("pages mal lues : \(extraction.pagesDouteuses)") }

            // Corrigé manuscrit : l'OCR le lit mal, on garde les pages originales.
            if bloc.role == .corrige && bloc.manuscrit {
                log("\(bloc.pagesLabel) : corrigé manuscrit, pages originales conservées.")
                fiche.etat = .nonConverti
                let out = try place(original: pdf, pages: bloc.pageRange, fiche: fiche, baseName: baseName + "_original",
                                    tex: nil, compiledPDF: nil)
                outputs.append(out(bloc))
                continue
            }

            // Mise au propre par l'IA
            log("— \(bloc.pagesLabel) (\(bloc.role.rawValue)\(session.map { " " + $0 } ?? "")) —")
            let images = conv.useImages
                ? AnnalesExtractor.pageImagesBase64(pdf: pdf, image: nil, pages: pdf == nil ? nil : bloc.pageRange)
                : []
            let result: ConversionResult
            do {
                result = try await AnnalesConversion.convert(
                    client: client, settings: conv, template: template,
                    metadata: promptMetadata(meta: meta, declared: declared, session: session, bloc: bloc, type: typeDocument),
                    texte: bloc.texte, images: images,
                    fields: { verdict, motifs in
                        self.latexFields(meta: meta, declared: declared, session: session, sha: sha, kind: kind,
                                         extraction: extraction, identifiant: identifiant,
                                         verdict: verdict, motifs: motifs)
                    },
                    title: Self.title(session: session, bloc: bloc, type: typeDocument),
                    defaultType: typeDocument, workDir: workDir, baseName: baseName,
                    latexFolder: config.latexFolder, log: log)
            } catch {
                log("Conversion impossible : \(error.localizedDescription)")
                fiche.raisons.append("conversion IA impossible : \(error.localizedDescription)")
                fiche.etat = .nonConverti
                let out = try place(original: pdf, pages: bloc.pageRange, fiche: fiche, baseName: baseName + "_original",
                                    tex: nil, compiledPDF: nil)
                outputs.append(out(bloc))
                continue
            }
            fiche.verdict = result.verdict
            fiche.motifs = result.motifs
            fiche.compiled = result.compiled

            // Tags par exercice
            let notions = config.notions(niveau: meta.niveau, matiere: meta.matiere)
            var tags: [String: [String]] = [:]
            var tagSource = "mots_cles"
            if !bloc.exercices.isEmpty && !notions.isEmpty {
                if settings.aiTagging, let ai = await aiTags(exercices: bloc.exercices, notions: notions,
                                                            matiere: config.matiere(meta.matiere, niveau: meta.niveau)?.nom ?? "") {
                    tags = ai
                    tagSource = "ia"
                } else {
                    for e in bloc.exercices { tags[e.numero] = AnnalesTagging.tags(e.texte, notions: notions) }
                }
                log("Tags (\(tagSource)) : " + bloc.exercices.map { "ex.\($0.numero) → \((tags[$0.numero] ?? []).joined(separator: ", "))" }.joined(separator: " · "))
            }
            fiche.tags = tags

            // Rangement
            if result.verdict == .rejet {
                fiche.etat = .rejete
                fiche.raisons.append("rejeté par le contrôle de crédibilité : " + result.motifs.joined(separator: " ; "))
            } else if result.compiled && result.verdict == .ok && fiche.raisons.isEmpty && meta.complet {
                fiche.etat = .range
            } else {
                fiche.etat = .aVerifier
                if !result.compiled { fiche.raisons.append("le .tex rendu par l'IA ne compile pas : à corriger à la main") }
                if result.verdict == .doute { fiche.raisons.append("doute de l'IA : " + result.motifs.joined(separator: " ; ")) }
            }
            let out = try place(original: pdf, pages: bloc.pageRange, fiche: fiche, baseName: baseName,
                                tex: result.texURL, compiledPDF: result.pdf, texContent: result.tex)
            let output = out(bloc)
            outputs.append(output)
            log("→ \(output.fiche.etat.label) : \(output.pdf?.lastPathComponent ?? output.tex?.lastPathComponent ?? "")")

            // Base de données
            let exercices = (bloc.role == .sujet || bloc.role == .variante) ? bloc.exercices : []
            try bank.saveSujet(AnnalesBank.SujetRecord(
                empreinte: sha, original: file.lastPathComponent, fichier: output.pdf?.path ?? copy.path,
                pages: fiche.pages, role: bloc.role.rawValue, manuscrit: bloc.manuscrit, meta: meta, session: session,
                version: bloc.version, statut: fiche.etat == .range ? "ia" : (fiche.etat == .rejete ? "rejete" : "en_attente"),
                tex: output.tex?.path, pdf: output.pdf?.path, verdict: result.verdict.rawValue,
                motifs: result.motifs.joined(separator: " ; ")),
                exercices: exercices.map { ($0, tags[$0.numero] ?? [], tagSource) })
        }

        let anyRanged = outputs.contains(where: { $0.fiche.etat == .range })
        let anyToCheck = outputs.contains(where: { $0.fiche.etat == .aVerifier })
        let allRejected = !outputs.isEmpty && outputs.allSatisfy({ $0.fiche.etat == .rejete })
        entry.etat = anyRanged && !anyToCheck ? "range" : (allRejected ? "rejete" : "a_verifier")
        entry.sorties = outputs.compactMap { $0.pdf?.path }
        bank.record(sha, entry)
        return DepositOutcome(state: .traite, message: "\(outputs.count) document(s) produit(s).", meta: meta,
                              extraction: extraction, blocs: blocs, subjects: outputs)
    }

    static func describe(_ b: Bloc) -> String {
        var t = "\(b.pagesLabel) \(b.role.rawValue)"
        if let s = b.session { t += " " + s }
        if !b.exercices.isEmpty { t += " (\(b.exercices.count) ex.)" }
        return t
    }

    // MARK: Rangement

    func destination(for fiche: SubjectFiche) -> URL {
        switch fiche.etat {
        case .range:
            let m = fiche.meta
            return bank.url("ranges/\(m.etablissement ?? "inconnu")/\(m.niveau ?? "inconnu")/\(m.matiere ?? "inconnue")")
        case .rejete:
            return bank.url("rejets")
        default:
            return bank.url("a_verifier")
        }
    }

    /// Copie le PDF propre (ou les pages originales), le .tex et la fiche à leur place.
    func place(original: URL?, pages: ClosedRange<Int>, fiche: SubjectFiche, baseName: String,
               tex: URL?, compiledPDF: URL?, texContent: String? = nil) throws -> (Bloc) -> SubjectOutput {
        let fm = FileManager.default
        let dir = destination(for: fiche)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdfDest = FileUtils.unique(dir.appendingPathComponent(baseName + ".pdf"))
        let stem = pdfDest.deletingPathExtension().lastPathComponent
        var finalPDF: URL?
        var finalTex: URL?

        if let compiled = compiledPDF {
            try fm.copyItem(at: compiled, to: pdfDest)
            if settings.compressOutput { _ = try? Compressor.compress(pdfDest, level: .light, to: pdfDest) }
            var pm = PDFMetadata()
            pm.title = [config.matiere(fiche.meta.matiere, niveau: fiche.meta.niveau)?.nom,
                        fiche.session.map(AnnalesMetadataDetector.sessionLabel), fiche.meta.anneeUniv]
                .compactMap { $0 }.joined(separator: " — ")
            pm.author = fiche.declared.enseignant
            pm.subject = "Annales \(fiche.meta.niveau ?? "")"
            pm.keywords = Array(Set(fiche.tags.values.flatMap { $0 })).sorted().joined(separator: ", ")
            try? Metadata.write(pm, pdfDest, to: pdfDest)
            finalPDF = pdfDest
        } else if let original = original, let doc = PDFDocument(url: original) {
            // Pas de version propre : on garde les pages originales du bloc.
            let pagesDoc = PDFOps.makeDocument(from: pages.compactMap { doc.page(at: $0 - 1) })
            try PDFOps.save(pagesDoc, to: pdfDest)
            finalPDF = pdfDest
        }
        if let content = texContent ?? tex.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            let texDest = dir.appendingPathComponent(stem + ".tex")
            try content.write(to: texDest, atomically: true, encoding: .utf8)
            finalTex = texDest
            // La classe à côté du .tex : on peut le recompiler tel quel (onglet LaTeX).
            let cls = dir.appendingPathComponent("annales.cls")
            if !fm.fileExists(atPath: cls.path) { try? fm.copyItem(at: config.classURL, to: cls) }
        }
        let ficheURL = dir.appendingPathComponent(stem + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fiche).write(to: ficheURL)
        return { bloc in SubjectOutput(bloc: bloc, fiche: fiche, pdf: finalPDF, tex: finalTex, ficheURL: ficheURL) }
    }

    // MARK: Validation humaine

    /// Relu et corrigé à la main : on note la relecture, on recompile et on range définitivement.
    public func validate(ficheURL: URL, corrections: DeclaredInfo, reviewer: String,
                         log: @escaping (String) -> Void) throws -> URL {
        var fiche = try JSONDecoder().decode(SubjectFiche.self, from: Data(contentsOf: ficheURL))
        let dir = ficheURL.deletingLastPathComponent()
        let stem = ficheURL.deletingPathExtension().lastPathComponent
        let texURL = dir.appendingPathComponent(stem + ".tex")
        guard var tex = try? String(contentsOf: texURL, encoding: .utf8) else {
            throw PDFToolError.commandFailed("pas de .tex à côté de la fiche : rien à valider")
        }
        // Corrections de métadonnées saisies pendant la relecture
        if let v = corrections.value("niveau") { fiche.meta.niveau = v }
        if let v = corrections.value("matiere") { fiche.meta.matiere = v }
        if let v = corrections.value("annee_univ") { fiche.meta.anneeUniv = v }
        if let v = corrections.value("session") { fiche.session = v; fiche.meta.sessions = [v] }
        if let v = corrections.value("etablissement") { fiche.meta.etablissement = v }
        guard fiche.meta.niveau != nil, fiche.meta.matiere != nil, fiche.meta.anneeUniv != nil, fiche.session != nil else {
            throw PDFToolError.commandFailed("complète le niveau, la matière, l'année et la session avant de valider")
        }
        fiche.meta.raisonsDoute = []
        let fields = latexFields(meta: fiche.meta, declared: fiche.declared, session: fiche.session, sha: fiche.empreinte,
                                 kind: nil, extraction: nil, identifiant: fiche.identifiant,
                                 verdict: fiche.verdict, motifs: fiche.motifs,
                                 relecture: "\(Self.today()) — \(reviewer.isEmpty ? "BDE" : reviewer)")
        tex = AnnalesConversion.injectMetadata(tex, fields: fields)
        try tex.write(to: texURL, atomically: true, encoding: .utf8)
        log("Recompilation après relecture…")
        let result = try Latex.compile(texURL, engine: settings.conversion.engine, texInputs: [config.latexFolder, dir])
        guard result.success else {
            let first = Latex.parseIssues(result.log).first { !$0.isWarning }
            throw PDFToolError.commandFailed("le .tex ne compile pas" + (first.map { " : \($0.location) \($0.message)" } ?? ""))
        }
        fiche.etat = .range
        fiche.compiled = true
        fiche.raisons = []
        let oldPDF = dir.appendingPathComponent(stem + ".pdf")
        let make = try place(original: nil, pages: 1...1, fiche: fiche,
                             baseName: "\(fiche.meta.anneeUniv ?? "annee")_\(fiche.session ?? "sujet")",
                             tex: texURL, compiledPDF: result.pdf, texContent: tex)
        let out = make(Bloc(premierePage: 1, dernierePage: 1, texte: ""))
        // Ancienne version (à vérifier) retirée
        if dir.standardizedFileURL != destination(for: fiche).standardizedFileURL {
            for ext in ["pdf", "tex", "json", "log", "aux", "fls", "fdb_latexmk", "synctex.gz", "out", "toc"] {
                try? FileManager.default.trashItem(at: dir.appendingPathComponent("\(stem).\(ext)"), resultingItemURL: nil)
            }
        }
        if let pdf = out.pdf {
            try? bank.setStatut(pdf: oldPDF.path, statut: "valide", newPDF: pdf.path, newTex: out.tex?.path)
            log("Validé et rangé : \(pdf.path)")
            return pdf
        }
        throw PDFToolError.cannotWrite(destination(for: fiche))
    }

    // MARK: Champs et prompts

    static func identifiant(meta: AnnaleMetadata, sha: String, index: Int?) -> String {
        let mat = (meta.matiere ?? "XXX").uppercased().filter { $0.isLetter }.prefix(3)
        let year = meta.anneeUniv.map { String($0.prefix(4)) } ?? "0000"
        return "ANN-\(meta.niveau ?? "XX")-\(mat)-\(year)-\(sha.prefix(6))" + (index.map { "-\($0)" } ?? "")
    }

    static func title(session: String?, bloc: Bloc, type: String) -> String {
        var t: String
        switch type {
        case "td": t = "Travaux dirigés"
        case "tp": t = "Travaux pratiques"
        case "cours": t = "Cours"
        default: t = session.map(AnnalesMetadataDetector.sessionLabel) ?? "Examen"
        }
        if bloc.role == .corrige { t += " — Corrigé" }
        if let v = bloc.version { t += " — Version \(v)" }
        return AnnalesText.latexEscape(t)
    }

    func promptMetadata(meta: AnnaleMetadata, declared: DeclaredInfo, session: String?, bloc: Bloc,
                        type: String) -> [String: String] {
        var d: [String: String] = ["type_document": type, "role_du_bloc": bloc.role.rawValue, "pages": bloc.pagesLabel]
        if let m = config.matiere(meta.matiere, niveau: meta.niveau) { d["matiere"] = m.nom }
        if let n = meta.niveau { d["niveau"] = n }
        if let f = meta.formation { d["formation"] = f }
        if let e = config.etablissement(meta.etablissement) { d["universite"] = e.nom }
        if let a = meta.anneeUniv { d["annee_univ"] = a }
        if let s = session { d["session"] = AnnalesMetadataDetector.sessionLabel(s) }
        if !declared.enseignant.isEmpty { d["enseignant"] = declared.enseignant }
        if let v = bloc.version { d["version"] = v }
        return d
    }

    func latexFields(meta: AnnaleMetadata, declared: DeclaredInfo, session: String?, sha: String,
                     kind: DepositKind?, extraction: TextExtraction?, identifiant: String,
                     verdict: Verdict? = nil, motifs: [String] = [], relecture: String = "") -> [(String, String)] {
        let e = AnnalesText.latexEscape
        let matiere = config.matiere(meta.matiere, niveau: meta.niveau)?.nom ?? ""
        var formation = ""
        if let n = meta.niveau {
            let level = n.hasPrefix("L") ? "Licence \(n.dropFirst())" : "Master \(n.dropFirst())"
            formation = level + (meta.formation.map { " \($0)" } ?? "")
        } else if let f = meta.formation {
            formation = f
        }
        let universite = config.etablissement(meta.etablissement)?.nom ?? ""
        let original = extraction.map { Self.originalLabel(kind, $0) } ?? ""
        var verification = "Contrôle de crédibilité par IA (Toolbox)"
        if let v = verdict {
            verification = "Contrôle IA : \(v.label.lowercased())" + (motifs.isEmpty ? "" : " (\(motifs.joined(separator: " ; ")))")
        }
        if !relecture.isEmpty { verification += " + relecture humaine" }
        var fields: [(String, String)] = [
            ("matiere", e(matiere)),
            ("session", session.map(AnnalesMetadataDetector.sessionLatex) ?? ""),
            ("formation", e(formation)),
            ("universite", e(universite)),
            ("anneeuniv", (meta.anneeUniv ?? "").replacingOccurrences(of: "-", with: "--")),
            ("enseignant", e(declared.enseignant)),
            ("empreinte", sha),
            ("deposepar", e(declared.deposePar)),
            ("datedepot", Self.today()),
            ("identifiant", e(identifiant)),
            ("verification", e(verification)),
            ("diffusion", "En attente de l'accord de l'enseignant"),
            ("relecture", e(relecture)),
        ]
        if !original.isEmpty { fields.append(("original", e(original))) }
        return fields
    }

    // MARK: Tags par l'IA

    func aiTags(exercices: [Exercice], notions: [NotionRule], matiere: String) async -> [String: [String]]? {
        let valid = Set(notions.map { $0.name })
        let liste = notions.map { "- \($0.name) (mots-clés : \($0.mots.prefix(8).joined(separator: ", ")))" }.joined(separator: "\n")
        let exos = exercices.map { "### Exercice \($0.numero)\n\(String($0.texte.prefix(2500)))" }.joined(separator: "\n\n")
        let prompt = """
        Matière : \(matiere). Notions possibles (utilise EXACTEMENT ces noms) :
        \(liste)

        Pour chaque exercice ci-dessous, choisis de 1 à 3 notions dans la liste, de la plus \
        importante à la moins importante. Réponds UNIQUEMENT en JSON, sous la forme :
        {"1": ["notion_a", "notion_b"], "2": ["notion_c"]}

        \(exos)
        """
        guard let raw = try? await client.chat(model: settings.conversion.model,
                                               messages: [OllamaMessage(role: "user", content: prompt)],
                                               options: ["temperature": 0, "num_ctx": settings.conversion.numCtx],
                                               format: "json"),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [String: [String]] = [:]
        for e in exercices {
            let picked = (json[e.numero] as? [String] ?? []).filter { valid.contains($0) }
            result[e.numero] = Array(picked.prefix(3))
        }
        return result.values.allSatisfy({ $0.isEmpty }) ? nil : result
    }
}
