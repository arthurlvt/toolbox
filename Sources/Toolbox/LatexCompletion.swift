import Foundation

/// Propositions de complétion selon le contexte : \commande, \begin{…}, \ref{…}, \cite{…}…
enum LatexCompletion {

    static let commands: [String] = [
        // structure
        "documentclass", "usepackage", "begin", "end", "title", "author", "date", "maketitle", "tableofcontents",
        "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "appendix", "newpage", "clearpage",
        "label", "ref", "eqref", "pageref", "cite", "footnote", "item", "input", "include", "includegraphics",
        "caption", "centering", "newcommand", "renewcommand", "DeclareMathOperator", "hspace", "vspace", "medskip",
        "bigskip", "smallskip", "noindent", "par", "linewidth", "textwidth", "hline", "toprule", "midrule", "bottomrule",
        "multicolumn", "url", "href",
        // texte
        "textbf", "textit", "emph", "underline", "texttt", "textsc", "textrm", "textsf", "small", "footnotesize",
        "large", "Large", "LARGE", "huge", "today", "ldots", "dots", "quad", "qquad",
        // maths
        "frac", "dfrac", "tfrac", "sqrt", "sum", "prod", "int", "iint", "oint", "lim", "limsup", "liminf", "sup", "inf",
        "max", "min", "infty", "partial", "nabla", "cdot", "cdots", "times", "div", "pm", "mp", "leq", "geq",
        "leqslant", "geqslant", "neq", "approx", "equiv", "sim", "simeq", "propto", "to", "mapsto", "rightarrow",
        "leftarrow", "Rightarrow", "Leftarrow", "Leftrightarrow", "iff", "implies", "forall", "exists", "nexists",
        "in", "notin", "subset", "subseteq", "supset", "cup", "cap", "bigcup", "bigcap", "setminus", "emptyset",
        "varnothing", "mathbb", "mathcal", "mathrm", "mathbf", "mathit", "operatorname", "text", "left", "right",
        "big", "Big", "langle", "rangle", "lfloor", "rfloor", "lceil", "rceil", "overline", "underbrace", "overbrace",
        "vec", "hat", "bar", "tilde", "dot", "ddot", "binom", "log", "ln", "exp", "sin", "cos", "tan", "arcsin",
        "arccos", "arctan", "sinh", "cosh", "tanh", "det", "dim", "ker", "deg", "gcd", "mod", "pmod",
        "alpha", "beta", "gamma", "Gamma", "delta", "Delta", "epsilon", "varepsilon", "zeta", "eta", "theta",
        "Theta", "vartheta", "iota", "kappa", "lambda", "Lambda", "mu", "nu", "xi", "Xi", "pi", "Pi", "rho",
        "sigma", "Sigma", "tau", "upsilon", "phi", "Phi", "varphi", "chi", "psi", "Psi", "omega", "Omega",
        // classe annales
        "matiere", "titre", "consignes", "objectif", "illisible", "code", "dateexamen", "duree", "documents",
    ]

    static let environments: [String] = [
        "itemize", "enumerate", "description", "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "cases", "matrix", "pmatrix", "bmatrix", "vmatrix", "array", "tabular", "table", "figure",
        "center", "flushleft", "flushright", "minipage", "quote", "verbatim", "lstlisting", "proof", "theorem",
        "lemma", "proposition", "corollary", "definition", "remark", "example", "abstract", "thebibliography",
        "tikzpicture", "multicols",
        // classe annales
        "exercice", "exercicebonus", "question", "sousquestion", "bloc", "correction",
    ]

    static let packages: [String] = [
        "amsmath", "amssymb", "amsthm", "mathtools", "graphicx", "geometry", "hyperref", "xcolor", "tikz",
        "babel", "inputenc", "fontenc", "lmodern", "enumitem", "booktabs", "array", "tabularx", "multicol",
        "listings", "fancyhdr", "float", "caption", "subcaption", "siunitx", "tcolorbox", "cleveref", "csquotes",
        "biblatex", "microtype", "lipsum", "pgfplots", "algorithm2e", "minted", "stmaryrd", "esint",
    ]

    /// Nombre d'arguments obligatoires ajoutés {}{} quand on choisit la commande.
    static let argumentCount: [String: Int] = [
        "frac": 2, "dfrac": 2, "tfrac": 2, "binom": 2, "href": 2, "newcommand": 2, "renewcommand": 2,
        "begin": 1, "end": 1, "usepackage": 1, "documentclass": 1, "title": 1, "author": 1, "part": 1, "chapter": 1,
        "section": 1, "subsection": 1, "subsubsection": 1, "paragraph": 1, "label": 1, "ref": 1, "eqref": 1,
        "pageref": 1, "cite": 1, "footnote": 1, "input": 1, "include": 1, "includegraphics": 1, "caption": 1,
        "textbf": 1, "textit": 1, "emph": 1, "underline": 1, "texttt": 1, "textsc": 1, "text": 1, "sqrt": 1,
        "mathbb": 1, "mathcal": 1, "mathrm": 1, "mathbf": 1, "mathit": 1, "operatorname": 1, "overline": 1,
        "underbrace": 1, "overbrace": 1, "vec": 1, "hat": 1, "bar": 1, "tilde": 1, "dot": 1, "url": 1,
        "hspace": 1, "vspace": 1, "matiere": 1, "titre": 1, "consignes": 1, "objectif": 1, "code": 1,
        "dateexamen": 1, "duree": 1, "documents": 1,
    ]

