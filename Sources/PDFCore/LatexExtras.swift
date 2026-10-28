import Foundation

// MARK: - SyncTeX (aller-retour PDF ↔ source)

public struct SyncTeXSource {
    public let file: URL
    public let line: Int
}

public struct SyncTeXTarget {
    /// Page (à partir de 1).
    public let page: Int
    /// Position en points, origine en HAUT à gauche de la page (convention SyncTeX).
    public let x: Double
    public let y: Double
}

public enum SyncTeX {
    public static var isAvailable: Bool { Shell.which("synctex") != nil }

    /// Clic dans le PDF → fichier source et ligne. `x`, `y` : points depuis le coin haut-gauche.
    public static func source(pdf: URL, page: Int, x: Double, y: Double) -> SyncTeXSource? {
        guard let exe = Shell.which("synctex"),
              let r = try? Shell.run(exe, ["edit", "-o", "\(page):\(x):\(y):\(pdf.path)"],
                                     in: pdf.deletingLastPathComponent()),
              r.status == 0 else { return nil }
        var file: String?
        var line: Int?
        for l in r.text.components(separatedBy: .newlines) {
            if file == nil, l.hasPrefix("Input:") { file = String(l.dropFirst(6)) }
            if line == nil, l.hasPrefix("Line:") { line = Int(l.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
        }
        guard let f = file, let ln = line else { return nil }
        let url = URL(fileURLWithPath: f, relativeTo: pdf.deletingLastPathComponent()).standardizedFileURL
        return SyncTeXSource(file: url, line: max(1, ln))
    }

    /// Ligne du source → position dans le PDF.
    public static func target(tex: URL, line: Int, pdf: URL) -> SyncTeXTarget? {
        guard let exe = Shell.which("synctex"),
              let r = try? Shell.run(exe, ["view", "-i", "\(line):0:\(tex.path)", "-o", pdf.path],
                                     in: pdf.deletingLastPathComponent()),
              r.status == 0 else { return nil }
        var page: Int?
        var x: Double?
        var y: Double?
        for l in r.text.components(separatedBy: .newlines) {
            if page == nil, l.hasPrefix("Page:") { page = Int(l.dropFirst(5)) }
            if x == nil, l.hasPrefix("x:") { x = Double(l.dropFirst(2)) }
            if y == nil, l.hasPrefix("y:") { y = Double(l.dropFirst(2)) }
        }
        guard let p = page else { return nil }
        return SyncTeXTarget(page: p, x: x ?? 0, y: y ?? 0)
    }
}

// MARK: - Statistiques

public struct LatexStats {
    public let words: Int?
    public let wordSource: String
    public let undefinedReferences: [String]
    public let undefinedCitations: [String]
}

extension Latex {

    public static func stats(for tex: URL, issues: [LatexIssue]) -> LatexStats {
        let (words, source) = wordCount(tex)
        var refs: [String] = []
        var cites: [String] = []
        let pattern = try? NSRegularExpression(pattern: #"(Reference|Citation) [`‘']([^'’]+)['’].*undefined"#)
        for issue in issues where issue.isWarning {
            let m = issue.message
            guard let regex = pattern,
                  let match = regex.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)),
                  let kindRange = Range(match.range(at: 1), in: m),
                  let keyRange = Range(match.range(at: 2), in: m) else { continue }
            let key = String(m[keyRange])
            if m[kindRange] == "Reference" {
                if !refs.contains(key) { refs.append(key) }
            } else if !cites.contains(key) {
                cites.append(key)
            }
        }
        return LatexStats(words: words, wordSource: source, undefinedReferences: refs, undefinedCitations: cites)
    }

    /// Nombre de mots via texcount (inclus dans TeX Live), sinon estimation.
    public static func wordCount(_ tex: URL) -> (Int?, String) {
        if let tc = Shell.which("texcount"),
           let r = try? Shell.run(tc, ["-1", "-sum", "-inc", "-utf8", tex.lastPathComponent],
                                  in: tex.deletingLastPathComponent()),
           r.status == 0,
           let n = Int(r.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber }) {
            return (n, "texcount")
        }
        guard let text = try? String(contentsOf: tex, encoding: .utf8) else { return (nil, "") }
        var body = text
        if let start = body.range(of: "\\begin{document}") { body = String(body[start.upperBound...]) }
        body = body.replacingOccurrences(of: #"(?m)(?<!\\)%.*$"#, with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\$[^$]*\$"#, with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\\[a-zA-Z@]+\*?(\[[^\]]*\])?"#, with: " ", options: .regularExpression)
        let words = body.components(separatedBy: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "'’-")))
            .filter { $0.count > 1 }
        return (words.count, "estimation")
    }
}

