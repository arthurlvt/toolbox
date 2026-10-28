import Foundation
import PDFCore

// pdftool — la même boîte à outils, en ligne de commande.

let help = """
pdftool — boîte à outils PDF & LaTeX 100 % locale

PDF
  pdftool merge   sortie.pdf a.pdf b.pdf [...]          Fusionner
  pdftool split   doc.pdf [--every N | --ranges "1-3,4-"] [--out dossier]
                                                        Diviser (défaut : une page par fichier)
  pdftool extract doc.pdf "1-3,7" [sortie.pdf]          Garder ces pages (dans cet ordre)
  pdftool delete  doc.pdf "2,5-6" [sortie.pdf]          Supprimer ces pages
  pdftool rotate  doc.pdf 90 [--pages "1-3"] [sortie.pdf]
                                                        Pivoter (90, 180, 270, -90)
  pdftool compress doc.pdf [...] [--level strong|balanced|light]
                                                        Crée doc_compressé.pdf à côté
  pdftool info    doc.pdf                               Infos (pages, taille, métadonnées)
  pdftool ocr     scan.pdf [...] [--lang fr|en|fr,en] [--force]
                                                        Rendre cherchable → scan_ocr.pdf
  pdftool number  doc.pdf [--format "{n} / {total}"] [--pos bas|bas-droite|bas-gauche|haut|haut-droite]
                  [--start N] [--skip-first] [--header "…"] [--footer "…"] [--watermark "…"] [sortie.pdf]
  pdftool watermark doc.pdf "BROUILLON" [--opacity 0.15] [sortie.pdf]
  pdftool protect doc.pdf motdepasse [sortie.pdf]       Chiffrer avec un mot de passe
  pdftool unlock  doc.pdf motdepasse [sortie.pdf]       Retirer le mot de passe
  pdftool meta    doc.pdf [--title …] [--author …] [--subject …] [--keywords "a, b"]
                                                        Lire (sans option) ou modifier les infos
  pdftool crop    doc.pdf [--auto [--keep 5] | --margins "haut,bas,gauche,droite" (mm)] [--pages …] [sortie.pdf]
  pdftool nup     doc.pdf [2|4] [sortie.pdf]            2 ou 4 pages par feuille A4
  pdftool booklet doc.pdf [sortie.pdf]                  Livret A5 (recto-verso bord court, plier)
  pdftool rag     doc.pdf [...] [--format md|jsonl]     Export texte par page pour un RAG
  pdftool batch   dossier_sortie a.pdf b.pdf [...] [--ocr] [--number] [--compress strong|balanced|light]
                  [--author "…"] [--rename "{nom}_{n}"]

Conversion
  pdftool img2pdf sortie.pdf img1.jpg img2.png [...] [--original]
                                                        Images → PDF (A4 par défaut)
  pdftool pdf2img doc.pdf [--dpi 150] [--format png|jpeg] [--pages "1-3"] [--out dossier]
  pdftool text    doc.pdf [sortie.txt]                  PDF → texte

LaTeX
  pdftool tex   main.tex [--engine pdflatex|xelatex|lualatex] [--watch] [--verbose]
  pdftool clean main.tex                                Fichiers auxiliaires → corbeille
  pdftool new   "Titre" [--template cours|td|rapport|beamer] [--author "…"] [--in dossier]
  pdftool words main.tex                                Nombre de mots

Annales (Annalyse, IA locale via Ollama)
  pdftool annales depot1.pdf photo.jpg [...] --annalyse ~/…/Annalyse --model qwen2.5vl:7b
                  [--banque dossier] [--niveau L1] [--matiere analyse1] [--annee 2024-2025]
                  [--session CC1] [--type examen|td|tp|cours] [--enseignant …] [--par …] [--sans-images]

Plages de pages : "1-3, 5, 8-"  (8- = jusqu'à la fin, -3 = depuis le début)
"""

var args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("L'option \(name) attend une valeur.") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func path(_ p: String) -> URL {
    URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
}

func require(_ count: Int, _ usage: String) {
    if args.count < count { fail("Usage : \(usage)") }
}

func sibling(_ url: URL, _ suffix: String) -> URL { FileUtils.sibling(of: url, suffix: suffix) }

guard let command = args.first, !["-h", "--help", "help"].contains(command) else {
    print(help)
    exit(0)
}
args.removeFirst()

