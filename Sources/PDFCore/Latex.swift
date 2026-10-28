import Foundation

public enum LatexEngine: String, CaseIterable, Identifiable {
    case pdflatex, xelatex, lualatex

    public var id: String { rawValue }
    public var title: String { rawValue }

    var latexmkFlag: String {
        switch self {
        case .pdflatex: return "-pdf"
        case .xelatex: return "-xelatex"
        case .lualatex: return "-lualatex"
        }
    }
}

public struct LatexIssue: Identifiable, Hashable {
    public let id = UUID()
    public let file: String?
    public let line: Int?
    public let message: String
    public let isWarning: Bool

    public var location: String {
        let name = file.map { ($0 as NSString).lastPathComponent }
        switch (name, line) {
        case let (n?, l?): return "\(n):\(l)"
        case let (nil, l?): return "ligne \(l)"
        case let (n?, nil): return n
        default: return ""
        }
    }
}

public struct LatexResult {
    public let success: Bool
    public let pdf: URL
    public let log: String
    public let usedLatexmk: Bool
}

public enum Latex {
    public static var latexmkPath: String? { Shell.which("latexmk") }

    public static func isAvailable(_ engine: LatexEngine) -> Bool { Shell.which(engine.rawValue) != nil }

    public static func pdfURL(for tex: URL) -> URL {
        tex.deletingPathExtension().appendingPathExtension("pdf")
    }

    // MARK: Compilation

    /// Compile avec latexmk (gère bibliographie, index et passes multiples tout seul),
    /// ou à défaut lance le moteur deux fois.
    /// `texInputs` : dossiers supplémentaires où chercher les classes (.cls) et paquets.
    public static func compile(_ tex: URL, engine: LatexEngine, texInputs: [URL] = [],
                               onOutput: ((String) -> Void)? = nil) throws -> LatexResult {
        let dir = tex.deletingLastPathComponent()
        let name = tex.lastPathComponent
        let common = ["-interaction=nonstopmode", "-file-line-error", "-synctex=1", "-halt-on-error"]
        // Évite que TeX coupe les messages à 79 caractères.
        var env = ["max_print_line": "10000", "error_line": "254", "half_error_line": "238"]
        if !texInputs.isEmpty {
            // Le « : » final garde aussi les chemins par défaut de TeX.
            env["TEXINPUTS"] = texInputs.map { $0.path + "//" }.joined(separator: ":") + ":"
        }

        if let latexmk = latexmkPath {
            let r = try Shell.run(latexmk, [engine.latexmkFlag] + common + [name],
                                  in: dir, extraEnvironment: env, onOutput: onOutput)
            return LatexResult(success: r.status == 0, pdf: pdfURL(for: tex), log: r.text, usedLatexmk: true)
        }

        guard let exe = Shell.which(engine.rawValue) else {
            throw PDFToolError.toolMissing("\(engine.rawValue). Installe MacTeX : brew install --cask mactex-no-gui")
        }
        var log = ""
        var ok = true
        for _ in 0..<2 {
            let r = try Shell.run(exe, common + [name], in: dir, extraEnvironment: env, onOutput: onOutput)
            log += r.text
            if r.status != 0 { ok = false; break }
        }
        return LatexResult(success: ok, pdf: pdfURL(for: tex), log: log, usedLatexmk: false)
    }

    // MARK: Analyse du journal

    public static func parseIssues(_ log: String) -> [LatexIssue] {
        var issues: [LatexIssue] = []
        var seen = Set<String>()
        func add(_ issue: LatexIssue) {
            let key = "\(issue.file ?? "")|\(issue.line ?? -1)|\(issue.message)"
            if seen.insert(key).inserted { issues.append(issue) }
        }

        let fileLine = try? NSRegularExpression(pattern: #"^(.+?\.(?:tex|sty|cls|bib|ltx|dtx)):(\d+): (.+)$"#)
        let inputLine = try? NSRegularExpression(pattern: #"on input line (\d+)"#)
        let lines = log.components(separatedBy: .newlines)

        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let m = match(fileLine, line), m.count == 3 {
                add(LatexIssue(file: m[0], line: Int(m[1]), message: m[2], isWarning: false))
            } else if line.hasPrefix("! ") {
                var lineNo: Int?
                for next in lines[(i + 1)..<min(i + 12, lines.count)] where next.hasPrefix("l.") {
                    lineNo = Int(next.dropFirst(2).prefix { $0.isNumber })
                    break
                }
                add(LatexIssue(file: nil, line: lineNo, message: String(line.dropFirst(2)), isWarning: false))
            } else if line.contains("Warning:"),
                      line.hasPrefix("LaTeX Warning") || line.hasPrefix("Package") || line.hasPrefix("Class") {
                let message = line.components(separatedBy: "Warning:").dropFirst().joined(separator: "Warning:")
                    .trimmingCharacters(in: .whitespaces)
                let lineNo = match(inputLine, line).flatMap { Int($0[0]) }
                add(LatexIssue(file: nil, line: lineNo, message: message, isWarning: true))
            }
        }
        // Erreurs d'abord.
        return issues.filter { !$0.isWarning } + issues.filter { $0.isWarning }
    }

    private static func match(_ regex: NSRegularExpression?, _ s: String) -> [String]? {
        guard let regex = regex,
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    // MARK: Nettoyage

    public static let auxiliaryExtensions = [
        "aux", "log", "out", "toc", "lof", "lot", "lol", "loa", "fls", "fdb_latexmk",
        "synctex.gz", "synctex", "synctex(busy)", "bbl", "blg", "bcf", "run.xml",
        "nav", "snm", "vrb", "idx", "ilg", "ind", "glo", "gls", "glg", "ist",
        "acn", "acr", "alg", "thm", "xdv", "dvi",
    ]

    /// Met à la corbeille les fichiers auxiliaires du document (pas le PDF).
    @discardableResult
    public static func clean(_ tex: URL) -> [URL] {
        let dir = tex.deletingLastPathComponent()
        let base = tex.deletingPathExtension().lastPathComponent
        var removed: [URL] = []
        for ext in auxiliaryExtensions {
            let url = dir.appendingPathComponent("\(base).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                removed.append(url)
            }
        }
        return removed
    }

    // MARK: Surveillance

    public static let watchedExtensions: Set<String> = [
        "tex", "bib", "sty", "cls", "bst", "tikz", "png", "jpg", "jpeg", "eps", "svg",
    ]

    /// Date de modification de chaque source du dossier (sous-dossiers compris).
    /// Le PDF n'est volontairement pas surveillé pour éviter une boucle de recompilation.
    public static func sourceSnapshot(in folder: URL, limit: Int = 3000) -> [URL: Date] {
        var result: [URL: Date] = [:]
        guard let e = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }
        var count = 0
        for case let url as URL in e {
            count += 1
            if count > limit { break }
            guard watchedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            result[url] = date ?? .distantPast
        }
        return result
    }
}
