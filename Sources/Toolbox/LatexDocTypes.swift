import SwiftUI
import AppKit
import PDFCore

// MARK: - Types de document

/// « Nouveau document » : TD, TP, cours, rapport ou autre, avec un modèle pré-rempli
/// reprenant la mise en page des modèles d'Annalyse (annales.cls, exemples, cahier de projet),
/// mais autonome : pas besoin de la classe à côté du fichier, et pas de fiche de provenance.
enum LatexDocKind: String, CaseIterable, Identifiable {
    case td, tp, cours, test, rapport, autre
    var id: String { rawValue }

    var title: String {
        switch self {
        case .td: return "TD"
        case .tp: return "TP"
        case .cours: return "Cours"
        case .test: return "Test hebdo"
        case .rapport: return "Rapport"
        case .autre: return "Autre"
        }
    }
    var icon: String {
        switch self {
        case .td: return "pencil.and.list.clipboard"
        case .tp: return "chevron.left.forwardslash.chevron.right"
        case .cours: return "book.closed"
        case .test: return "checklist"
        case .rapport: return "doc.richtext"
        case .autre: return "doc"
        }
    }
    var color: Color {
        switch self {
        case .td: return .blue
        case .tp: return .green
        case .cours: return .indigo
        case .test: return .pink
        case .rapport: return .orange
        case .autre: return .gray
        }
    }
    var summary: String {
        switch self {
        case .td: return "En-tête TD n° – thème, objectif, exercices et questions numérotés automatiquement, corrections masquables."
        case .tp: return "Objectifs, code en couleur (listings), réponses encadrées, section rendu et compilation."
        case .cours: return "Page de titre, sommaire, encadrés colorés : définition, théorème, propriété, méthode, exemple…"
        case .test: return "Test de connaissances de la semaine, en gros caractères : Restituer / Calculer, espace pour répondre, note sur 5."
        case .rapport: return "Page de titre façon cahier de projet, sommaire, sections, encadrés objectif / livrable, tableau."
        case .autre: return "Document simple avec le même préambule (maths, couleurs, code)."
        }
    }
    /// Type du dossier « Mes cours » où ranger le document.
    var courseKind: CourseKind {
        switch self {
        case .td: return .td
        case .tp: return .tp
        case .cours: return .cours
        case .test, .rapport, .autre: return .autre
        }
    }
    var numbered: Bool { self == .td || self == .tp || self == .cours }
    var numberLabel: String { self == .cours ? "Chapitre" : title }
    var titlePrompt: String {
        switch self {
        case .td: return "Ex. : Limites et continuité"
        case .tp: return "Ex. : Pointeurs et tableaux"
        case .cours: return "Ex. : Les nombres réels"
        case .test: return ""
        case .rapport: return "Ex. : Projet Annalyse"
        case .autre: return "Titre du document"
        }
    }
}

// MARK: - Formulaire

final class NewLatexDocForm: ObservableObject {
    static let shared = NewLatexDocForm()
    private let d = UserDefaults.standard

    @Published var show = false
    @Published var kind = LatexDocKind(rawValue: UserDefaults.standard.string(forKey: "latexdoc.kind") ?? "") ?? .td {
        didSet { d.set(kind.rawValue, forKey: "latexdoc.kind"); refreshNumber() }
    }
    /// id (chemin) de la matière de « Mes cours », ou "" pour une matière saisie à la main
    @Published var courseID = "" { didSet { if courseID != "" { matiere = courseName }; refreshNumber() } }
    @Published var matiere = UserDefaults.standard.string(forKey: "latexdoc.matiere") ?? ""
    @Published var number = 1
    @Published var title = ""
    @Published var author = UserProfile.firstName.isEmpty ? NSFullUserName() : UserProfile.firstName
    @Published var formation = UserDefaults.standard.string(forKey: "latexdoc.formation") ?? "Licence 1 Informatique"
    @Published var enseignant = ""
    @Published var objectif = ""
    @Published var corrige = UserDefaults.standard.object(forKey: "latexdoc.corrige") as? Bool ?? true {
        didSet { d.set(corrige, forKey: "latexdoc.corrige") }
    }
    @Published var language = UserDefaults.standard.string(forKey: "latexdoc.lang") ?? "C" {
        didSet { d.set(language, forKey: "latexdoc.lang") }
    }
    @Published var week = Date()
    @Published var testCorrige = false
    @Published var restituer = UserDefaults.standard.object(forKey: "latexdoc.test.r") as? Int ?? 2 {
        didSet { d.set(restituer, forKey: "latexdoc.test.r") }
    }
    @Published var calculer = UserDefaults.standard.object(forKey: "latexdoc.test.c") as? Int ?? 3 {
        didSet { d.set(calculer, forKey: "latexdoc.test.c") }
    }
    @Published var bareme = UserDefaults.standard.object(forKey: "latexdoc.test.b") as? Int ?? 5 {
        didSet { d.set(bareme, forKey: "latexdoc.test.b") }
    }
    @Published var inCourseFolder = UserDefaults.standard.object(forKey: "latexdoc.incourse") as? Bool ?? true {
        didSet { d.set(inCourseFolder, forKey: "latexdoc.incourse") }
    }

    static let languages = ["C", "C++", "Python", "Java", "bash", "SQL", "HTML", "Aucun"]

    var course: Course? { CoursesStore.shared.courses.first { $0.id == courseID } }
    var courseName: String { course.map { CoursesStore.shared.name($0) } ?? matiere }

