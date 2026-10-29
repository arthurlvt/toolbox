import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import PDFCore

// MARK: - Banc de test : compiler un TP (C, C++, Python), le lancer sur des tests, chercher les erreurs mémoire

enum BenchLanguage: String, CaseIterable, Identifiable, Codable {
    case c, cpp, python
    var id: String { rawValue }
    var title: String {
        switch self {
        case .c: return "C"
        case .cpp: return "C++"
        case .python: return "Python"
        }
    }
    var extensions: Set<String> {
        switch self {
        case .c: return ["c"]
        case .cpp: return ["cpp", "cc", "cxx", "c"]
        case .python: return ["py"]
        }
    }
    var defaultFlags: String {
        switch self {
        case .c: return "-std=c11 -Wall -Wextra"
        case .cpp: return "-std=c++17 -Wall -Wextra"
        case .python: return ""
        }
    }
}

enum CompareMode: String, CaseIterable, Identifiable, Codable {
    case trim, exact, contains
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trim: return "Identique (espaces de fin ignorés)"
        case .exact: return "Identique au caractère près"
        case .contains: return "Contient"
        }
    }
}

struct BenchTest: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Test"
    var args = ""
    var input = ""
    var expected = ""
    var mode = CompareMode.trim
    var timeout = 3.0
}

/// Enregistré dans le dossier du TP (.toolbox-tests.json) : les tests suivent le projet.
struct BenchProject: Codable {
    var language: BenchLanguage?
    var flags: String?
    var excluded: [String] = []
    var mainFile: String?
    var tests: [BenchTest] = []
}

struct BenchResult: Equatable {
    enum Status: Equatable { case pass, fail, timeout, crash, memory, ran }
    var status: Status
    var output: String
    var errors: String
    var exitCode: Int32
    var duration: Double
    var detail: String           // « Erreur de segmentation », résumé AddressSanitizer…
    var leaks: String?           // « 2 fuites, 64 octets »

    var label: String {
        switch status {
        case .pass: return "Réussi"
        case .fail: return "Sortie différente"
        case .timeout: return "Trop long"
        case .crash: return "Plantage"
        case .memory: return "Erreur mémoire"
        case .ran: return "Exécuté"
        }
    }
    var color: Color {
        switch status {
        case .pass: return leaks == nil ? .green : .orange
        case .fail, .crash: return .red
        case .timeout, .memory: return .orange
        case .ran: return .secondary
        }
    }
    var icon: String {
        switch status {
        case .pass: return leaks == nil ? "checkmark.circle.fill" : "drop.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .timeout: return "hourglass"
        case .crash: return "bolt.trianglebadge.exclamationmark.fill"
        case .memory: return "memorychip.fill"
        case .ran: return "play.circle"
        }
    }
}

struct BenchDiagnostic: Identifiable, Hashable {
    let id = UUID()
    let file: String
    let line: Int?
    let column: Int?
    let severity: String     // error, warning, note
    let message: String
}

enum Bench {
    static let configName = ".toolbox-tests.json"

    // MARK: Outils

