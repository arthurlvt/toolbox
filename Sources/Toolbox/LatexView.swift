import SwiftUI
import AppKit
import Combine
import PDFKit
import PDFCore

/// Entrée du plan du document (section, exercice…).
struct OutlineItem: Identifiable, Equatable {
    let id: Int          // ligne (1…)
    let level: Int
    let title: String
}

final class LatexModel: ObservableObject {
    @Published var texURL: URL?                 // fichier principal (celui qu'on compile)
    @Published var engine: LatexEngine = .pdflatex
    @Published var log = ""
    @Published var issues: [LatexIssue] = []
    @Published var compiling = false
    @Published var lastSuccess: Bool?
    @Published var lastDuration: TimeInterval = 0
    @Published var watching = false
    @Published var reloadToken = 0
    @Published var status: StatusMessage?
    @Published var stats: LatexStats?

    // Nouveau projet
    @Published var showNewProject = false
    @Published var newTemplate: LatexTemplate = .course
    @Published var newTitle = ""
    @Published var newAuthor = NSFullUserName()

    // SyncTeX
    @Published var jump: PDFJump?

    // Éditeur intégré : le fichier affiché (onglet courant)
    @Published var source = "" { didSet { if source != savedSource { sourceEdited() } } }
    @Published private(set) var savedSource = ""
    @Published var editorCommand: EditorCommand?
    @Published var showDiagnostics = true
    @Published var showOutline = true
    @Published var fontSize: CGFloat = 13
    @Published var outline: [OutlineItem] = []
    var cursorLine = 1
    var dirty: Bool { source != savedSource }

    // Onglets (fichier principal + fichiers \input / \include)
    @Published var tabs: [URL] = []
    @Published var currentFile: URL?
    private var buffers: [URL: String] = [:]
    private var savedBuffers: [URL: String] = [:]

    // Historique
    @Published var showHistory = false

    // IA locale (ses changements redessinent aussi la vue LaTeX)
    let ai = LatexAI()
    private var aiSink: AnyCancellable?

    private var timer: Timer?
    private var snapshot: [URL: Date] = [:]
    private var pendingRecompile = false
    private var pendingSave: DispatchWorkItem?
    private var outlineWork: DispatchWorkItem?
    private let maxLogLength = 400_000

    init() {
        aiSink = ai.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var pdfURL: URL? { texURL.map(Latex.pdfURL(for:)) }
    var pdfExists: Bool { pdfURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var errorCount: Int { issues.filter { !$0.isWarning }.count }
    var warningCount: Int { issues.filter { $0.isWarning }.count }
    var folder: URL? { texURL?.deletingLastPathComponent() }

    /// Dossier des nouveaux documents : ~/Documents/Toolbox LaTeX
    static var draftsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Toolbox LaTeX", isDirectory: true)
    }

    // MARK: Ouverture

    func open(_ url: URL) {
        if texURL != nil { saveAll() }
        RecentFiles.add(url)
        texURL = url
        buffers = [:]
        savedBuffers = [:]
        currentFile = url
        tabs = [url]
        loadSource()
        refreshTabs()
        log = ""
        issues = []
        lastSuccess = nil
        status = nil
        stats = nil
        engine = Self.guessEngine(url)
        reloadToken += 1
        if watching { startWatching() }
    }

    func close() {
        saveAll()
        setWatching(false)
        pendingSave?.cancel()
        texURL = nil
        currentFile = nil
        tabs = []
        buffers = [:]
        savedBuffers = [:]
        savedSource = ""
        source = ""
        outline = []
        log = ""
        issues = []
        lastSuccess = nil
        status = nil
    }

    static func guessEngine(_ url: URL) -> LatexEngine {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .pdflatex }
        let head = text.prefix(4000).lowercased()
        if head.contains("program = lualatex") || head.contains("program=lualatex") { return .lualatex }
        if head.contains("program = xelatex") || head.contains("program=xelatex") || head.contains("{fontspec}") {
            return .xelatex
        }
        return .pdflatex
    }

    // MARK: Onglets