// MARK: - Modèles de projet

public enum LatexTemplate: String, CaseIterable, Identifiable {
    case course = "Résumé de cours"
    case exercises = "TD / exercices corrigés"
    case report = "Rapport"
    case slides = "Présentation (Beamer)"

    public var id: String { rawValue }

    public var summary: String {
        switch self {
        case .course: return "Définitions, théorèmes et démonstrations encadrés, table des matières."
        case .exercises: return "Énoncés numérotés, corrigés masquables d'un seul interrupteur."
        case .report: return "Page de titre, chapitres, bibliographie (biblatex)."
        case .slides: return "Diaporama Beamer sobre, en français."
        }
    }

    static let preamble = #"""
    \usepackage[T1]{fontenc}
    \usepackage[utf8]{inputenc}
    \usepackage[french]{babel}
    \usepackage{lmodern}
    \usepackage{amsmath, amssymb, amsthm, mathtools}
    \usepackage{xcolor}
    \usepackage{enumitem}
    \usepackage{graphicx}
    \usepackage[hidelinks]{hyperref}

    % Raccourcis
    \newcommand{\N}{\mathbb{N}}
    \newcommand{\Z}{\mathbb{Z}}
    \newcommand{\Q}{\mathbb{Q}}
    \newcommand{\R}{\mathbb{R}}
    \newcommand{\C}{\mathbb{C}}
    """#

    public func content(title: String, author: String) -> String {
        let pre = LatexTemplate.preamble
        switch self {
        case .course:
            return #"""
            \documentclass[11pt,a4paper]{article}
            \#(pre)
            \usepackage[margin=2.2cm]{geometry}
            \usepackage[most]{tcolorbox}

            \tcbset{base/.style={enhanced, breakable, boxrule=0.6pt, arc=2pt, left=6pt, right=6pt}}
            \newtcbtheorem[number within=section]{definition}{Définition}{base, colback=blue!4, colframe=blue!55!black}{def}
            \newtcbtheorem[use counter from=definition]{theoreme}{Théorème}{base, colback=red!4, colframe=red!55!black}{thm}
            \newtcbtheorem[use counter from=definition]{propriete}{Propriété}{base, colback=green!4, colframe=green!45!black}{prop}
            \newtcolorbox{methode}{base, colback=orange!6, colframe=orange!70!black, title=Méthode}
            \theoremstyle{remark}
            \newtheorem*{remarque}{Remarque}
            \newtheorem*{exemple}{Exemple}