    /// Découpe des arguments comme le shell : espaces, "guillemets" et 'apostrophes'.
    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, has = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; has = true
            } else if ch == " " || ch == "\t" {
                if !cur.isEmpty || has { out.append(cur); cur = ""; has = false }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty || has { out.append(cur) }
        return out
    }

    static func matches(_ output: String, _ expected: String, mode: CompareMode) -> Bool {
        switch mode {
        case .exact: return output == expected
        case .contains: return output.contains(expected)
        case .trim:
            func norm(_ t: String) -> [String] {
                var lines = t.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                    .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
                while lines.last == "" { lines.removeLast() }
                return lines
            }
            return norm(output) == norm(expected)
        }
    }

    /// Première ligne qui diffère (numérotée à partir de 1).
    static func firstDifference(_ output: String, _ expected: String) -> Int? {
        let a = output.components(separatedBy: "\n"), b = expected.components(separatedBy: "\n")
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i].replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) : nil
            let y = i < b.count ? b[i].replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) : nil
            if x != y { return i + 1 }
        }
        return nil
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case 11: return "Erreur de segmentation (SIGSEGV) : accès à une adresse interdite (pointeur NULL, tableau dépassé…)"
        case 10: return "Erreur de bus (SIGBUS) : accès mémoire mal aligné ou hors zone"
        case 6: return "Arrêt du programme (SIGABRT) : assert raté, double free…"
        case 8: return "Erreur arithmétique (SIGFPE) : division entière par zéro ?"
        case 4: return "Instruction illégale (SIGILL)"
        case 9, 15: return "Arrêté (délai dépassé)"
        default: return "Arrêté par le signal \(sig)"
        }
    }

    /// clang : « main.c:12:5: error: … » ; Python : « File "x.py", line 3 » puis « SyntaxError: … ».
    static func parseDiagnostics(_ log: String, language: BenchLanguage) -> [BenchDiagnostic] {
        var out: [BenchDiagnostic] = []
        let lines = log.components(separatedBy: "\n")
        if language == .python {
            var file = "", line: Int?
            for l in lines {
                if let r = l.range(of: #"File "([^"]+)", line (\d+)"#, options: .regularExpression) {
                    let part = String(l[r])
                    file = part.components(separatedBy: "\"")[1]
                    line = Int(part.components(separatedBy: "line ").last ?? "")
                } else if l.range(of: #"^\w*(Error|Exception)\b"#, options: .regularExpression) != nil {
                    out.append(BenchDiagnostic(file: (file as NSString).lastPathComponent, line: line, column: nil, severity: "error", message: l))
                }
            }
            return out
        }
        guard let re = try? NSRegularExpression(pattern: #"^(.+?):(\d+):(\d+): (fatal error|error|warning|note): (.*)$"#) else { return [] }
        for l in lines {
            let ns = l as NSString
            guard let m = re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { continue }
            let sev = ns.substring(with: m.range(at: 4))
            guard sev != "note" else { continue }
            out.append(BenchDiagnostic(file: ns.substring(with: m.range(at: 1)), line: Int(ns.substring(with: m.range(at: 2))),
                                       column: Int(ns.substring(with: m.range(at: 3))),
                                       severity: sev == "fatal error" ? "error" : sev, message: ns.substring(with: m.range(at: 5))))
        }
        return out
    }

    /// Résumé AddressSanitizer / UBSan dans la sortie d'erreur.
    static func sanitizerSummary(_ stderr: String) -> String? {
        if let r = stderr.range(of: #"SUMMARY: \w+Sanitizer: [^\n]+"#, options: .regularExpression) {
            let s = String(stderr[r]).replacingOccurrences(of: "SUMMARY: ", with: "")
            return explain(s)
        }
        if let r = stderr.range(of: #"[^\n]*runtime error: [^\n]+"#, options: .regularExpression) {
            return "Comportement indéfini : " + String(stderr[r]).components(separatedBy: "runtime error: ").last!
        }
        if let r = stderr.range(of: #"ERROR: AddressSanitizer: [^\n]+"#, options: .regularExpression) {
            return explain(String(stderr[r]).replacingOccurrences(of: "ERROR: ", with: ""))
        }
        return nil
    }

    static func explain(_ raw: String) -> String {
        // chemins complets → nom du fichier seul (« /Users/…/TP3/main.c:12 » → « main.c:12 »)
        let s = raw.replacingOccurrences(of: #"/(?:[^/\s]+/)+"#, with: "", options: .regularExpression)
        let table: [(String, String)] = [
            ("heap-buffer-overflow", "dépassement d'un tableau alloué (malloc/new)"),
            ("stack-buffer-overflow", "dépassement d'un tableau local"),
            ("global-buffer-overflow", "dépassement d'un tableau global"),
            ("heap-use-after-free", "utilisation d'une zone déjà libérée (free/delete)"),
            ("double-free", "free appelé deux fois sur la même zone"),
            ("stack-use-after-return", "pointeur vers une variable locale d'une fonction terminée"),
            ("SEGV on unknown address", "accès à une adresse invalide (pointeur NULL ou non initialisé ?)"),
            ("alloc-dealloc-mismatch", "malloc libéré avec delete (ou new avec free)"),
            ("memory leaks", "fuite mémoire"),
        ]
        for (k, v) in table where s.contains(k) { return v.prefix(1).uppercased() + v.dropFirst() + " — " + s }
        return s
    }

    static func parseLeaks(_ text: String) -> String? {
        guard let r = text.range(of: #"(\d+) leaks? for (\d+) total leaked bytes"#, options: .regularExpression) else { return nil }
        let nums = String(text[r]).components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        guard nums.count >= 2, let n = Int(nums[0]), n > 0 else { return nil }
        return "\(n) fuite\(n > 1 ? "s" : "") mémoire, \(nums[1]) octets jamais libérés"
    }

    // MARK: Exécution

    struct RunOutput { var out: String; var err: String; var code: Int32; var signal: Int32?; var timedOut: Bool; var duration: Double }

    static func run(_ exe: String, _ args: [String], input: String, in dir: URL, env: [String: String] = [:], timeout: Double) -> RunOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = dir
        var e = Shell.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        let outURL = tmp.appendingPathExtension("out"), errURL = tmp.appendingPathExtension("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }
        guard let outH = try? FileHandle(forWritingTo: outURL), let errH = try? FileHandle(forWritingTo: errURL) else {
            return RunOutput(out: "", err: "Impossible de lancer le programme", code: -1, signal: nil, timedOut: false, duration: 0)
        }
        p.standardOutput = outH
        p.standardError = errH
        let inPipe = Pipe()
        p.standardInput = inPipe
        let start = Date()
        do { try p.run() } catch {
            return RunOutput(out: "", err: error.localizedDescription, code: -1, signal: nil, timedOut: false, duration: 0)
        }
        DispatchQueue.global().async {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        var timedOut = false
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: deadline) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); done.wait() }
        }
        try? outH.close(); try? errH.close()
        func read(_ u: URL) -> String {
            guard let d = try? Data(contentsOf: u) else { return "" }
            let cut = d.count > 200_000 ? d.prefix(200_000) : d
            return String(decoding: cut, as: UTF8.self) + (d.count > 200_000 ? "\n… (sortie coupée)" : "")
        }
        let sig: Int32? = p.terminationReason == .uncaughtSignal ? p.terminationStatus : nil
        return RunOutput(out: read(outURL), err: read(errURL), code: p.terminationStatus, signal: sig,
                         timedOut: timedOut, duration: Date().timeIntervalSince(start))
    }
}