    static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    static func labels(_ text: String) -> [String] { matches(#"\\label\{([^}]+)\}"#, text) }

    static func bibKeys(_ folder: URL?) -> [String] {
        guard let folder = folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "bib" }.flatMap { f -> [String] in
            guard let t = try? String(contentsOf: f, encoding: .utf8) else { return [] }
            return matches(#"@\w+\s*\{\s*([^,\s]+)\s*,"#, t)
        }
    }

    static func projectFiles(_ folder: URL?, graphics: Bool) -> [String] {
        guard let folder = folder,
              let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let exts = graphics ? ["png", "jpg", "jpeg", "pdf", "eps"] : ["tex"]
        let base = folder.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let u as URL in e {
            if out.count > 300 { break }
            guard exts.contains(u.pathExtension.lowercased()) else { continue }
            let path = u.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            var rel = String(path.dropFirst(base.count))
            if !graphics { rel = (rel as NSString).deletingPathExtension }
            if graphics && rel.hasSuffix(".pdf") && FileManager.default.fileExists(atPath: (path as NSString).deletingPathExtension + ".tex") {
                continue   // PDF produit par un .tex voisin, pas une image
            }
            out.append(rel)
        }
        return out
    }

    /// Commande dont on est en train de remplir l'argument : « \begin{ali| » → "begin".
    static func argumentContext(_ before: String) -> String? {
        let tail = String(before.suffix(80))
        guard let r = tail.range(of: #"\\([a-zA-Z]+)\*?(\[[^\]]*\])?\{[^{}\\]*$"#, options: .regularExpression) else { return nil }
        let chunk = tail[r].dropFirst()
        return String(chunk.prefix { $0.isLetter })
    }

    static func candidates(text: String, partialRange: NSRange, folder: URL?) -> [String] {
        let ns = text as NSString
        guard NSMaxRange(partialRange) <= ns.length else { return [] }
        let partial = ns.substring(with: partialRange)
        let before = ns.substring(to: partialRange.location)
        var pool: [String]
        if before.hasSuffix("\\") {
            let own = matches(#"\\(?:newcommand|renewcommand|DeclareMathOperator)\*?\{?\\([a-zA-Z]+)"#, text)
            pool = own + commands
        } else if let cmd = argumentContext(before) {
            switch cmd {
            case "begin", "end":
                pool = matches(#"\\begin\{([^}]+)\}"#, text) + environments
                if cmd == "end", let open = lastUnclosedEnvironment(before) { pool.insert(open, at: 0) }
            case "ref", "eqref", "pageref", "autoref", "cref", "Cref", "vref": pool = labels(text)
            case "cite", "citep", "citet", "parencite", "textcite", "nocite": pool = bibKeys(folder)
            case "usepackage", "RequirePackage": pool = packages
            case "includegraphics": pool = projectFiles(folder, graphics: true)
            case "input", "include", "subfile": pool = projectFiles(folder, graphics: false)
            default: return []
            }
        } else {
            return []
        }
        var seen = Set<String>()
        let lower = partial.lowercased()
        let filtered = pool.filter { c in
            guard !seen.contains(c), c != partial else { return false }
            seen.insert(c)
            return partial.isEmpty || c.lowercased().hasPrefix(lower)
        }
        return Array(filtered.prefix(60))
    }

    /// L'environnement ouvert le plus récemment qui n'est pas encore refermé.
    static func lastUnclosedEnvironment(_ before: String) -> String? {
        var stack: [String] = []
        guard let rx = try? NSRegularExpression(pattern: #"\\(begin|end)\{([^}]+)\}"#) else { return nil }
        let ns = before as NSString
        for m in rx.matches(in: before, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1)), env = ns.substring(with: m.range(at: 2))
            if kind == "begin" { stack.append(env) } else if let i = stack.lastIndex(of: env) { stack.remove(at: i) }
        }
        return stack.last
    }
}

/// Morceaux de LaTeX fabriqués à partir de ce qu'on colle.
enum LatexSnippets {

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&", "%", "$", "#", "_", "{", "}": out += "\\" + String(c)
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            case "\\": out += "\\textbackslash{}"
            default: out.append(c)
            }
        }
        return out
    }

    /// Lignes séparées par des tabulations (copie depuis un tableur) → tabular.
    static func tabular(fromTSV text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, text.count < 40_000 else { return nil }
        let rows = lines.map { $0.components(separatedBy: "\t") }
        let columns = rows[0].count
        guard columns >= 2, rows.allSatisfy({ $0.count == columns }) else { return nil }
        let number = try? NSRegularExpression(pattern: #"^\s*[-+]?[0-9 ]*[.,]?[0-9]+\s*%?\s*$"#)
        func isNumber(_ s: String) -> Bool {
            number?.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        let spec = (0..<columns).map { col -> String in
            let body = rows.dropFirst().map { $0[col] }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return !body.isEmpty && body.allSatisfy(isNumber) ? "r" : "l"
        }.joined(separator: "|")
        var out = "\\begin{center}\n\\begin{tabular}{|\(spec)|}\n  \\hline\n"
        for (i, row) in rows.enumerated() {
            let cells = row.map { escape($0.trimmingCharacters(in: .whitespaces)) }
            let line = i == 0 ? cells.map { $0.isEmpty ? "" : "\\textbf{\($0)}" } : cells
            out += "  " + line.joined(separator: " & ") + " \\\\\n"
            if i == 0 { out += "  \\hline\n" }
        }
        out += "  \\hline\n\\end{tabular}\n\\end{center}"
        return out
    }
}