            \title{\#(title)}
            \author{\#(author)}
            \date{\today}

            \begin{document}
            \maketitle
            \tableofcontents

            \section{Première partie}

            \begin{definition}{Nom de la notion}{exemple}
            Une suite $(u_n)_{n\in\N}$ converge vers $\ell\in\R$ si
            \[ \forall \varepsilon>0,\ \exists N\in\N,\ \forall n\ge N,\ |u_n-\ell|<\varepsilon. \]
            \end{definition}

            \begin{theoreme}{Unicité de la limite}{unicite}
            Si une suite converge, sa limite est unique.
            \end{theoreme}

            \begin{proof}
            À compléter.
            \end{proof}

            \begin{remarque}
            Voir la définition~\ref{def:exemple}.
            \end{remarque}

            \end{document}
            """#

        case .exercises:
            return #"""
            \documentclass[11pt,a4paper]{article}
            \#(pre)
            \usepackage[margin=2cm]{geometry}
            \usepackage{ifthen}

            % Passer à false pour masquer tous les corrigés.
            \newboolean{corriges}
            \setboolean{corriges}{true}

            \newcounter{exo}
            \newenvironment{exercice}[1][]{%
              \refstepcounter{exo}\par\medskip\noindent
              \textbf{Exercice~\theexo}\ifthenelse{\equal{#1}{}}{}{~\textit{(#1)}}\quad}{\par}
            \newenvironment{corrige}{%
              \par\smallskip\noindent\color{blue!50!black}\textbf{Corrigé.}\quad}{\par}

            \title{\#(title)}
            \author{\#(author)}
            \date{\today}

            \begin{document}
            \maketitle

            \begin{exercice}[Échauffement]
            Calculer $\displaystyle \lim_{x\to 0} \frac{\sin x}{x}$.
            \end{exercice}
            \ifthenelse{\boolean{corriges}}{
            \begin{corrige}
            C'est le taux d'accroissement de $\sin$ en $0$, donc la limite vaut $\cos 0 = 1$.
            \end{corrige}
            }{}

            \end{document}
            """#

        case .report:
            return #"""
            \documentclass[11pt,a4paper]{report}
            \#(pre)
            \usepackage[margin=2.5cm]{geometry}
            \usepackage{csquotes}
            \usepackage[backend=biber, style=numeric]{biblatex}
            \addbibresource{references.bib}

            \title{\#(title)}
            \author{\#(author)}
            \date{\today}

            \begin{document}
            \maketitle
            \tableofcontents

            \chapter{Introduction}
            Contexte et objectifs~\cite{exemple}.

            \chapter{Développement}

            \chapter{Conclusion}

            \printbibliography
            \end{document}
            """#

        case .slides:
            return #"""
            \documentclass[11pt,aspectratio=169]{beamer}
            \usetheme{metropolis}
            \usepackage[T1]{fontenc}
            \usepackage[utf8]{inputenc}
            \usepackage[french]{babel}
            \usepackage{amsmath, amssymb}

            \title{\#(title)}
            \author{\#(author)}
            \date{\today}

            \begin{document}
            \maketitle

            \begin{frame}{Plan}
              \tableofcontents
            \end{frame}

            \section{Introduction}
            \begin{frame}{Première diapositive}
              \begin{itemize}
                \item Un point
                \item Un autre point
              \end{itemize}
            \end{frame}

            \end{document}
            """#
        }
    }

    /// Fichiers annexes du modèle.
    var extraFiles: [String: String] {
        switch self {
        case .report:
            return ["references.bib": """
            @book{exemple,
              author    = {Donald E. Knuth},
              title     = {The TeXbook},
              publisher = {Addison-Wesley},
              year      = {1984}
            }
            """]
        default:
            return [:]
        }
    }

    /// Crée « parent/<titre>/main.tex » (+ annexes) et renvoie l'URL de main.tex.
    public func createProject(title: String, author: String, in parent: URL) throws -> URL {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Nouveau document" : title
        let slug = cleanTitle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let folder = FileUtils.unique(parent.appendingPathComponent(slug.isEmpty ? "projet-latex" : slug))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let main = folder.appendingPathComponent("main.tex")
        let tex = "% !TEX program = \(self == .report ? "pdflatex" : "pdflatex")\n" + content(title: cleanTitle, author: author)
        try tex.write(to: main, atomically: true, encoding: .utf8)
        for (name, text) in extraFiles {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try ".DS_Store\n*.aux\n*.log\n*.out\n*.toc\n*.fls\n*.fdb_latexmk\n*.synctex.gz\n*.bbl\n*.blg\n*.bcf\n*.run.xml\n"
            .write(to: folder.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        return main
    }
}