// MARK: - État

final class BenchStore: ObservableObject {
    static let shared = BenchStore()

    @Published private(set) var folder: URL?
    @Published private(set) var sources: [URL] = []
    @Published var excluded: Set<String> = [] { didSet { save() } }
    @Published var language: BenchLanguage = .c {
        didSet {
            if !loading, flags == oldValue.defaultFlags { flags = language.defaultFlags }
            built = false
            save()
        }
    }
    @Published var flags = "" { didSet { save() } }
    @Published var mainFile = "" { didSet { save() } }
    @Published var tests: [BenchTest] = [] { didSet { if tests != oldValue { save() } } }
    @Published var selectedID: UUID?
    @Published var leakCheck = UserDefaults.standard.object(forKey: "bench.leaks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(leakCheck, forKey: "bench.leaks") }
    }
    @Published private(set) var results: [UUID: BenchResult] = [:]
    @Published private(set) var diagnostics: [BenchDiagnostic] = []
    @Published private(set) var compileLog = ""
    @Published private(set) var built = false
    @Published private(set) var working = ""
    @Published var status: StatusMessage?
    @Published private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "bench.recents") ?? []

    private var loading = false
    private var binary: URL?
    private var plainBinary: URL?

    var busy: Bool { !working.isEmpty }
    var enabledSources: [URL] { sources.filter { !excluded.contains($0.lastPathComponent) } }
    var passed: Int { tests.filter { results[$0.id]?.status == .pass && results[$0.id]?.leaks == nil }.count }
    var allGreen: Bool { !tests.isEmpty && passed == tests.count }

    // MARK: Projet

    func open(_ dir: URL) {
        var isDir: ObjCBool = false
        var d = dir
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue { d = dir.deletingLastPathComponent() }
        loading = true
        folder = d
        results = [:]
        diagnostics = []
        compileLog = ""
        built = false
        binary = nil
        plainBinary = nil
        scanSources()
        let cfg = (try? Data(contentsOf: d.appendingPathComponent(Bench.configName)))
            .flatMap { try? JSONDecoder().decode(BenchProject.self, from: $0) } ?? BenchProject()
        language = cfg.language ?? guessLanguage()
        flags = cfg.flags ?? language.defaultFlags
        excluded = Set(cfg.excluded)
        mainFile = cfg.mainFile ?? (sources.first { ["main.py", "tp.py"].contains($0.lastPathComponent) } ?? sources.first)?.lastPathComponent ?? ""
        tests = cfg.tests.isEmpty ? [BenchTest(name: "Essai")] : cfg.tests
        selectedID = tests.first?.id
        loading = false
        recents.removeAll { $0 == d.path }
        recents.insert(d.path, at: 0)
        recents = Array(recents.prefix(8))
        UserDefaults.standard.set(recents, forKey: "bench.recents")
        status = .info("\(sources.count) fichier\(sources.count > 1 ? "s" : "") source dans « \(d.lastPathComponent) »")
    }

    func scanSources() {
        guard let d = folder else { return }
        let exts: Set<String> = ["c", "cpp", "cc", "cxx", "py"]
        var list: [URL] = []
        for sub in [d, d.appendingPathComponent("src")] {
            let items = (try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            list += items.filter { exts.contains($0.pathExtension.lowercased()) }
        }
        sources = list.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func guessLanguage() -> BenchLanguage {
        let exts = Set(sources.map { $0.pathExtension.lowercased() })
        if exts.contains("cpp") || exts.contains("cc") || exts.contains("cxx") { return .cpp }
        if exts.contains("c") { return .c }
        if exts.contains("py") { return .python }
        return .c
    }

    /// Dossiers de TP de « Mes cours », les plus récents d'abord.
    var suggestions: [URL] {
        var list: [(URL, Date)] = []
        for c in CoursesStore.shared.courses {
            for s in c.sessions(.tp) {
                for it in s.items where it.isFolder { list.append((it.url, it.modified)) }
            }
        }
        return list.sorted { $0.1 > $1.1 }.prefix(6).map { $0.0 }
    }

    private func save() {
        guard !loading, let d = folder else { return }
        let cfg = BenchProject(language: language, flags: flags, excluded: Array(excluded).sorted(),
                               mainFile: mainFile.isEmpty ? nil : mainFile, tests: tests)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) { try? data.write(to: d.appendingPathComponent(Bench.configName), options: .atomic) }
    }

    private var buildDir: URL {
        let key = SHA256.hash(data: Data((folder?.path ?? "").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/fr.arthur.toolbox/bench/\(folder?.lastPathComponent ?? "tp")-\(key)", isDirectory: true)
    }

    // MARK: Compiler

    func compile(then next: (() -> Void)? = nil) {
        guard let d = folder, !busy else { return }
        let files = enabledSources.filter { language.extensions.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { status = .err("Aucun fichier \(language.title) coché."); return }
        working = "Compilation…"
        diagnostics = []
        let lang = language, userFlags = Bench.splitArgs(flags), out = buildDir, leaks = leakCheck
        runInBackground({ () -> (Bool, String, URL?, URL?) in
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if lang == .python {
                guard let py = Shell.which("python3") else { throw PDFToolError.commandFailed("python3 introuvable") }
                let r = try Shell.run(py, ["-m", "py_compile"] + files.map { $0.path }, in: d)
                return (r.status == 0, r.text, nil, nil)
            }
            let cc = lang == .c ? (Shell.which("clang") ?? "/usr/bin/cc") : (Shell.which("clang++") ?? "/usr/bin/c++")
            let exe = out.appendingPathComponent("programme")
            let common = userFlags + ["-g"] + files.map { $0.path }
            let sanit = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-fno-sanitize-recover=undefined"]
            let r = try Shell.run(cc, common + sanit + ["-o", exe.path, "-lm"], in: d)
            var plain: URL?
            if r.status == 0, leaks {
                let p = out.appendingPathComponent("programme-fuites")
                if (try? Shell.run(cc, common + ["-o", p.path, "-lm"], in: d))?.status == 0 { plain = p }
            }
            return (r.status == 0, r.text, r.status == 0 ? exe : nil, plain)
        }) { [weak self] r in
            guard let self = self else { return }
            self.working = ""
            switch r {
            case .success(let (ok, log, exe, plain)):
                self.compileLog = log
                self.diagnostics = Bench.parseDiagnostics(log, language: lang)
                self.built = ok
                self.binary = exe
                self.plainBinary = plain
                let w = self.diagnostics.filter { $0.severity == "warning" }.count
                if ok {
                    self.status = .ok("Compilé ✓" + (w > 0 ? " · \(w) avertissement\(w > 1 ? "s" : "") à regarder" : ""))
                    next?()
                } else {
                    let e = max(1, self.diagnostics.filter { $0.severity == "error" }.count)
                    self.status = .err("La compilation a échoué : \(e) erreur\(e > 1 ? "s" : ""). Clique une erreur pour l'ouvrir.")
                }
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    // MARK: Lancer

    func runAll() { compile { self.runTests(self.tests.map { $0.id }) } }
    func runOne(_ id: UUID) { compile { self.runTests([id]) } }

    private func runTests(_ ids: [UUID]) {
        guard let d = folder else { return }
        let lang = language, exe = binary, plain = plainBinary, list = tests.filter { ids.contains($0.id) }
        let main = d.appendingPathComponent(mainFile)
        working = "Tests en cours…"
        for t in list { results[t.id] = nil }
        runInBackground({ () -> [(UUID, BenchResult)] in
            var out: [(UUID, BenchResult)] = []
            for t in list {
                let args = Bench.splitArgs(t.args)
                let o: Bench.RunOutput
                if lang == .python {
                    o = Bench.run(Shell.which("python3") ?? "/usr/bin/python3", [main.path] + args, input: t.input, in: d, timeout: t.timeout)
                } else if let exe = exe {
                    o = Bench.run(exe.path, args, input: t.input, in: d,
                                  env: ["ASAN_OPTIONS": "detect_leaks=0:abort_on_error=0:halt_on_error=1",
                                        "UBSAN_OPTIONS": "print_stacktrace=1"], timeout: t.timeout)
                } else { continue }
                var r = BenchResult(status: .ran, output: o.out, errors: o.err, exitCode: o.code, duration: o.duration, detail: "")
                if o.timedOut {
                    r.status = .timeout
                    r.detail = "Toujours en cours après \(MathFormat.fr(t.timeout)) s : boucle infinie, ou il attend une entrée ?"
                } else if let san = Bench.sanitizerSummary(o.err) {
                    r.status = .memory
                    r.detail = san
                } else if let sig = o.signal {
                    r.status = .crash
                    r.detail = Bench.signalName(sig)
                } else if lang == .python, o.code != 0, let last = o.err.components(separatedBy: "\n").last(where: { !$0.isEmpty }) {
                    r.status = .crash
                    r.detail = last
                } else if t.expected.isEmpty {
                    r.status = .ran
                    r.detail = "Pas de sortie attendue : « Utiliser comme sortie attendue » pour en faire un test"
                } else {
                    r.status = Bench.matches(o.out, t.expected, mode: t.mode) ? .pass : .fail
                    if r.status == .fail, let line = Bench.firstDifference(o.out, t.expected), t.mode != .contains {
                        r.detail = "Première différence à la ligne \(line)"
                    }
                    if o.code != 0 && r.status == .pass { r.detail = "Code de retour \(o.code) (main devrait renvoyer 0)" }
                }
                // fuites : version sans AddressSanitizer, lancée sous « leaks »
                if let plain = plain, r.status == .pass || r.status == .ran {
                    let l = Bench.run("/usr/bin/leaks", ["--atExit", "--", plain.path] + args, input: t.input, in: d,
                                      env: ["MallocStackLogging": "1"], timeout: t.timeout + 10)
                    r.leaks = Bench.parseLeaks(l.out + l.err)
                }
                out.append((t.id, r))
            }
            return out
        }) { [weak self] r in
            guard let self = self else { return }
            self.working = ""
            guard case .success(let list) = r else { return }
            for (id, res) in list { self.results[id] = res }
            let total = self.tests.count
            if list.count > 1 || total == 1 {
                if self.allGreen {
                    self.status = .ok("\(total)/\(total) tests réussis\(self.plainBinary != nil ? ", aucune fuite mémoire" : "") 🎉")
                    ToastCenter.shared.show("Tous les tests passent 🎉", cheer: true)
                } else {
                    self.status = .info("\(self.passed)/\(total) tests réussis")
                }
            }
        }
    }

    func useOutputAsExpected(_ id: UUID) {
        guard let r = results[id], let i = tests.firstIndex(where: { $0.id == id }) else { return }
        tests[i].expected = r.output
        results[id]?.status = .pass
        results[id]?.detail = ""
    }

    func addTest() {
        let t = BenchTest(name: "Test \(tests.count + 1)")
        tests.append(t)
        selectedID = t.id
    }

    func duplicate(_ id: UUID) {
        guard let t = tests.first(where: { $0.id == id }) else { return }
        var c = t
        c.id = UUID()
        c.name += " (copie)"
        tests.append(c)
        selectedID = c.id
    }

    func remove(_ id: UUID) {
        tests.removeAll { $0.id == id }
        results[id] = nil
        if selectedID == id { selectedID = tests.first?.id }
    }

    func binding(_ id: UUID) -> Binding<BenchTest>? {
        guard tests.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.tests.first { $0.id == id } ?? BenchTest() },
                       set: { v in if let i = self.tests.firstIndex(where: { $0.id == id }) { self.tests[i] = v } })
    }

    func prepareSubmission() {
        guard let d = folder else { return }
        let a = ArchiveStore.shared
        a.items = [d]
        a.forTP = true
        a.excludeJunk = true
        a.tab = .create
        AppRouter.shared.show = .compress
    }
}

// MARK: - Vue

struct TestBenchView: View {
    @ObservedObject var s = BenchStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .testbench)
            if s.folder == nil {
                start
            } else {
                HSplitView {
                    left.frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    right.frame(minWidth: 480).padding(.leading, 10)
                }
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FileDrop.load(providers) { if let u = $0.first { s.open(u) } }
            return true
        }
    }

    // MARK: Accueil

    private var start: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text("Dépose le dossier d'un TP (C, C++ ou Python)").font(.title3.weight(.semibold))
            Text("Je le compile avec les détecteurs d'erreurs mémoire, je le lance sur tes tests (entrée → sortie attendue) et je cherche les fuites. Les tests sont gardés dans le dossier du TP.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            Button("Choisir le dossier…") { if let u = Panels.folder(prompt: "Tester ce TP") { s.open(u) } }
                .buttonStyle(.borderedProminent).controlSize(.large)
            let sug = s.suggestions
            let rec = s.recents.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !sug.isEmpty || !rec.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Récemment").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(Set(rec + sug)).sorted { a, b in (rec.firstIndex(of: a) ?? 99) < (rec.firstIndex(of: b) ?? 99) }.prefix(8), id: \.self) { u in
                        Button { s.open(u) } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(Color.orange)
                                Text(u.deletingLastPathComponent().lastPathComponent + " / " + u.lastPathComponent)
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Projet (gauche)

    private var left: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Color.orange)
                    Text(s.folder?.lastPathComponent ?? "").font(.headline).lineLimit(1)
                    Spacer()
                    Menu {
                        Button("Autre dossier…") { if let u = Panels.folder(prompt: "Tester ce TP") { s.open(u) } }
                        Button("Ouvrir dans VS Code") { if let d = s.folder { VSCode.open(d) } }
                        Button("Afficher dans le Finder") { if let d = s.folder { NSWorkspace.shared.activateFileViewerSelecting([d]) } }
                        Button("Relire les fichiers") { s.scanSources() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                Picker("Langage", selection: $s.language) {
                    ForEach(BenchLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fichiers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(s.sources, id: \.self) { u in
                        let usable = s.language.extensions.contains(u.pathExtension.lowercased())
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(get: { !s.excluded.contains(u.lastPathComponent) },
                                                     set: { if $0 { s.excluded.remove(u.lastPathComponent) } else { s.excluded.insert(u.lastPathComponent) } }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(!usable)
                            Text(u.lastPathComponent).font(.callout.monospaced()).foregroundStyle(usable ? Color.primary : Color.secondary)
                            Spacer()
                            if s.language == .python {
                                Button { s.mainFile = u.lastPathComponent } label: {
                                    Image(systemName: s.mainFile == u.lastPathComponent ? "play.circle.fill" : "play.circle")
                                }
                                .buttonStyle(.borderless).help("Fichier à lancer")
                            }
                        }
                    }
                    if s.sources.isEmpty { Text("Aucun .c, .cpp ou .py dans ce dossier").font(.caption).foregroundStyle(.secondary) }
                }
                if s.language != .python {
                    TextField("Options de compilation", text: $s.flags).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    Toggle("Chercher les fuites mémoire (leaks)", isOn: $s.leakCheck)
                    Text("Compilé avec AddressSanitizer et UBSan : dépassements de tableau, pointeurs invalides, double free et comportements indéfinis sont détectés et expliqués.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button { s.compile() } label: { Label("Compiler", systemImage: "hammer.fill") }
                        .disabled(s.busy)
                    if s.busy { ProgressView().controlSize(.small); Text(s.working).font(.caption).foregroundStyle(.secondary) }
                }
                if !s.diagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compilation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(s.diagnostics) { d in
                            Button {
                                if let f = s.folder {
                                    let u = d.file.hasPrefix("/") ? URL(fileURLWithPath: d.file) : f.appendingPathComponent(d.file)
                                    Editor.open(u, line: d.line)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: d.severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(d.severity == "error" ? Color.red : Color.orange)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\((d.file as NSString).lastPathComponent)\(d.line.map { ":\($0)" } ?? "")").font(.caption.monospaced())
                                        Text(d.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Ouvrir à la ligne dans VS Code")
                        }
                    }
                } else if !s.compileLog.isEmpty && !s.built {
                    Text(s.compileLog).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(.trailing, 8)
        }
    }

    // MARK: Tests (droite)

    private var right: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tests").font(.headline)
                if !s.tests.isEmpty, !s.results.isEmpty {
                    Text("\(s.passed)/\(s.tests.count)").font(.callout.monospacedDigit())
                        .foregroundStyle(s.allGreen ? Color.green : Color.secondary)
                }
                Spacer()
                Button { s.addTest() } label: { Label("Test", systemImage: "plus") }
                Button { s.runAll() } label: { Label("Tout lancer", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r")
                    .disabled(s.busy || s.tests.isEmpty)
                    .help("Compiler puis lancer tous les tests (⌘R)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(s.tests) { t in chip(t) }
                }
            }
            if let id = s.selectedID, let b = s.binding(id) {
                testEditor(b, id: id)
            } else {
                Text("Ajoute un test : ce que tu tapes au clavier (entrée) et ce que le programme doit afficher (sortie attendue).")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if s.allGreen {
                HStack {
                    Label("Tout est vert\(s.leakCheck && s.language != .python ? ", sans fuite" : "") : prêt à rendre", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.green).font(.callout.weight(.semibold))
                    Spacer()
                    Button { s.prepareSubmission() } label: { Label("Préparer le .zip à rendre", systemImage: "archivebox") }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.1)))
            }
        }
    }

    private func chip(_ t: BenchTest) -> some View {
        let r = s.results[t.id]
        let on = s.selectedID == t.id
        return Button { s.selectedID = t.id } label: {
            HStack(spacing: 5) {
                Image(systemName: r?.icon ?? "circle.dashed").foregroundStyle(r?.color ?? Color.secondary)
                Text(t.name).lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Lancer ce test") { s.runOne(t.id) }
            Button("Dupliquer") { s.duplicate(t.id) }
            Divider()
            Button("Supprimer", role: .destructive) { s.remove(t.id) }
        }
    }

    private func testEditor(_ t: Binding<BenchTest>, id: UUID) -> some View {
        let r = s.results[id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Nom", text: t.name).textFieldStyle(.roundedBorder).frame(width: 180)
                TextField("Arguments (argv)", text: t.args).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                Stepper(value: t.timeout, in: 1...60, step: 1) { Text("\(Int(t.wrappedValue.timeout)) s").monospacedDigit() }
                    .fixedSize().help("Temps maximum avant de considérer une boucle infinie")
                Button { s.runOne(id) } label: { Image(systemName: "play.fill") }.disabled(s.busy).help("Lancer ce test")
                Button { s.remove(id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Supprimer le test")
            }
            HStack(alignment: .top, spacing: 10) {
                box("Entrée (clavier, stdin)", text: t.input)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sortie attendue").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: t.mode) { ForEach(CompareMode.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden().fixedSize().controlSize(.small)
                    }
                    TextEditor(text: t.expected).font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }
            .frame(height: 150)
            if let r = r {
                result(r, test: t.wrappedValue, id: id)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func box(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private func result(_ r: BenchResult, test: BenchTest, id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(r.label, systemImage: r.icon).foregroundStyle(r.color).font(.callout.weight(.semibold))
                Text(String(format: "%.0f ms", r.duration * 1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if r.exitCode != 0 && r.status != .crash { Text("code \(r.exitCode)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if r.status == .fail || r.status == .ran {
                    Button("Utiliser comme sortie attendue") { s.useOutputAsExpected(id) }.controlSize(.small)
                }
            }
            if !r.detail.isEmpty {
                Text(r.detail).font(.callout).foregroundStyle(r.status == .pass || r.status == .ran ? Color.secondary : r.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let l = r.leaks {
                Label(l + " : il manque un free (ou delete) quelque part", systemImage: "drop.triangle.fill")
                    .font(.callout).foregroundStyle(Color.orange)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sortie obtenue").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        diffText(r.output, against: test.expected, mode: test.mode, show: r.status == .fail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                if !r.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Erreurs (stderr)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ScrollView {
                            Text(r.errors).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.06)))
                    }
                }
            }
            .frame(minHeight: 120)
        }
    }

    /// Lignes différentes de l'attendu en rouge.
    private func diffText(_ out: String, against expected: String, mode: CompareMode, show: Bool) -> some View {
        let a = out.components(separatedBy: "\n"), b = expected.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(a.enumerated()), id: \.offset) { i, line in
                let same = !show || mode == .contains || (i < b.count && line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                                                         == b[i].replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(same ? Color.primary : Color.red)
                    .background(same ? Color.clear : Color.red.opacity(0.1))
                    .help(same || i >= b.count ? "" : "Attendu : " + b[i])
            }
            if show, b.count > a.count, mode != .contains {
                Text("(il manque \(b.count - a.count) ligne\(b.count - a.count > 1 ? "s" : ""))")
                    .font(.caption).foregroundStyle(Color.red)
            }
        }
        .textSelection(.enabled)
    }
}