    static func same(_ a: URL?, _ b: URL?) -> Bool {
        guard let a = a, let b = b else { return false }
        return a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Ajoute les fichiers \input{…}, \include{…} du fichier principal.
    func refreshTabs() {
        guard let main = texURL, let dir = folder else { return }
        let text = Self.same(currentFile, main) ? source : ((try? String(contentsOf: main, encoding: .utf8)) ?? "")
        let found = LatexCompletion.matches(#"(?m)^[^%\n]*?\\(?:input|include|subfile)\{([^}]+)\}"#, text)
        var urls = tabs.isEmpty ? [main] : tabs
        for name in found {
            var u = URL(fileURLWithPath: name, relativeTo: dir).standardizedFileURL
            if u.pathExtension.isEmpty { u = u.appendingPathExtension("tex") }
            if FileManager.default.fileExists(atPath: u.path), !urls.contains(where: { Self.same($0, u) }) {
                urls.append(u)
            }
        }
        if urls != tabs { tabs = urls }
    }

    func isDirty(_ url: URL) -> Bool {
        if Self.same(url, currentFile) { return dirty }
        guard let b = buffers[url] else { return false }
        return b != savedBuffers[url]
    }

    func select(_ url: URL) {
        guard !Self.same(url, currentFile) else { return }
        if let cur = currentFile {
            buffers[cur] = source
            savedBuffers[cur] = savedSource
        }
        currentFile = url
        if let b = buffers[url], let saved = savedBuffers[url] {
            savedSource = saved
            source = b
            updateOutline()
        } else {
            loadSource()
        }
    }

    func openTab(_ url: URL) {
        if !tabs.contains(where: { Self.same($0, url) }) { tabs.append(url) }
        select(tabs.first { Self.same($0, url) } ?? url)
    }

    func closeTab(_ url: URL) {
        guard !Self.same(url, texURL) else { return }
        if Self.same(url, currentFile) {
            save()
            if let main = texURL { select(main) }
        } else if let b = buffers[url], b != savedBuffers[url] {
            try? b.write(to: url, atomically: true, encoding: .utf8)
        }
        buffers[url] = nil
        savedBuffers[url] = nil
        tabs.removeAll { Self.same($0, url) }
    }

    // MARK: Compilation

    func compile() {
        guard let tex = texURL else { return }
        saveAll()
        if compiling { pendingRecompile = true; return }
        compiling = true
        log = ""
        status = .info("Compilation de \(tex.lastPathComponent) avec \(engine.rawValue)…")
        let engine = self.engine
        let start = Date()
        let files = tabs
        runInBackground({ LatexHistory.snapshot(main: tex, files: files) }) { _ in }

        runInBackground({ [weak self] in
            try Latex.compile(tex, engine: engine) { chunk in
                DispatchQueue.main.async { self?.appendLog(chunk) }
            }
        }) { [weak self] result in
            guard let self = self else { return }
            self.compiling = false
            self.lastDuration = Date().timeIntervalSince(start)
            switch result {
            case .success(let r):
                defer { DiscordPresence.shared.refresh() }
                let wasFailing = self.lastSuccess == false
                self.issues = Latex.parseIssues(r.log)
                self.lastSuccess = r.success
                if r.success && wasFailing {
                    ToastCenter.shared.show("Plus aucune erreur, bravo ! 🎉", cheer: true)
                }
                self.reloadToken += 1
                self.computeStats()
                let secs = String(format: "%.1f", self.lastDuration)
                if r.success {
                    let w = self.warningCount
                    self.status = .ok("PDF généré en \(secs) s" + (w > 0 ? " · \(w) avertissement(s)" : ""))
                } else {
                    self.showDiagnostics = true
                    self.status = .err("Échec de la compilation : \(max(1, self.errorCount)) erreur(s). Clique une erreur pour y aller, ✨ pour l'explication.")
                }
            case .failure(let e):
                self.lastSuccess = false
                self.status = .err(e)
            }
            if self.pendingRecompile {
                self.pendingRecompile = false
                self.compile()
            }
        }
    }

    private func appendLog(_ chunk: String) {
        log += chunk
        if log.count > maxLogLength { log = String(log.suffix(maxLogLength)) }
    }

    func clean() {
        guard let tex = texURL else { return }
        let removed = Latex.clean(tex)
        status = removed.isEmpty
            ? .info("Aucun fichier auxiliaire à nettoyer.")
            : .ok("\(removed.count) fichier(s) auxiliaire(s) mis à la corbeille : " +
                  removed.map { $0.pathExtension }.joined(separator: ", "))
    }

    // MARK: Surveillance

    func setWatching(_ on: Bool) {
        watching = on
        if on { startWatching(); compile() } else { stopWatching() }
    }

    private func startWatching() {
        stopWatching()
        snapshot = currentSnapshot()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func checkForChanges() {
        let now = currentSnapshot()
        if now != snapshot {
            // Fichier modifié dans un autre éditeur : on recharge s'il n'y a rien de non enregistré ici.
            if let cur = currentFile, !dirty,
               let key = now.keys.first(where: { Self.same($0, cur) }), now[key] != snapshot[key] {
                loadSource()
            }
            snapshot = now
            compile()
        }
    }

    private func currentSnapshot() -> [URL: Date] {
        guard let dir = folder else { return [:] }
        return Latex.sourceSnapshot(in: dir)
    }

    // MARK: Statistiques

    func computeStats() {
        guard let tex = texURL else { return }
        let issues = self.issues
        runInBackground({ Latex.stats(for: tex, issues: issues) }) { [weak self] result in
            if case .success(let s) = result { self?.stats = s }
        }
    }

    // MARK: SyncTeX

    /// ⌘-clic dans l'aperçu → la bonne ligne dans l'éditeur.
    func inverseSearch(pageIndex: Int, point: CGPoint, mediaBox: CGRect) {
        guard let pdf = pdfURL else { return }
        let x = Double(point.x - mediaBox.minX)
        let y = Double(mediaBox.maxY - point.y)
        runInBackground({ SyncTeX.source(pdf: pdf, page: pageIndex + 1, x: x, y: y) }) { [weak self] result in
            if case .success(let found?) = result {
                self?.show(found.file, line: found.line)
                self?.status = .info("→ \(found.file.lastPathComponent), ligne \(found.line)")
            } else {
                self?.status = .err("SyncTeX n'a rien trouvé à cet endroit (recompile si le PDF a changé).")
            }
        }
    }

    /// Ligne du curseur → position dans l'aperçu.
    func forwardSearch() {
        guard let tex = currentFile ?? texURL, let pdf = pdfURL else { return }
        save()
        let line = cursorLine
        let token = (jump?.token ?? 0) + 1
        runInBackground({ SyncTeX.target(tex: tex, line: line, pdf: pdf) }) { [weak self] result in
            if case .success(let t?) = result {
                self?.jump = PDFJump(page: t.page, x: t.x, y: t.y, token: token)
                self?.status = .info("Ligne \(line) → page \(t.page)")
            } else {
                self?.status = .err("Ligne \(line) introuvable dans le PDF (compile d'abord).")
            }
        }
    }

    // MARK: Nouveau projet / document

    func createProject(in parent: URL) {
        do {
            let main = try newTemplate.createProject(title: newTitle, author: newAuthor, in: parent)
            LatexDocsStore.shared.register(main, kind: "projet", title: newTitle, matiere: "")
            showNewProject = false
            open(main)
            compile()
        } catch {
            status = .err(error)
        }
    }

    /// « Nouveau document » : demande le type (TD, TP, cours, rapport, autre) puis crée un modèle pré-rempli.
    func newDocument() {
        NewLatexDocForm.shared.present()
    }

    /// Document vierge dans ~/Documents/Toolbox LaTeX/Sans titre N/main.tex (sans rien demander)
    func newBlankDocument() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.draftsFolder, withIntermediateDirectories: true)
            var n = 1
            var dir = Self.draftsFolder.appendingPathComponent("Sans titre")
            while fm.fileExists(atPath: dir.path) {
                n += 1
                dir = Self.draftsFolder.appendingPathComponent("Sans titre \(n)")
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let main = dir.appendingPathComponent("main.tex")
            try Self.blankDocument.write(to: main, atomically: true, encoding: .utf8)
            LatexDocsStore.shared.register(main, kind: "autre", title: dir.lastPathComponent, matiere: "")
            open(main)
            send(.goTo(line: 15))
            compile()
        } catch {
            status = .err(error)
        }
    }

    static let blankDocument = #"""
\documentclass[a4paper,11pt]{article}
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage[french]{babel}
\usepackage{amsmath,amssymb}
\usepackage[margin=2.5cm]{geometry}

\title{Sans titre}
\author{}
\date{\today}

\begin{document}
\maketitle

Ton texte ici. Une formule : $\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$.

\end{document}
"""#

    // MARK: Éditeur

    func send(_ action: EditorCommand.Action) {
        editorCommand = EditorCommand(action: action, token: (editorCommand?.token ?? 0) + 1)
    }

    func reveal(_ issue: LatexIssue) {
        guard let dir = folder else { return }
        let file = issue.file.map { URL(fileURLWithPath: $0, relativeTo: dir).standardizedFileURL } ?? texURL
        if let file = file { show(file, line: issue.line) }
    }

    /// Fichier .tex du projet → onglet de l'éditeur intégré ; autre fichier → éditeur externe.
    func show(_ file: URL, line: Int?) {
        let inProject = folder.map { file.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") } ?? false
        if file.pathExtension.lowercased() == "tex" && (inProject || tabs.contains { Self.same($0, file) }) {
            openTab(file)
            if let line = line { send(.goTo(line: line)) }
        } else {
            Editor.open(file, line: line)
        }
    }

    private func loadSource() {
        guard let file = currentFile else { return }
        let text = (try? String(contentsOf: file, encoding: .utf8))
            ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
        savedSource = text
        source = text
        updateOutline()
    }

    /// Frappe : enregistrement 1 s après la dernière touche (et compilation si « Auto »).
    private func sourceEdited() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.watching { self.compile() } else { self.save() }
            self.refreshTabs()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        scheduleOutline()
    }

    private func scheduleOutline() {
        outlineWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateOutline() }
        outlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func updateOutline() {
        let new = Self.outline(of: source)
        if new != outline { outline = new }
    }

    static func outline(of text: String) -> [OutlineItem] {
        let levels = ["part": 0, "chapter": 0, "section": 1, "subsection": 2, "subsubsection": 3]
        var items: [OutlineItem] = []
        var exercice = 0
        var lineNo = 0
        text.enumerateLines { line, _ in
            lineNo += 1
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\\") else { return }
            if let r = t.range(of: #"^\\(part|chapter|section|subsection|subsubsection)\*?\{"#, options: .regularExpression) {
                let cmd = String(t[r].dropFirst().prefix { $0.isLetter })
                var title = String(t[r.upperBound...])
                if let end = title.lastIndex(of: "}") { title = String(title[..<end]) }
                items.append(OutlineItem(id: lineNo, level: levels[cmd] ?? 1, title: title.isEmpty ? "(sans titre)" : title))
            } else if t.hasPrefix("\\begin{exercice") {
                exercice += 1
                let opts = LatexCompletion.matches(#"\[([^\]]*)\]"#, t)
                let titre = opts.count >= 2 ? opts[1] : ""
                items.append(OutlineItem(id: lineNo, level: 1,
                                         title: "Exercice \(exercice)" + (titre.isEmpty ? "" : " — \(titre)")))
            }
        }
        return items
    }

    @discardableResult
    func save() -> Bool {
        guard let file = currentFile, dirty else { return true }
        do {
            try source.write(to: file, atomically: true, encoding: .utf8)
            savedSource = source
            if watching { snapshot = currentSnapshot() }   // pas de double compilation
            return true
        } catch {
            status = .err(error)
            return false
        }
    }

    func saveAll() {
        save()
        for (url, text) in buffers where text != savedBuffers[url] {
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { savedBuffers[url] = text }
        }
        if watching { snapshot = currentSnapshot() }
    }

    func saveAs() {
        guard let file = currentFile,
              let dest = Panels.save(suggested: file.lastPathComponent, type: .tex,
                                     directory: file.deletingLastPathComponent()) else { return }
        do {
            try source.write(to: dest, atomically: true, encoding: .utf8)
            savedSource = source
            if Self.same(file, texURL) { open(dest) } else { openTab(dest) }
            status = .ok("Enregistré sous \(dest.lastPathComponent)")
        } catch {
            status = .err(error)
        }
    }

    /// Texte actuel d'un fichier du projet (onglet ouvert ou disque).
    func text(of file: URL) -> String {
        if Self.same(file, currentFile) { return source }
        if let b = buffers.first(where: { Self.same($0.key, file) })?.value { return b }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    // MARK: IA

    func explain(_ issue: LatexIssue) {
        guard let dir = folder else { return }
        let file = issue.file.map { URL(fileURLWithPath: $0, relativeTo: dir).standardizedFileURL } ?? texURL
        let text = file.map { self.text(of: $0) } ?? ""
        reveal(issue)
        ai.explain(issue: issue, file: file, text: text, log: log)
    }

    /// Applique les lignes corrigées proposées par l'IA (annulable avec ⌘Z).
    func applySuggestion() {
        guard let s = ai.suggestion, let target = ai.suggestionTarget else { return }
        show(target.file, line: nil)
        send(.replaceLines(from: target.from, to: target.to, with: s))
        ai.showExplain = false
    }

    /// Restaure la version d'un fichier tirée de l'historique (annulable avec ⌘Z).
    func restore(_ text: String, file: URL) {
        show(file, line: nil)
        send(.replaceAll(text))
        showHistory = false
        status = .ok("Version restaurée dans \(file.lastPathComponent) (⌘Z pour annuler).")
    }
}

/// Ouvre un fichier à la bonne ligne dans VS Code si présent, sinon dans l'éditeur par défaut.
enum Editor {
    static var vscode: String? {
        let insiders = "Visual Studio Code - Insiders.app/Contents/Resources/app/bin"
        let candidates = [
            Shell.which("code-insiders"),
            "/Applications/\(insiders)/code-insiders",
            "/Applications/\(insiders)/code",
            "\(NSHomeDirectory())/Applications/\(insiders)/code-insiders",
            "\(NSHomeDirectory())/Applications/\(insiders)/code",
            Shell.which("code"),
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            "\(NSHomeDirectory())/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func open(_ file: URL, line: Int?) {
        if let code = vscode {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: code)
            p.arguments = ["-g", line.map { "\(file.path):\($0)" } ?? file.path]
            p.environment = Shell.environment
            if (try? p.run()) != nil { return }
        }
        NSWorkspace.shared.open(file)
    }
}

// MARK: - Vue

struct LatexToolView: View {
    @ObservedObject var model: LatexModel
    @ObservedObject var lib = LatexLibraryState.shared
    @ObservedObject var docs = LatexDocsStore.shared

    private var explainShown: Binding<Bool> {
        Binding(get: { model.ai.showExplain }, set: { model.ai.showExplain = $0 })
    }
    private var formulaShown: Binding<Bool> {
        Binding(get: { model.ai.showFormula }, set: { model.ai.showFormula = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .latex)
            if let tex = model.texURL {
                controls(tex)
                    .sheet(isPresented: $model.showHistory) { HistorySheet(model: model) }
                HSplitView {
                    if model.showOutline {
                        outlinePanel
                            .frame(minWidth: 140, idealWidth: 190, maxWidth: 320)
                    }
                    VSplitView {
                        VStack(spacing: 0) {
                            tabBar
                            LatexEditor(text: $model.source, command: model.editorCommand, fontSize: model.fontSize,
                                        folder: model.folder) { line in
                                model.cursorLine = line
                            }
                        }
                        .frame(minHeight: 200)
                        .sheet(isPresented: explainShown) { ExplainSheet(model: model, ai: model.ai) }
                        if model.showDiagnostics {
                            diagnostics
                                .padding(.top, 8)
                                .frame(minHeight: 140, idealHeight: 220)
                        }
                    }
                    .frame(minWidth: 380, idealWidth: 560)
                    preview
                        .frame(minWidth: 320)
                        .sheet(isPresented: formulaShown) { FormulaSheet(model: model, ai: model.ai) }
                }
            } else {
                DropZone(title: "Dépose ton fichier .tex principal",
                         subtitle: "Éditeur intégré avec aperçu PDF côte à côte, compilation ⌘B, erreurs cliquables et expliquées par l'IA, recompilation pendant la frappe.",
                         types: [.tex], multiple: false) { urls in
                    if let u = urls.first { model.open(u) }
                }
                HStack(spacing: 16) {
                    Button { model.newDocument() } label: {
                        Label("Nouveau document…", systemImage: "square.and.pencil")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Choisis TD, TP, cours, rapport ou autre : un modèle pré-rempli est créé et ouvert (⇧⌘N)")
                    .tourTarget("latex.new")
                    Button { model.showNewProject = true } label: {
                        Label("Depuis un modèle…", systemImage: "doc.badge.plus")
                    }
                    .controlSize(.large)
                    libraryButton(compact: false)
                        .controlSize(.large)
                    Spacer()
                    toolsInfo
                }
                LatexDocsList(model: model)
                    .tourTarget("latex.docs")
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
            }
            StatusBanner(message: model.status)
        }
        .padding(20)
        .sheet(isPresented: $model.showNewProject) { NewProjectSheet(model: model) }
        .background(NewDocSheetHost(model: model))
    }

    // MARK: Mes documents

    private var docsButton: some View {
        Button { LatexDocsStore.shared.showPopover.toggle() } label: { Image(systemName: "doc.on.doc") }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .help("Mes documents LaTeX : rouvrir, modifier ou supprimer (⇧⌘O)")
            .tourTarget("latex.docs")
            .popover(isPresented: $docs.showPopover, arrowEdge: .bottom) {
                LatexDocsList(model: model, compact: true)
                    .padding(14)
                    .frame(width: 460, height: 480)
            }
    }

    // MARK: Symboles & formules

    private func libraryButton(compact: Bool) -> some View {
        Button { lib.show.toggle() } label: {
            if compact {
                Label("Symboles", systemImage: "x.squareroot")
            } else {
                Label("Symboles & formules", systemImage: "x.squareroot")
            }
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .help("Bibliothèque de symboles et formules LaTeX : ensembles, logique, limites, dérivées… (⇧⌘M)")
        .popover(isPresented: $lib.show, arrowEdge: .bottom) { LatexLibraryView(model: model) }
        .tourTarget("latex.symbols")
    }

    // MARK: Barre de contrôle

    private func controls(_ tex: URL) -> some View {
        HStack(spacing: 10) {
            Button { model.showOutline.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("Afficher / masquer le plan du document")
            Image(systemName: "doc.plaintext").font(.title2).foregroundStyle(Color.indigo)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tex.lastPathComponent).font(.headline)
                    Text(model.dirty ? "● modifié" : "enregistré")
                        .font(.caption)
                        .foregroundStyle(model.dirty ? Color.orange : Color.secondary)
                }
                Text(tex.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            docsButton
            libraryButton(compact: true)
            Button { model.ai.openFormula() } label: { Image(systemName: "camera.viewfinder") }
                .help("Formule depuis une photo ou une capture → LaTeX (IA locale)")
            Button { model.showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("Historique : une version est gardée à chaque compilation")
            Picker("Moteur", selection: $model.engine) {
                ForEach(LatexEngine.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Auto", isOn: Binding(get: { model.watching }, set: { model.setWatching($0) }))
                .toggleStyle(.switch)
                .help("Recompiler automatiquement une seconde après ta dernière frappe (ou quand un fichier du dossier change)")
            Button { model.save() } label: { Image(systemName: "square.and.arrow.down") }
                .keyboardShortcut("s")
                .help("Enregistrer (⌘S) — l'enregistrement est aussi automatique après 1 s")
            Button { model.showDiagnostics.toggle() } label: {
                Image(systemName: model.showDiagnostics ? "rectangle.bottomthird.inset.filled" : "rectangle")
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .help("Afficher / masquer les erreurs et le journal (⇧⌘J)")
            Button { model.compile() } label: {
                Label("Compiler", systemImage: "play.fill")
            }
            .tourTarget("latex.compile")
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("b")
            .help("Compiler (⌘B ou ⌘↩)")
            .disabled(model.compiling)
            Button("") { model.compile() }
                .keyboardShortcut(.return)
                .frame(width: 0, height: 0).opacity(0)
            Menu {
                Button("Ouvrir le PDF") { if let u = model.pdfURL { NSWorkspace.shared.open(u) } }
                    .disabled(!model.pdfExists)
                Button("Afficher dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.pdfExists ? model.pdfURL! : tex])
                }
                Button("Enregistrer sous…") { model.saveAs() }
                Button("Ouvrir dans un éditeur externe") {
                    model.save()
                    Editor.open(model.currentFile ?? tex, line: model.cursorLine)
                }
                Divider()
                Button("Formule depuis une image…") { model.ai.openFormula() }
                Button("Historique des versions…") { model.showHistory = true }
                Divider()
                Button("Agrandir le texte") { model.fontSize = min(28, model.fontSize + 1) }
                Button("Réduire le texte") { model.fontSize = max(9, model.fontSize - 1) }
                Divider()
                Button("Nettoyer les fichiers auxiliaires") { model.clean() }
                Divider()
                Button("Nouveau document…") { model.newDocument() }
                Button("Nouveau projet depuis un modèle…") { model.showNewProject = true }
                Button("Choisir un autre .tex…") {
                    if let u = Panels.open([.tex]).first { model.open(u) }
                }
                Button("Mes documents…") { docs.showPopover = true }
                Button("Supprimer ce document…") {
                    if let doc = docs.docs.first(where: { $0.url.path == tex.path }) {
                        docs.delete(doc, model: model)
                    } else {
                        docs.delete(LatexDocsStore.Doc(url: tex, kind: "ouvert", title: LatexDocsStore.guessTitle(tex), matiere: "",
                                                       modified: Date(), createdByToolbox: false), model: model)
                    }
                }
                Button("Fermer") { model.close() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Onglets

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.tabs, id: \.self) { url in
                    TabChip(url: url,
                            current: LatexModel.same(url, model.currentFile),
                            main: LatexModel.same(url, model.texURL),
                            dirty: model.isDirty(url),
                            onSelect: { model.select(url) },
                            onClose: { model.closeTab(url) })
                }
                Button {
                    if let u = Panels.open([.tex]).first { model.openTab(u) }
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 6)
                    .help("Ouvrir un autre fichier .tex dans un onglet")
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Plan

    private var outlinePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan").font(.subheadline.bold()).padding(.leading, 4)
            if model.outline.isEmpty {
                Text("Pas de \\section ni d'exercice dans ce fichier.")
                    .font(.caption).foregroundStyle(.secondary).padding(4)
                Spacer()
            } else {
                List(model.outline) { item in
                    Text(item.title)
                        .font(item.level <= 1 ? .callout.bold() : .callout)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(max(0, item.level - 1)) * 12)
                        .contentShape(Rectangle())
                        .onTapGesture { model.send(.goTo(line: item.id)) }
                        .help("Ligne \(item.id)")
                }
                .listStyle(.sidebar)
            }
        }
        .padding(.trailing, 6)
    }

    // MARK: Erreurs + journal

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if !model.issues.isEmpty {
                List(model.issues) { issue in
                    IssueRow(issue: issue) { model.explain(issue) }
                        .contentShape(Rectangle())
                        .onTapGesture { model.reveal(issue) }
                        .help("Clic : aller à cette ligne dans l'éditeur")
                }
                .listStyle(.inset)
                .frame(minHeight: 70, maxHeight: 160)
            }
            HStack {
                Text("Journal").font(.subheadline.bold())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log, forType: .string)
                } label: { Label("Copier", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.borderless)
                    .disabled(model.log.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.log.isEmpty ? "Le journal de compilation s'affichera ici (⌘B pour compiler)." : model.log)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.log.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .onChange(of: model.log) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var summary: some View {
        if model.compiling {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Compilation en cours…")
            }
        } else if let ok = model.lastSuccess {
            HStack(spacing: 12) {
                Label(ok ? "Compilé" : "Échec", systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
                    .font(.headline)
                Text("\(model.errorCount) erreur(s) · \(model.warningCount) avertissement(s) · \(String(format: "%.1f", model.lastDuration)) s")
                    .foregroundStyle(.secondary)
            }
        }
        if let st = model.stats {
            VStack(alignment: .leading, spacing: 3) {
                if let w = st.words {
                    Text("\(w) mots (\(st.wordSource))").font(.callout)
                }
                if !st.undefinedReferences.isEmpty {
                    Text("Références indéfinies : " + st.undefinedReferences.joined(separator: ", "))
                        .font(.caption).foregroundStyle(Color.orange).lineLimit(2)
                }
                if !st.undefinedCitations.isEmpty {
                    Text("Citations indéfinies : " + st.undefinedCitations.joined(separator: ", "))
                        .font(.caption).foregroundStyle(Color.orange).lineLimit(2)
                }
            }
        }
    }

    // MARK: Aperçu

    private var preview: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("⌘-clic dans le PDF → ligne du code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.forwardSearch() } label: {
                    Label("Curseur → PDF", systemImage: "arrow.right.doc.on.clipboard")
                }
                .keyboardShortcut("l")
                .help("Montre dans le PDF l'endroit où se trouve le curseur (⌘L)")
                .disabled(!model.pdfExists)
            }
            .padding(.leading, 8)
            pdfArea
        }
    }

    private var pdfArea: some View {
        ZStack {
            SyncPDFPreview(url: model.pdfURL, reloadToken: model.reloadToken, jump: model.jump) { index, point, box in
                model.inverseSearch(pageIndex: index, point: point, mediaBox: box)
            }
            if !model.pdfExists {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark").font(.system(size: 36, weight: .light))
                    Text("Pas encore de PDF — lance une compilation (⌘B).")
                }
                .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 8)
    }

    // MARK: Outils installés

    private var toolsInfo: some View {
        let tools: [(String, Bool)] = [
            ("latexmk", Latex.latexmkPath != nil),
            ("pdflatex", Latex.isAvailable(.pdflatex)),
            ("xelatex", Latex.isAvailable(.xelatex)),
            ("lualatex", Latex.isAvailable(.lualatex)),
        ]
        let anyEngine = tools.dropFirst().contains { $0.1 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach(tools, id: \.0) { tool in
                    Label(tool.0, systemImage: tool.1 ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(tool.1 ? Color.green : Color.secondary)
                }
            }
            if !anyEngine {
                Text("Aucune distribution LaTeX trouvée. Installe MacTeX : brew install --cask mactex-no-gui")
                    .font(.caption).foregroundStyle(Color.orange).textSelection(.enabled)
            }
        }
    }
}

struct TabChip: View {
    let url: URL
    let current: Bool
    let main: Bool
    let dirty: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: main ? "star.fill" : "doc.text")
                .font(.caption2)
                .foregroundStyle(main ? Color.yellow : Color.secondary)
            Text(url.lastPathComponent).font(.callout)
            if dirty { Circle().fill(Color.orange).frame(width: 6, height: 6) }
            if !main {
                Button(action: onClose) { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(current ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(main ? "Fichier principal (celui qu'on compile)" : url.path)
    }
}

struct IssueRow: View {
    let issue: LatexIssue
    var onExplain: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: issue.isWarning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(issue.isWarning ? Color.orange : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message).lineLimit(3)
                if !issue.location.isEmpty {
                    Text(issue.location).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !issue.isWarning, let explain = onExplain {
                Button(action: explain) { Label("Expliquer", systemImage: "sparkles") }
                    .buttonStyle(.borderless)
                    .help("Explication et correction proposées par l'IA locale (Ollama)")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Aperçu avec SyncTeX

struct PDFJump: Equatable {
    let page: Int
    let x: Double
    let y: Double
    let token: Int
}

final class SyncPDFView: PDFView {
    var onCommandClick: ((Int, CGPoint, CGRect) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let doc = document {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = page(for: viewPoint, nearest: true) {
                let p = convert(viewPoint, to: page)
                onCommandClick?(doc.index(for: page), p, page.bounds(for: .mediaBox))
                return
            }
        }
        super.mouseDown(with: event)
    }
}

struct SyncPDFPreview: NSViewRepresentable {
    let url: URL?
    let reloadToken: Int
    let jump: PDFJump?
    let onCommandClick: (Int, CGPoint, CGRect) -> Void

    final class Coordinator {
        var token = Int.min
        var url: URL?
        var jumpToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        view.onCommandClick = onCommandClick
        let c = context.coordinator

        if c.token != reloadToken || c.url != url {
            c.token = reloadToken
            c.url = url
            var pageIndex = 0
            if let doc = view.document, let current = view.currentPage {
                pageIndex = doc.index(for: current)
            }
            if let url = url, let doc = PDFDocument(url: url), doc.pageCount > 0 {
                view.document = doc
                if let page = doc.page(at: min(pageIndex, doc.pageCount - 1)) { view.go(to: page) }
            } else {
                view.document = nil
            }
        }

        if let j = jump, j.token != c.jumpToken, let doc = view.document,
           j.page >= 1, j.page <= doc.pageCount, let page = doc.page(at: j.page - 1) {
            c.jumpToken = j.token
            let box = page.bounds(for: .mediaBox)
            let point = CGPoint(x: box.minX + CGFloat(j.x), y: box.maxY - CGFloat(j.y) + 60)
            view.go(to: PDFDestination(page: page, at: point))
        }
    }
}

// MARK: - Nouveau projet

struct NewProjectSheet: View {
    @ObservedObject var model: LatexModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nouveau projet LaTeX").font(.title2.bold())
            Picker("Modèle", selection: $model.newTemplate) {
                ForEach(LatexTemplate.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(model.newTemplate.summary).font(.caption).foregroundStyle(.secondary)
            TextField("Titre", text: $model.newTitle, prompt: Text("Ex. : Analyse 1 — Suites réelles"))
            TextField("Auteur", text: $model.newAuthor)
            Text("Un dossier portant le nom du titre est créé avec main.tex, puis compilé et ouvert dans l'éditeur intégré.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { model.showNewProject = false }
                    .keyboardShortcut(.cancelAction)
                Button("Créer…") {
                    if let dir = Panels.folder(prompt: "Créer ici") { model.createProject(in: dir) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