    /// Ouvre la feuille, en devinant la matière (cours en ce moment, sinon dernière utilisée).
    func present() {
        author = UserProfile.firstName.isEmpty ? NSFullUserName() : UserProfile.firstName
        title = ""; objectif = ""; enseignant = ""
        let store = CoursesStore.shared
        let last = d.string(forKey: "latexdoc.course") ?? ""
        if let now = store.now?.course {
            courseID = now.id
        } else if store.courses.contains(where: { $0.id == last }) {
            courseID = last
        } else if !store.courses.contains(where: { $0.id == courseID }) {
            courseID = ""
        }
        week = Self.defaultWeek()
        refreshNumber()
        show = true
    }

    func refreshNumber() {
        if let c = course, kind.numbered { number = c.nextNumber(kind.courseKind) } else if number < 1 { number = 1 }
    }

    /// Lundi de la semaine (celle qui vient si on est le week-end).
    static func monday(of date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    static func defaultWeek() -> Date {
        let cal = Calendar(identifier: .gregorian)
        let wd = cal.component(.weekday, from: Date())          // 1 = dimanche, 7 = samedi
        let base = (wd == 1 || wd == 7) ? cal.date(byAdding: .day, value: 2, to: Date()) ?? Date() : Date()
        return monday(of: base)
    }

    static func weekLabel(_ d: Date, format: String = "dd/MM") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = format
        return f.string(from: monday(of: d))
    }

    static var academicYear: String {
        let cal = Calendar.current, now = Date()
        let y = cal.component(.year, from: now)
        return cal.component(.month, from: now) >= 8 ? "\(y)--\(y + 1)" : "\(y - 1)--\(y)"
    }

    /// Titre affiché : « TD 4 -- Limites et continuité »
    var fullTitle: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if kind == .test { return "Test de connaissances" }
        guard kind.numbered else { return t.isEmpty ? (kind == .rapport ? "Rapport" : "Sans titre") : t }
        let head = kind == .cours ? "Chapitre \(number)" : "\(kind.title) \(number)"
        return t.isEmpty ? head : head + " -- " + t
    }

    /// Dossier + fichier : Analyse 1/TDs/TD4/TD4.tex, sinon Documents/Toolbox LaTeX/<titre>/<titre>.tex
    func destination() -> URL {
        let base: URL
        let name: String
        if kind == .test {
            name = "Test-" + Self.weekLabel(week, format: "yyyy-MM-dd")
            if inCourseFolder, let c = course {
                base = c.url.appendingPathComponent("Tests", isDirectory: true)
            } else {
                base = LatexModel.draftsFolder.appendingPathComponent("Tests hebdo", isDirectory: true)
            }
        } else if inCourseFolder, let c = course {
            let kindDir = c.folder(for: kind.courseKind)
            if kind.numbered {
                name = "\(kind.courseKind.sessionPrefix)\(number)"
                base = kindDir.appendingPathComponent(kind == .cours ? "Chapitre \(number)" : name, isDirectory: true)
            } else {
                name = Self.slug(title.isEmpty ? kind.title : title)
                base = kindDir.appendingPathComponent(name, isDirectory: true)
            }
        } else {
            let label = kind.numbered ? [courseName, "\(kind.numberLabel) \(number)"].filter { !$0.isEmpty }.joined(separator: " ")
                : (title.isEmpty ? (kind == .autre ? "Sans titre" : kind.title) : title)
            name = Self.slug(label)
            base = LatexModel.draftsFolder.appendingPathComponent(label.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        }
        let dir = FileManager.default.fileExists(atPath: base.appendingPathComponent(name + ".tex").path) ? FileUtils.unique(base) : base
        return dir.appendingPathComponent(name + ".tex")
    }

    static func slug(_ s: String) -> String {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return f.isEmpty ? "document" : f
    }

    func remember() {
        d.set(courseID, forKey: "latexdoc.course")
        d.set(matiere, forKey: "latexdoc.matiere")
        d.set(formation, forKey: "latexdoc.formation")
    }

    var values: LatexDocTemplates.Values {
        LatexDocTemplates.Values(kind: kind, matiere: courseName, number: number, theme: title, fullTitle: fullTitle,
                                 author: author, formation: formation, enseignant: enseignant, objectif: objectif,
                                 annee: Self.academicYear, corrige: kind == .test ? testCorrige : corrige, language: language,
                                 week: Self.weekLabel(week), restituer: restituer, calculer: calculer, bareme: bareme)
    }
}

// MARK: - Modèles

enum LatexDocTemplates {
    struct Values {
        var kind: LatexDocKind
        var matiere: String
        var number: Int
        var theme: String
        var fullTitle: String
        var author: String
        var formation: String
        var enseignant: String
        var objectif: String
        var annee: String
        var corrige: Bool
        var language: String
        var week: String = ""
        var restituer: Int = 2
        var calculer: Int = 3
        var bareme: Int = 5
    }