do {
    switch command {
    case "merge":
        require(3, "pdftool merge sortie.pdf a.pdf b.pdf [...]")
        let out = path(args[0])
        let n = try PDFOps.merge(args.dropFirst().map(path), into: out)
        print("✓ \(out.lastPathComponent) — \(n) pages")

    case "split":
        let every = option("--every")
        let ranges = option("--ranges")
        let outDir = option("--out")
        require(1, "pdftool split doc.pdf [--every N | --ranges \"1-3,4-\"] [--out dossier]")
        let input = path(args[0])
        let mode: PDFOps.SplitMode
        if let e = every {
            guard let n = Int(e) else { fail("--every attend un nombre.") }
            mode = .every(n)
        } else if let r = ranges {
            mode = .ranges(r)
        } else {
            mode = .everyPage
        }
        let folder = outDir.map(path)
            ?? FileUtils.unique(input.deletingLastPathComponent()
                .appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_divisé"))
        let files = try PDFOps.split(input, mode: mode, into: folder)
        print("✓ \(files.count) fichiers dans \(folder.path)")

    case "extract":
        require(2, "pdftool extract doc.pdf \"1-3,7\" [sortie.pdf]")
        let input = path(args[0])
        let out = args.count > 2 ? path(args[2]) : sibling(input, "_extrait")
        let n = try PDFOps.extract(input, pages: args[1], to: out)
        print("✓ \(out.lastPathComponent) — \(n) pages")

    case "delete":
        require(2, "pdftool delete doc.pdf \"2,5-6\" [sortie.pdf]")
        let input = path(args[0])
        let out = args.count > 2 ? path(args[2]) : sibling(input, "_modifié")
        let n = try PDFOps.delete(input, pages: args[1], to: out)
        print("✓ \(out.lastPathComponent) — \(n) pages restantes")

    case "rotate":
        let pages = option("--pages")
        require(2, "pdftool rotate doc.pdf 90 [--pages \"1-3\"] [sortie.pdf]")
        let input = path(args[0])
        guard let deg = Int(args[1]), deg % 90 == 0 else { fail("L'angle doit être un multiple de 90.") }
        let out = args.count > 2 ? path(args[2]) : sibling(input, "_pivoté")
        try PDFOps.rotate(input, degrees: deg, pages: pages, to: out)
        print("✓ \(out.lastPathComponent)")

    case "compress":
        let levelName = option("--level") ?? "balanced"
        guard let level = CompressionLevel(rawValue: levelName) else {
            fail("Niveau inconnu : \(levelName) (strong, balanced, light)")
        }
        require(1, "pdftool compress doc.pdf [...] [--level strong|balanced|light]")
        if Compressor.ghostscriptPath == nil {
            print("ℹ︎ Ghostscript absent : compression basique. Pour mieux : brew install ghostscript")
        }
        for p in args {
            let input = path(p)
            let r = try Compressor.compress(input, level: level, to: sibling(input, "_compressé"))
            print("✓ \(input.lastPathComponent) : \(r.summary) [\(r.method)]")
        }

    case "info":
        require(1, "pdftool info doc.pdf")
        for p in args {
            for (k, v) in try PDFOps.info(path(p)) {
                print(k.padding(toLength: 15, withPad: " ", startingAt: 0) + v)
            }
            print("")
        }

    case "img2pdf":
        let original = flag("--original")
        require(2, "pdftool img2pdf sortie.pdf img1.jpg [...] [--original]")
        let out = path(args[0])
        let n = try Converter.imagesToPDF(args.dropFirst().map(path), pageSize: original ? .original : .a4, to: out)
        print("✓ \(out.lastPathComponent) — \(n) pages")

    case "pdf2img":
        let dpi = Double(option("--dpi") ?? "150") ?? 150
        let formatName = (option("--format") ?? "png").lowercased()
        let pages = option("--pages")
        let outDir = option("--out")
        require(1, "pdftool pdf2img doc.pdf [--dpi 150] [--format png|jpeg] [--pages \"1-3\"] [--out dossier]")
        let format: ImageFormat = ["jpg", "jpeg"].contains(formatName) ? .jpeg : .png
        let input = path(args[0])
        let folder = outDir.map(path)
            ?? FileUtils.unique(input.deletingLastPathComponent()
                .appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_images"))
        let files = try Converter.pdfToImages(input, format: format, dpi: dpi, pages: pages, into: folder)
        print("✓ \(files.count) images dans \(folder.path)")

    case "text":
        require(1, "pdftool text doc.pdf [sortie.txt]")
        let input = path(args[0])
        let out = args.count > 1 ? path(args[1]) : FileUtils.sibling(of: input, suffix: "", ext: "txt")
        try Converter.pdfToText(input, to: out)
        print("✓ \(out.lastPathComponent)")

    case "tex":
        let engineName = option("--engine") ?? "pdflatex"
        let watch = flag("--watch")
        let verbose = flag("--verbose")
        guard let engine = LatexEngine(rawValue: engineName) else { fail("Moteur inconnu : \(engineName)") }
        require(1, "pdftool tex main.tex [--engine pdflatex|xelatex|lualatex] [--watch] [--verbose]")
        let tex = path(args[0])

        func build() {
            let start = Date()
            do {
                let echo: ((String) -> Void)? = verbose ? { (s: String) in print(s, terminator: "") } : nil
                let r = try Latex.compile(tex, engine: engine, onOutput: echo)
                let issues = Latex.parseIssues(r.log)
                for i in issues {
                    let tag = i.isWarning ? "⚠︎" : "✗"
                    print("  \(tag) \(i.location.isEmpty ? "" : i.location + " : ")\(i.message)")
                }
                let secs = String(format: "%.1f", Date().timeIntervalSince(start))
                print(r.success ? "✓ \(r.pdf.lastPathComponent) (\(secs) s)" : "✗ Échec de la compilation (\(secs) s)")
            } catch {
                print("✗ \(error.localizedDescription)")
            }
        }

        build()
        if watch {
            print("👀 Surveillance de \(tex.deletingLastPathComponent().path) — Ctrl-C pour arrêter")
            var snapshot = Latex.sourceSnapshot(in: tex.deletingLastPathComponent())
            while true {
                Thread.sleep(forTimeInterval: 0.8)
                let now = Latex.sourceSnapshot(in: tex.deletingLastPathComponent())
                if now != snapshot {
                    snapshot = now
                    print("\n↻ Modification détectée")
                    build()
                }
            }
        }

    case "clean":
        require(1, "pdftool clean main.tex")
        let removed = Latex.clean(path(args[0]))
        print(removed.isEmpty ? "Rien à nettoyer." : "✓ \(removed.count) fichier(s) mis à la corbeille")

    case "ocr":
        let lang = option("--lang") ?? "fr,en"
        let force = flag("--force")
        require(1, "pdftool ocr scan.pdf [...] [--lang fr|en|fr,en] [--force]")
        var o = OCROptions()
        o.languages = lang.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) == "en" ? "en-US" : "fr-FR" }
        o.skipPagesWithText = !force
        for p in args {
            let input = path(p)
            let out = sibling(input, "_ocr")
            let r = try OCR.makeSearchable(input, options: o, to: out) { page, total in
                FileHandle.standardError.write(Data("\r  page \(page)/\(total)".utf8))
            }
            FileHandle.standardError.write(Data("\r".utf8))
            print("✓ \(out.lastPathComponent) — \(r.recognizedPages)/\(r.pages) pages reconnues, \(r.characters) caractères")
        }

    case "number", "watermark":
        var o = StampOptions()
        if command == "number" {
            o.numbering = true
            if let f = option("--format") { o.numberFormat = f }
            if let pos = option("--pos") {
                let map: [String: StampPosition] = ["bas": .bottomCenter, "bas-droite": .bottomRight, "bas-gauche": .bottomLeft,
                                                    "haut": .topCenter, "haut-droite": .topRight]
                guard let p = map[pos] else { fail("Position inconnue : \(pos)") }
                o.numberPosition = p
            }
            if let st = option("--start") { o.firstNumber = Int(st) ?? 1 }
            o.skipFirstPage = flag("--skip-first")
            if let h = option("--header") { o.header = h }
            if let f = option("--footer") { o.footer = f }
            if let w = option("--watermark") { o.watermark = w }
            if let size = option("--size") { o.fontSize = Double(size) ?? 10 }
            require(1, "pdftool number doc.pdf [options] [sortie.pdf]")
        } else {
            if let op = option("--opacity") { o.watermarkOpacity = Double(op) ?? 0.15 }
            require(2, "pdftool watermark doc.pdf \"TEXTE\" [--opacity 0.15] [sortie.pdf]")
            o.watermark = args.remove(at: 1)
        }
        let input = path(args[0])
        let out = args.count > 1 ? path(args[1]) : sibling(input, command == "number" ? "_numéroté" : "_filigrane")
        let n = try Stamper.stamp(input, options: o, to: out)
        print("✓ \(out.lastPathComponent) — \(n) pages")

    case "protect":
        require(2, "pdftool protect doc.pdf motdepasse [sortie.pdf]")
        let input = path(args[0])
        let out = args.count > 2 ? path(args[2]) : sibling(input, "_protégé")
        try Security.protect(input, password: args[1], to: out)
        print("✓ \(out.lastPathComponent) protégé")

    case "unlock":
        require(2, "pdftool unlock doc.pdf motdepasse [sortie.pdf]")
        let input = path(args[0])
        let out = args.count > 2 ? path(args[2]) : sibling(input, "_déverrouillé")
        try Security.unlock(input, password: args[1], to: out)
        print("✓ \(out.lastPathComponent) sans mot de passe")

    case "meta":
        let title = option("--title"), author = option("--author")
        let subject = option("--subject"), keywords = option("--keywords")
        require(1, "pdftool meta doc.pdf [--title …] [--author …] [--subject …] [--keywords \"a, b\"]")
        let input = path(args[0])
        var m = try Metadata.read(input)
        if title == nil && author == nil && subject == nil && keywords == nil {
            print("Titre     : \(m.title)\nAuteur    : \(m.author)\nSujet     : \(m.subject)\nMots-clés : \(m.keywords)")
        } else {
            if let v = title { m.title = v }
            if let v = author { m.author = v }
            if let v = subject { m.subject = v }
            if let v = keywords { m.keywords = v }
            try Metadata.write(m, input, to: input)
            print("✓ Infos de \(input.lastPathComponent) mises à jour")
        }

    case "crop":
        let auto = flag("--auto")
        let keep = Double(option("--keep") ?? "5") ?? 5
        let marginsText = option("--margins")
        let pages = option("--pages")
        require(1, "pdftool crop doc.pdf [--auto [--keep 5] | --margins \"h,b,g,d\"] [--pages …] [sortie.pdf]")
        let input = path(args[0])
        let out = args.count > 1 ? path(args[1]) : sibling(input, "_rogné")
        if auto || marginsText == nil {
            let n = try Layout.autoCrop(input, keepMM: keep, pages: pages, to: out)
            print("✓ \(out.lastPathComponent) — \(n) pages rognées automatiquement")
        } else {
            let v = marginsText!.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 4 else { fail("--margins attend 4 valeurs en mm : haut,bas,gauche,droite") }
            let n = try Layout.crop(input, margins: Margins(top: v[0], bottom: v[1], left: v[2], right: v[3]), pages: pages, to: out)
            print("✓ \(out.lastPathComponent) — \(n) pages rognées")
        }

    case "nup":
        require(1, "pdftool nup doc.pdf [2|4] [sortie.pdf]")
        let input = path(args[0])
        let four = args.count > 1 && args[1] == "4"
        if args.count > 1 && (args[1] == "2" || args[1] == "4") { args.remove(at: 1) }
        let out = args.count > 1 ? path(args[1]) : sibling(input, four ? "_4-par-feuille" : "_2-par-feuille")
        let n = try Layout.impose(input, layout: four ? .fourUp : .twoUp, to: out)
        print("✓ \(out.lastPathComponent) — \(n) feuilles")

    case "booklet":
        require(1, "pdftool booklet doc.pdf [sortie.pdf]")
        let input = path(args[0])
        let out = args.count > 1 ? path(args[1]) : sibling(input, "_livret")
        let n = try Layout.impose(input, layout: .booklet, to: out)
        print("✓ \(out.lastPathComponent) — \(n) faces : imprime en recto-verso (bord court), puis plie")

    case "rag":
        let fmt = (option("--format") ?? "md").lowercased()
        let format: RAGFormat = fmt.hasPrefix("json") ? .jsonl : .markdown
        require(1, "pdftool rag doc.pdf [...] [--format md|jsonl]")
        for p in args {
            let input = path(p)
            let out = FileUtils.sibling(of: input, suffix: "", ext: format.fileExtension)
            let n = try RAGExport.export(input, format: format, to: out)
            print("✓ \(out.lastPathComponent) — \(n) pages avec texte")
        }

    case "batch":
        var o = BatchOptions()
        o.ocr = flag("--ocr")
        o.stamp.numbering = flag("--number")
        if let w = option("--watermark") { o.stamp.watermark = w }
        if let c = option("--compress") {
            guard let level = CompressionLevel(rawValue: c) else { fail("Niveau inconnu : \(c)") }
            o.compression = level
        }
        if let a = option("--author") { var m = PDFMetadata(); m.author = a; o.metadata = m }
        if let r = option("--rename") { o.renamePattern = r }
        require(2, "pdftool batch dossier_sortie a.pdf [...] [--ocr] [--number] [--compress …] [--author …] [--rename …]")
        let folder = path(args[0])
        let results = Batch.run(args.dropFirst().map(path), options: o, into: folder) { i, n, name in
            print("  [\(i)/\(n)] \(name)")
        }
        for r in results {
            if let e = r.error { print("✗ \(r.input.lastPathComponent) : \(e)") }
            else { print("✓ \(r.input.lastPathComponent) → \(r.output?.lastPathComponent ?? "")") }
        }

    case "new":
        let templateName = (option("--template") ?? "cours").lowercased()
        let author = option("--author") ?? NSFullUserName()
        let dir = option("--in").map(path) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        require(1, "pdftool new \"Titre\" [--template cours|td|rapport|beamer] [--author …] [--in dossier]")
        let map: [String: LatexTemplate] = ["cours": .course, "td": .exercises, "rapport": .report, "beamer": .slides]
        guard let template = map[templateName] else { fail("Modèle inconnu : \(templateName) (cours, td, rapport, beamer)") }
        let main = try template.createProject(title: args.joined(separator: " "), author: author, in: dir)
        print("✓ Projet créé : \(main.path)")

    case "words":
        require(1, "pdftool words main.tex")
        let (n, source) = Latex.wordCount(path(args[0]))
        print(n.map { "\($0) mots (\(source))" } ?? "Impossible de compter les mots.")

    case "annales":
        guard let rootText = option("--annalyse") else { fail("--annalyse : dossier Annalyse (config/ et latex/) obligatoire") }
        guard let model = option("--model") else { fail("--model : nom du modèle Ollama (ex. qwen2.5vl:7b) obligatoire") }
        let root = path(rootText)
        let bankRoot = option("--banque").map(path) ?? root.appendingPathComponent("banque")
        var declared = DeclaredInfo()
        declared.niveau = option("--niveau") ?? ""
        declared.matiere = option("--matiere") ?? ""
        declared.anneeUniv = option("--annee") ?? ""
        declared.session = option("--session") ?? ""
        declared.typeDocument = option("--type") ?? ""
        declared.enseignant = option("--enseignant") ?? ""
        declared.deposePar = option("--par") ?? ""
        let noImages = flag("--sans-images")
        let host = option("--hote") ?? ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? OllamaClient.defaultHost
        require(1, "pdftool annales fichier [...] --annalyse dossier --model modèle")
        var settings = AnnalesSettings(annalyseRoot: root, bankRoot: bankRoot, model: model)
        settings.conversion.useImages = !noImages
        let pipeline = try AnnalesPipeline(settings: settings, client: OllamaClient(host: host))
        let files = args.map(path)
        let declaredInfo = declared

        final class Outcome { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                for file in files {
                    print("== \(file.lastPathComponent)")
                    let r = try await pipeline.process(file, declared: declaredInfo) { print("   " + $0) }
                    print("   \(r.message)")
                    for out in r.subjects {
                        print("   [\(out.fiche.etat.label)] \(out.title) → \(out.pdf?.path ?? out.tex?.path ?? "—")")
                    }
                }
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        done.wait()
        if let e = outcome.error { throw e }
        print("Banque : \(bankRoot.path)")

    default:
        fail("Commande inconnue : \(command)\n\n\(help)")
    }
} catch {
    fail("✗ \(error.localizedDescription)")
}