    /// Échappe le texte saisi (& % # _ $ …) pour LaTeX.
    static func esc(_ s: String) -> String {
        var out = ""
        for ch in s.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "&", "%", "#", "_", "$", "{", "}": out += "\\" + String(ch)
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            default: out.append(ch)
            }
        }
        return out
    }

    static var monthYear: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "LLLL yyyy"
        let s = f.string(from: Date())
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM/yyyy"
        return f.string(from: Date())
    }

    static func lstLanguage(_ l: String) -> String? {
        switch l {
        case "C": return "C"
        case "C++": return "[ISO]C++"
        case "Python": return "Python"
        case "Java": return "Java"
        case "bash": return "bash"
        case "SQL": return "SQL"
        case "HTML": return "HTML"
        default: return nil
        }
    }

    // MARK: Préambule commun (repris d'annales.cls)

    static func preamble(cours: Bool, fancy: Bool, v: Values, lang: String?) -> String {
        let mat = esc(v.matiere.isEmpty ? "Matière" : v.matiere)
        let headers: String
        if !fancy {
            headers = "\\pagestyle{plain}"
        } else if cours {
            headers = #"""
            \pagestyle{fancy}
            \fancyhf{}
            \renewcommand{\headrulewidth}{0.4pt}
            \fancyhead[L]{\small \#(mat)}
            \fancyhead[R]{\small\nouppercase{\leftmark}}
            \fancyfoot[C]{\small\thepage}
            \fancypagestyle{plain}{\fancyhf{}\fancyfoot[C]{\small\thepage}\renewcommand{\headrulewidth}{0pt}}
            """#
        } else {
            headers = #"""
            \pagestyle{fancy}
            \fancyhf{}
            \renewcommand{\headrulewidth}{0.4pt}
            \renewcommand{\footrulewidth}{0.4pt}
            \fancyhead[L]{\small \#(esc(v.formation))}
            \fancyhead[R]{\small CERI -- Avignon Université}
            \fancyfoot[L]{\small \#(mat)}
            \fancyfoot[R]{\small Page \thepage/\pageref*{LastPage}}
            """#
        }
        let lstLang = lang.map { "  language=\($0),\n" } ?? ""
        return #"""
        % !TEX program = pdflatex
        % Modèle Toolbox, d'après les modèles d'Annalyse (annales.cls)
        \documentclass[a4paper,11pt]{article}

        % ---------- Polices et langue (pdfLaTeX, XeLaTeX ou LuaLaTeX) ----------
        \usepackage{iftex}
        \ifPDFTeX
          \usepackage[utf8]{inputenc}
          \usepackage[T1]{fontenc}
          \usepackage{lmodern}
        \else
          \usepackage{fontspec}
        \fi
        \usepackage[french]{babel}

        % ---------- Paquets ----------
        \usepackage{amsmath,amssymb}
        \usepackage[margin=2.5cm]{geometry}
        \usepackage{fancyhdr}
        \usepackage{lastpage}
        \usepackage{enumitem}
        \usepackage{xcolor}
        \usepackage{graphicx}
        \usepackage{array,booktabs,tabularx}
        \usepackage{listings}
        \usepackage{tikz}
        \usepackage[most]{tcolorbox}
        \usepackage{csquotes}
        \usepackage[hidelinks,bookmarksnumbered]{hyperref}

        \setlength{\headheight}{14pt}
        \setlength{\parindent}{0pt}
        \setlength{\parskip}{0.45em}
        \setlength{\emergencystretch}{3em}
        \clubpenalty=10000
        \widowpenalty=10000
        \setlist{itemsep=2pt, topsep=3pt}

        % Raccourcis
        \newcommand{\N}{\mathbb{N}}
        \newcommand{\Z}{\mathbb{Z}}
        \newcommand{\Q}{\mathbb{Q}}
        \newcommand{\R}{\mathbb{R}}
        \newcommand{\C}{\mathbb{C}}
        \newcommand{\code}[1]{\texttt{#1}}

        % ---------- Couleurs ----------
        \definecolor{annbleu}{HTML}{1F4E79}
        \definecolor{annbleuclair}{HTML}{E8F0F8}
        \definecolor{annvert}{HTML}{2E7D32}
        \definecolor{annvertclair}{HTML}{EAF5EA}
        \definecolor{annorange}{HTML}{B85C00}
        \definecolor{annorangeclair}{HTML}{FDF1E4}
        \definecolor{anngris}{HTML}{F5F5F5}
        \definecolor{anngrisfonce}{HTML}{555555}

        % ---------- En-têtes et pieds de page ----------
        \#(headers)

        % ---------- Code source ----------
        \lstdefinestyle{annales}{
        \#(lstLang)  basicstyle=\ttfamily\small,
          backgroundcolor=\color{anngris},
          frame=single, rulecolor=\color{black!25},
          keywordstyle=\color{annbleu}\bfseries,
          commentstyle=\color{annvert}\itshape,
          stringstyle=\color{annorange},
          showstringspaces=false, breaklines=true, tabsize=4,
          columns=fullflexible, keepspaces=true,
          xleftmargin=3pt, xrightmargin=3pt, framesep=4pt,
          literate=
            {é}{{\'e}}1 {è}{{\`e}}1 {ê}{{\^e}}1 {à}{{\`a}}1 {â}{{\^a}}1
            {ù}{{\`u}}1 {û}{{\^u}}1 {î}{{\^i}}1 {ô}{{\^o}}1 {ç}{{\c c}}1
            {É}{{\'E}}1 {À}{{\`A}}1 {«}{{\guillemotleft}}1 {»}{{\guillemotright}}1
        }
        \lstset{style=annales}
        """#
    }

    /// Encadrés de cours (colorés) : definition, theoreme, propriete, methode, attention, exemple, remarque, rappel.
    static let courseBoxes = #"""
    % ---------- Encadrés de cours ----------
    \tcbset{
      annbase/.style={
        enhanced, breakable, boxrule=0.6pt, arc=1.5mm,
        left=6pt, right=6pt, top=6pt, bottom=4pt,
        before skip=8pt, after skip=8pt,
        fonttitle=\bfseries\sffamily\small, coltitle=white,
        attach boxed title to top left={yshift=-2mm, xshift=3mm},
        boxed title style={boxrule=0pt, arc=0pt, outer arc=0pt}}
    }
    \newcommand\boitecours[4]{% nom, couleur cadre, couleur fond, titre
      \newtcolorbox{#1}[1][]{annbase, colframe=#2, colback=#3,
        boxed title style={colback=#2},
        title={#4\ifx\relax##1\relax\else\ : ##1\fi}}}
    \boitecours{definition}{annbleu}{annbleuclair}{Définition}
    \boitecours{theoreme}{annvert}{annvertclair}{Théorème}
    \boitecours{propriete}{annvert}{annvertclair}{Propriété}
    \boitecours{methode}{annorange}{annorangeclair}{Méthode}
    \boitecours{attention}{annorange}{annorangeclair}{Attention}
    \boitecours{exemple}{anngrisfonce}{white}{Exemple}
    \boitecours{remarque}{anngrisfonce}{white}{Remarque}
    \boitecours{rappel}{anngrisfonce}{white}{Rappel}
    """#

    /// Exercices et questions numérotés automatiquement (comme annales.cls), corrections masquables.
    static func exerciseEnvs(corrige: Bool, reponse: Bool) -> String {
        var s = #"""
        % ---------- Exercices et questions ----------
        % \begin{exercice}[5 points][Titre facultatif] ... \end{exercice}
        % \begin{question}[2 points] ... \end{question}   -> (1), (2)... automatiques
        \newcounter{exercice}
        \newcounter{question}[exercice]
        \newcommand\points[1]{\ifx\relax#1\relax\else\ (#1)\fi}
        \NewDocumentEnvironment{exercice}{O{} O{}}{%
          \refstepcounter{exercice}\par\addvspace{1.6\bigskipamount}%
          \needspace{5\baselineskip}%
          \noindent{\large\bfseries Exercice \theexercice.}{\bfseries\points{#1}}%
          \ifx\relax#2\relax\else\ \textemdash\ \textit{#2}\fi
          \par\nobreak\smallskip}{\par}
        \NewDocumentEnvironment{question}{O{} O{}}{%
          \refstepcounter{question}\par\addvspace{\medskipamount}%
          \noindent\textbf{(\thequestion)}%
          \ifx\relax#1\relax\else\ \textit{(#1)}\fi
          \ifx\relax#2\relax\else\ \textit{#2.}\fi\ \ignorespaces}{\par}
        \usepackage{needspace}

        % ---------- Corrections ----------
        % Mettre \corrigefalse pour imprimer le sujet seul.
        \newif\ifcorrige
        \#(corrige ? "\\corrigetrue" : "\\corrigefalse")
        \usepackage{comment}
        \ifcorrige
          \specialcomment{correction}{%
            \begin{tcolorbox}[blanker, breakable, left=10pt, top=2pt, bottom=2pt,
              borderline west={0.8pt}{0pt}{annbleu}, before skip=4pt, after skip=6pt]
            \textbf{Correction.}\par}{\end{tcolorbox}}
        \else
          \excludecomment{correction}
        \fi
        """#
        if reponse {
            s += "\n" + #"""

            % ---------- Réponses (toujours visibles) ----------
            \newenvironment{reponse}{%
              \begin{tcolorbox}[enhanced, breakable, colback=annvertclair, colframe=annvert, boxrule=0.5pt,
                arc=1mm, left=8pt, right=6pt, top=4pt, bottom=4pt, before skip=6pt, after skip=6pt]
              \textbf{\color{annvert}Réponse.}\par}{\end{tcolorbox}}
            """#
        }
        return s
    }

    // MARK: Documents

    static func document(_ v: Values) -> String {
        switch v.kind {
        case .td: return td(v)
        case .tp: return tp(v)
        case .cours: return cours(v)
        case .rapport: return rapport(v)
        case .test: return test(v)
        case .autre: return autre(v)
        }
    }

    /// En-tête d'un TD / TP, comme \ann@entetetd.
    static func sheetHeader(_ v: Values, objectif: String) -> String {
        let mat = esc(v.matiere.isEmpty ? "Matière" : v.matiere)
        return #"""
        \begin{center}
          {\LARGE\bfseries \#(esc(v.fullTitle))\par}
          \vspace{0.3em}
          {\large \#(mat) -- Année \#(v.annee)\par}
        \end{center}
        \#(objectif)\par
        \vspace{-0.2em}\noindent\rule{\linewidth}{0.4pt}\par\medskip
        """#
    }

    static func objectifLine(_ v: Values, fallback: String) -> String {
        let o = esc(v.objectif)
        return o.isEmpty ? fallback : o
    }

    static func meta(_ v: Values) -> String {
        var lines = ["% Matière : \(v.matiere.isEmpty ? "?" : v.matiere)", "% Auteur : \(v.author)", "% Créé le \(today) avec Toolbox"]
        if !v.enseignant.isEmpty { lines.append("% Enseignant : \(v.enseignant)") }
        return lines.joined(separator: "\n")
    }

    static func td(_ v: Values) -> String {
        let pre = preamble(cours: false, fancy: true, v: v, lang: nil)
        let obj = objectifLine(v, fallback: "L'objectif de ce TD est de \\dots")
        return #"""
        \#(meta(v))
        \#(pre)

        \#(exerciseEnvs(corrige: v.corrige, reponse: false))

        \hypersetup{pdftitle={\#(esc(v.fullTitle))}, pdfauthor={\#(esc(v.author))}}

        \begin{document}

        \#(sheetHeader(v, objectif: obj))

        \begin{exercice}
        Texte d'introduction commun aux questions.
        \begin{question}
        Première question. Une formule : $\displaystyle\lim_{x\to +\infty}\frac{1}{x}=0$.
        \end{question}
        \begin{correction}
        Réponse rédigée (visible seulement avec \verb|\corrigetrue|).
        \end{correction}
        \begin{question}
        Calculer, si elles existent, les limites suivantes :
        \begin{enumerate}[label=(\alph*), itemsep=4pt]
          \item $\displaystyle\lim_{x\to 0}\frac{\sin x}{x}$
          \item $\displaystyle\lim_{x\to +\infty}\frac{x^2+1}{x-1}$
        \end{enumerate}
        \end{question}
        \end{exercice}

        \begin{exercice}[][Titre facultatif]
        \begin{question}
        \end{question}
        \end{exercice}

        \end{document}
        """#
    }

    static func tp(_ v: Values) -> String {
        let lang = lstLanguage(v.language)
        let pre = preamble(cours: false, fancy: true, v: v, lang: lang)
        let obj = objectifLine(v, fallback: "Objectifs du TP : \\dots")
        let ext: String
        let sample: String
        let build: String
        switch v.language {
        case "C++":
            ext = "cpp"
            sample = "#include <iostream>\n\nint main() {\n    std::cout << \"Bonjour !\" << std::endl; // affiche un message\n    return 0;\n}"
            build = "g++ -Wall -Wextra -std=c++17 main.cpp -o main\n./main"
        case "Python":
            ext = "py"
            sample = "def main():\n    print(\"Bonjour !\")  # affiche un message\n\n\nif __name__ == \"__main__\":\n    main()"
            build = "python3 main.py"
        case "Java":
            ext = "java"
            sample = "public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"Bonjour !\"); // affiche un message\n    }\n}"
            build = "javac Main.java\njava Main"
        case "bash":
            ext = "sh"
            sample = "#!/bin/bash\n# affiche un message\necho \"Bonjour !\""
            build = "chmod +x script.sh\n./script.sh"
        case "SQL":
            ext = "sql"
            sample = "-- liste des étudiants\nSELECT nom, prenom\nFROM etudiant\nWHERE annee = 1;"
            build = "sqlite3 base.db < requetes.sql"
        case "HTML":
            ext = "html"
            sample = "<!DOCTYPE html>\n<html lang=\"fr\">\n  <body>\n    <p>Bonjour !</p>\n  </body>\n</html>"
            build = "open index.html"
        case "Aucun":
            ext = ""
            sample = "Code ou sortie du programme"
            build = ""
        default:
            ext = "c"
            sample = "#include <stdio.h>\n\nint main(void) {\n    printf(\"Bonjour !\\n\"); // affiche un message\n    return 0;\n}"
            build = "gcc -Wall -Wextra -std=c11 main.c -o main\n./main"
        }
        let buildBlock = build.isEmpty ? "" : #"""

        \section*{Compilation et exécution}
        \begin{lstlisting}[language=bash]
        \#(build)
        \end{lstlisting}
        """#
        let fileNote = ext.isEmpty ? "" : " (fichier \\code{main.\(ext)})"
        return #"""
        \#(meta(v))
        \#(pre)

        \#(exerciseEnvs(corrige: v.corrige, reponse: true))

        \hypersetup{pdftitle={\#(esc(v.fullTitle))}, pdfauthor={\#(esc(v.author))}}

        \begin{document}

        \#(sheetHeader(v, objectif: obj))

        \begin{tcolorbox}[colback=annbleuclair, colframe=annbleu, boxrule=0.6pt, arc=2pt,
          left=6pt, right=6pt, top=4pt, bottom=4pt, fonttitle=\bfseries, title=À rendre]
        \begin{itemize}[leftmargin=1.2em]
          \item Les sources commentées\#(fileNote) ;
          \item ce compte rendu (PDF) ;
          \item date limite : \dots
        \end{itemize}
        \end{tcolorbox}
        \#(buildBlock)

        \begin{exercice}[][Prise en main]
        \begin{question}
        Écrire un programme qui affiche un message.
        \end{question}
        \begin{reponse}
        Explication de la démarche, puis le code :
        \begin{lstlisting}
        \#(sample)
        \end{lstlisting}
        \end{reponse}
        \end{exercice}

        \begin{exercice}
        \begin{question}
        \end{question}
        \begin{reponse}
        \end{reponse}
        \end{exercice}

        \section*{Bilan}
        Ce qui fonctionne, difficultés rencontrées, pistes d'amélioration.

        \end{document}
        """#
    }

    static func cours(_ v: Values) -> String {
        let pre = preamble(cours: true, fancy: true, v: v, lang: nil)
        let mat = esc(v.matiere.isEmpty ? "Matière" : v.matiere)
        let theme = esc(v.theme)
        let subtitle = theme.isEmpty ? "Chapitre \(v.number)" : "Chapitre \(v.number) -- \(theme)"
        let prof = v.enseignant.isEmpty ? "" : "{\\large \(esc(v.enseignant))\\par}\\vspace{0.3em}\n    "
        let section = theme.isEmpty ? "Première partie" : theme
        return #"""
        \#(meta(v))
        \#(pre)

        \#(courseBoxes)

        % ---------- Titres en bleu ----------
        \makeatletter
        \renewcommand\section{\@startsection{section}{1}{\z@}%
          {-3.2ex \@plus -1ex \@minus -.2ex}{1.6ex \@plus .2ex}{\normalfont\Large\bfseries\color{annbleu}}}
        \renewcommand\subsection{\@startsection{subsection}{2}{\z@}%
          {-2.6ex \@plus -1ex \@minus -.2ex}{1.0ex \@plus .2ex}{\normalfont\large\bfseries\color{annbleu}}}
        \makeatother

        \hypersetup{pdftitle={\#(mat) -- \#(subtitle)}, pdfauthor={\#(esc(v.author))}}

        \begin{document}

        % ---------- Page de titre ----------
        \begin{titlepage}
          \centering
          \vspace*{3cm}
          {\color{annbleu}\rule{\linewidth}{1pt}}\par\vspace{0.8em}
          {\Huge\bfseries\color{annbleu}\#(mat)\par}\vspace{0.6em}
          {\Large \#(subtitle)\par}
          \vspace{0.4em}{\color{annbleu}\rule{\linewidth}{1pt}}\par
          \vspace{2em}
          {\large \#(esc(v.formation))\par}
          {\large Année \#(v.annee)\par}
          \vfill
          \#(prof){\large \#(esc(v.author))\par}\vspace{0.3em}
          {CERI -- Avignon Université\par}
        \end{titlepage}
        \pagenumbering{roman}
        \tableofcontents
        \clearpage
        \pagenumbering{arabic}

        \section{\#(section)}

        \subsection{Première notion}

        \begin{definition}[nom de la notion]
        Énoncé de la définition. Par exemple : $|x| = \max(x,-x)$.
        \end{definition}

        \begin{exemple}
        $E(2{,}85) = 2$ ; $E(-3{,}5) = -4$.
        \end{exemple}

        \begin{theoreme}[nom du théorème]
        \[ \forall x \in \R, \; \exists n \in \N, \; n > x. \]
        \end{theoreme}

        \begin{propriete}
        \end{propriete}

        \begin{methode}[comment faire]
        \end{methode}

        \begin{remarque}
        \end{remarque}

        \begin{attention}
        Piège classique à éviter.
        \end{attention}

        \subsection{Deuxième notion}

        \end{document}
        """#
    }

    static func rapport(_ v: Values) -> String {
        let pre = preamble(cours: false, fancy: false, v: v, lang: nil)
        let title = esc(v.fullTitle)
        let sub = esc(v.objectif)
        let mat = esc(v.matiere)
        let subtitleLine = sub.isEmpty ? "{\\Large Sous-titre du rapport}\\\\[0.4em]" : "{\\Large \(sub)}\\\\[0.4em]"
        let matLine = mat.isEmpty ? "" : "{\\large \(mat)}\\\\[4em]"
        let prof = v.enseignant.isEmpty ? "" : "Encadré par \(esc(v.enseignant))\\\\[0.3em]\n"
        return #"""
        \#(meta(v))
        \#(pre)
        \usepackage{titlesec}
        \usetikzlibrary{arrows.meta,positioning}

        % ---------- Table des matières ----------
        \makeatletter
        \renewcommand*\l@subsection{\@dottedtocline{2}{1.5em}{2.8em}}
        \makeatother
        \setcounter{tocdepth}{2}

        % ---------- Titres ----------
        \titleformat{\section}{\Large\bfseries\color{annbleu}}{\thesection}{0.8em}{}[\vspace{-0.4em}\textcolor{annbleu}{\rule{\linewidth}{0.6pt}}]
        \titleformat{\subsection}{\large\bfseries\color{annbleu}}{\thesubsection}{0.7em}{}

        % ---------- En-tête ----------
        \pagestyle{fancy}
        \fancyhf{}
        \fancyhead[L]{\small\color{anngrisfonce}\#(title)}
        \fancyhead[R]{\small\color{anngrisfonce}\#(esc(v.author))}
        \fancyfoot[C]{\small\thepage}
        \renewcommand{\headrulewidth}{0.3pt}

        % ---------- Encadrés ----------
        \newtcolorbox{objectif}{colback=annbleuclair,colframe=annbleu,boxrule=0.6pt,arc=2pt,
          left=6pt,right=6pt,top=4pt,bottom=4pt,fonttitle=\bfseries,title=Objectif}
        \newtcolorbox{livrable}{colback=annvertclair,colframe=annvert,boxrule=0.6pt,arc=2pt,
          left=6pt,right=6pt,top=4pt,bottom=4pt,fonttitle=\bfseries,title=Livrable \& critère de fin}
        \newtcolorbox{attention}{colback=annorangeclair,colframe=annorange,boxrule=0.6pt,arc=2pt,
          left=6pt,right=6pt,top=4pt,bottom=4pt,fonttitle=\bfseries,title=Attention}

        \hypersetup{pdftitle={\#(title)}, pdfauthor={\#(esc(v.author))}}

        \begin{document}

        % =====================================================================
        \begin{titlepage}
        \centering
        \vspace*{3cm}
        {\color{annbleu}\rule{\linewidth}{1pt}}\\[0.8em]
        {\Huge\bfseries\color{annbleu} \#(title)}\\[0.6em]
        \#(subtitleLine)
        {\color{annbleu}\rule{\linewidth}{1pt}}\\[2em]
        \#(matLine)
        \vfill
        {\large \#(esc(v.author))}\\[0.3em]
        \#(prof)\#(esc(v.formation)), Avignon Université\\[0.3em]
        \#(monthYear)
        \end{titlepage}

        \tableofcontents
        \newpage

        % =====================================================================
        \section{Contexte et objectifs}

        Présentation du contexte et du problème.

        \begin{objectif}
        Ce que le projet doit permettre de faire.
        \end{objectif}

        \section{Analyse}

        \subsection{Besoins}
        \begin{itemize}[leftmargin=1.5em]
          \item Premier besoin ;
          \item deuxième besoin.
        \end{itemize}

        \section{Réalisation}

        \begin{center}
        \renewcommand{\arraystretch}{1.35}
        \begin{tabularx}{\linewidth}{@{}p{3.6cm}Xp{2.2cm}@{}}
        \toprule
        \textbf{Étape} & \textbf{Description} & \textbf{État} \\
        \midrule
        \textbf{1. Conception} & \dots & Fait \\
        \textbf{2. Développement} & \dots & En cours \\
        \bottomrule
        \end{tabularx}
        \end{center}

        \begin{lstlisting}[language=Python]
        def main():
            print("Bonjour !")  # exemple de code
        \end{lstlisting}

        \begin{livrable}
        Ce qui est rendu et comment on sait que c'est terminé.
        \end{livrable}

        \section{Résultats}

        \begin{attention}
        Limites connues.
        \end{attention}

        \section{Conclusion et perspectives}

        \end{document}
        """#
    }

    // MARK: Test hebdo (d'après tes « Test de connaissances » T1 / T3)

    static let restituerExemples = [
        "Donnez la définition EXACTE de \\dots{} :",
        "Rappelez \\dots{} :",
        "Énoncez le théorème \\dots{} :",
        "Donnez la formule générale de \\dots{} :",
    ]
    static let calculerExemples = [
        "Calculez la limite suivante : $\\displaystyle\\lim_{x\\to 0}\\frac{e^{3x+2}-e^{2}}{x}$",
        "Déterminez par le calcul la dérivée de l'application suivante : $g : x \\mapsto \\dfrac{2}{5(2x-1)^{4}}$",
        "Résolvez l'équation / inéquation suivante : $\\dots$",
        "Démontrez \\dots{} :",
        "En langage mathématique, donnez la négation de la proposition suivante : \\[ P \\Rightarrow (Q \\wedge R) \\]",
    ]

    static func questions(_ list: [String], count: Int, space: String) -> String {
        guard count > 0 else { return "" }
        let items = (0..<count).map { i -> String in
            "  \\item " + list[i % list.count] + "\n  \\reponse[\(space)]{Réponse attendue.}"
        }
        return "\\begin{enumerate}\n" + items.joined(separator: "\n\n") + "\n\\end{enumerate}"
    }

    static func test(_ v: Values) -> String {
        let mat = esc(v.matiere)
        let subtitle = mat.isEmpty ? "Semaine du \\semaine" : "\\matiere\\ -- Semaine du \\semaine"
        let total = max(1, v.restituer + v.calculer)
        let space = total <= 4 ? "4cm" : total <= 5 ? "3cm" : "2.2cm"
        var parts: [String] = []
        if v.restituer > 0 {
            parts.append("\\partie{I / Restituer}\n" + questions(restituerExemples, count: v.restituer, space: space))
        }
        if v.calculer > 0 {
            let num = v.restituer > 0 ? "II" : "I"
            parts.append("\\partie{\(num) / Calculer}\n" + questions(calculerExemples, count: v.calculer, space: space))
        }
        return #"""
        \#(meta(v))
        % !TEX program = pdflatex
        % Test de connaissances hebdomadaire (modèle Toolbox, d'après T1 / T3)
        \documentclass[a4paper,12pt]{article}

        \usepackage{iftex}
        \ifPDFTeX
          \usepackage[utf8]{inputenc}
          \usepackage[T1]{fontenc}
          \usepackage{lmodern}               % maths nettes à toutes les tailles
          \usepackage[scaled=0.95]{helvet}   % proche de l'Helvetica Neue des tests faits avec Pages
        \else
          \usepackage{fontspec}
          \IfFontExistsTF{Helvetica Neue}{\setsansfont{Helvetica Neue}}{}
        \fi
        \renewcommand{\familydefault}{\sfdefault}
        \usepackage[french]{babel}
        \usepackage{amsmath,amssymb}
        \usepackage[a4paper,margin=1.8cm]{geometry}
        \usepackage{enumitem}
        \usepackage{xcolor}
        \pagestyle{empty}

        % ---------- À modifier chaque semaine ----------
        \newcommand{\semaine}{\#(v.week)}
        \newcommand{\matiere}{\#(mat.isEmpty ? "" : mat)}
        \newcommand{\bareme}{\#(v.bareme)}

        % \corrigetrue : les réponses s'affichent en bleu à la place des blancs
        \newif\ifcorrige
        \#(v.corrige ? "\\corrigetrue" : "\\corrigefalse")

        % ---------- Mise en page (gros caractères) ----------
        \AtBeginDocument{\fontsize{14}{19}\selectfont}
        \setlist[enumerate]{label=\arabic*., leftmargin=1.6em, itemsep=0.6em}
        \newcommand{\partie}[1]{\par\bigskip{\fontsize{18}{22}\selectfont\bfseries\itshape\underline{#1 :}}\par\medskip}
        % \reponse[espace]{corrigé}
        \newcommand{\reponse}[2][3.5cm]{%
          \ifcorrige\par{\color{blue!60!black}#2}\par\medskip\else\par\vspace{#1}\fi}

        \begin{document}

        \noindent\fbox{\parbox{\dimexpr\linewidth-2\fboxsep-2\fboxrule}{\centering
          \vspace{0.4em}
          {\fontsize{28}{32}\selectfont\bfseries\itshape Test de connaissances\par}
          \vspace{0.3em}
          {\fontsize{17}{20}\selectfont\itshape \#(subtitle)\par}
          \vspace{0.4em}}}

        \#(parts.joined(separator: "\n\n"))

        \vfill
        \hfill{\fontsize{18}{22}\selectfont Note : \hspace{1.5cm}/ \bareme}

        \end{document}
        """#
    }

    static func autre(_ v: Values) -> String {
        let pre = preamble(cours: false, fancy: false, v: v, lang: nil)
        return #"""
        \#(meta(v))
        \#(pre)

        \title{\#(esc(v.fullTitle))}
        \author{\#(esc(v.author))}
        \date{\today}

        \begin{document}
        \maketitle

        Ton texte ici. Une formule : $\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$.

        \end{document}
        """#
    }
}

// MARK: - Création

extension LatexModel {
    /// Crée le fichier depuis le formulaire, l'ouvre dans l'éditeur, place le curseur sur le premier contenu et compile.
    func createTypedDocument(_ form: NewLatexDocForm) {
        let fm = FileManager.default
        let url = form.destination()
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = LatexDocTemplates.document(form.values)
            try text.write(to: url, atomically: true, encoding: .utf8)
            LatexDocsStore.shared.register(url, kind: form.kind.rawValue,
                                           title: form.kind == .test ? "Test – semaine du \(NewLatexDocForm.weekLabel(form.week))" : form.fullTitle.replacingOccurrences(of: "--", with: "–"),
                                           matiere: form.kind == .autre ? "" : form.courseName)
            form.remember()
            form.show = false
            open(url)
            let lines = text.components(separatedBy: "\n")
            let target = lines.firstIndex { $0.hasPrefix("\\begin{exercice}") || $0.hasPrefix("\\partie") || $0.hasPrefix("\\section{") || $0.hasPrefix("Ton texte") }
                ?? lines.firstIndex { $0.hasPrefix("\\begin{document}") } ?? 0
            send(.goTo(line: target + 1))
            compile()
            if form.inCourseFolder, form.course != nil { CoursesStore.shared.scan() }
            status = .ok("\(form.kind.title) créé : \(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)")
        } catch {
            status = .err(error)
        }
    }
}

// MARK: - Feuille « Nouveau document »

struct NewLatexDocSheet: View {
    @ObservedObject var model: LatexModel
    @ObservedObject var f = NewLatexDocForm.shared
    @ObservedObject var courses = CoursesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nouveau document LaTeX").font(.title2.bold())
            HStack(spacing: 10) {
                ForEach(LatexDocKind.allCases) { k in kindButton(k) }
            }
            Text(f.kind.summary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                if f.kind != .autre {
                    Picker("Matière", selection: $f.courseID) {
                        Text("Autre / aucune").tag("")
                        if !courses.courses.isEmpty { Divider() }
                        ForEach(courses.courses) { c in Text(courses.name(c)).tag(c.id) }
                    }
                    if f.courseID.isEmpty {
                        TextField("Nom de la matière", text: $f.matiere, prompt: Text("Ex. : Analyse 1"))
                    }
                }
                if f.kind.numbered {
                    Stepper(value: $f.number, in: 1...99) {
                        Text("\(f.kind.numberLabel) \(f.number)").monospacedDigit()
                    }
                }
                if f.kind == .test {
                    DatePicker("Semaine du", selection: $f.week, displayedComponents: .date)
                    Text("Lundi \(NewLatexDocForm.weekLabel(f.week, format: "d MMMM"))").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $f.restituer, in: 0...6) { Text("I / Restituer : \(f.restituer) question\(f.restituer > 1 ? "s" : "")") }
                    Stepper(value: $f.calculer, in: 0...6) { Text("II / Calculer : \(f.calculer) question\(f.calculer > 1 ? "s" : "")") }
                    Stepper(value: $f.bareme, in: 1...40) { Text("Noté sur \(f.bareme)") }
                    Toggle("Version corrigée (réponses à la place des blancs)", isOn: $f.testCorrige)
                } else {
                    TextField(f.kind.numbered ? "Thème" : "Titre", text: $f.title, prompt: Text(f.kind.titlePrompt))
                }
                if f.kind == .td || f.kind == .tp {
                    TextField("Objectif", text: $f.objectif, prompt: Text("Facultatif : une phrase sous le titre"))
                }
                if f.kind == .rapport {
                    TextField("Sous-titre", text: $f.objectif, prompt: Text("Facultatif"))
                }
                if f.kind == .tp {
                    Picker("Langage du code", selection: $f.language) {
                        ForEach(NewLatexDocForm.languages, id: \.self) { Text($0).tag($0) }
                    }
                }
                if f.kind == .td || f.kind == .tp {
                    Toggle("Afficher les corrections (\\corrigetrue)", isOn: $f.corrige)
                }
                if f.kind != .test { TextField("Auteur", text: $f.author) }
                if f.kind != .autre && f.kind != .test {
                    TextField("Formation", text: $f.formation)
                    if f.kind == .cours || f.kind == .rapport {
                        TextField(f.kind == .rapport ? "Encadrant" : "Enseignant", text: $f.enseignant, prompt: Text("Facultatif"))
                    }
                }
                if f.course != nil {
                    Toggle("Ranger dans le dossier de la matière", isOn: $f.inCourseFolder)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 260)

            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(displayPath(f.destination())).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            HStack {
                Button("Projet depuis un ancien modèle…") { f.show = false; model.showNewProject = true }
                    .buttonStyle(.link)
                Spacer()
                Button("Annuler") { f.show = false }
                    .keyboardShortcut(.cancelAction)
                Button("Créer") { model.createTypedDocument(f) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func kindButton(_ k: LatexDocKind) -> some View {
        let selected = f.kind == k
        return Button { f.kind = k } label: {
            VStack(spacing: 6) {
                Image(systemName: k.icon).font(.title2)
                Text(k.title).font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(selected ? Color.white : k.color)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? k.color : k.color.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(k.summary)
    }

    private func displayPath(_ u: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return u.path.hasPrefix(home) ? "~" + u.path.dropFirst(home.count) : u.path
    }
}

/// Porte la feuille « Nouveau document » (séparée des autres .sheet de la page LaTeX).
struct NewDocSheetHost: View {
    @ObservedObject var model: LatexModel
    @ObservedObject var f = NewLatexDocForm.shared

    var body: some View {
        Color.clear
            .sheet(isPresented: $f.show) { NewLatexDocSheet(model: model) }
    }
}
