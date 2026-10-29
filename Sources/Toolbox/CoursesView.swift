import SwiftUI
import AppKit
import Quartz
import EventKit
import UniformTypeIdentifiers
import PDFCore

/// Réglages propres à une matière : nom affiché, couleur, autres noms (pour le calendrier).
struct CourseCustom: Codable, Equatable {
    var name: String?
    var color: Int?
    var aliases: String = ""
}

final class CoursesStore: ObservableObject {
    static let shared = CoursesStore()

    @Published var root: URL? {
        didSet { UserDefaults.standard.set(root?.path, forKey: "courses.root"); scan() }
    }
    @Published var courses: [Course] = []
    @Published var selectedID: String? { didSet { if oldValue != selectedID { selectedItem = nil } } }
    @Published var selectedItem: CourseItem? { didSet { folderPreview = nil; if selectedItem != nil { selectedHit = nil } } }
    @Published var query = "" { didSet { searchContent() } }
    @Published var scanning = false
    @Published var custom: [String: CourseCustom] = [:] { didSet { saveCustom() } }
    @Published var editing: Course?
    @Published var now: (course: Course, title: String, end: Date)?
    @Published var status: StatusMessage?
    @Published var recents: [String] = UserDefaults.standard.stringArray(forKey: "courses.recents") ?? []
    @Published var folderPreview: URL?          // fichier choisi dans la liste d'un dossier de TP
    @Published var hits: [ContentHit] = []      // recherche dans le contenu
    @Published var selectedHit: ContentHit?
    @Published var indexing: (done: Int, total: Int)?
    @Published var indexedCount = 0
    private var notified: Set<String> = []
    private var searchWork: DispatchWorkItem?

    private let events = EKEventStore()
    private var timer: Timer?

    static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .mint, .brown]

    init() {
        if let p = UserDefaults.standard.string(forKey: "courses.root") {
            root = URL(fileURLWithPath: p)
        } else {
            let guess = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Nextcloud/cours/uapv-cours/cours")
            if FileManager.default.fileExists(atPath: guess.path) { root = guess }
        }
        if let data = UserDefaults.standard.data(forKey: "courses.custom"),
           let c = try? JSONDecoder().decode([String: CourseCustom].self, from: data) { custom = c }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.updateNow() }
    }

    private func saveCustom() {
        if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: "courses.custom") }
    }

    // MARK: Lecture du dossier

    func scan() {
        guard let root = root else { courses = []; return }
        scanning = true
        runInBackground({ CourseLibrary.scan(root: root) }) { [weak self] r in
            guard let self = self else { return }
            self.scanning = false
            if case .success(let list) = r {
                self.courses = list
                if self.selectedID == nil || !list.contains(where: { $0.id == self.selectedID }) {
                    self.selectedID = list.first?.id
                }
                if let item = self.selectedItem, !FileManager.default.fileExists(atPath: item.url.path) { self.selectedItem = nil }
                self.updateNow()
                self.indexIfNeeded()
            }
        }
    }

    var selected: Course? { courses.first { $0.id == selectedID } }

    func name(_ c: Course) -> String { custom[c.id]?.name ?? c.name }

    func color(_ c: Course) -> Color {
        if let i = custom[c.id]?.color { return Self.palette[i % Self.palette.count] }
        // couleur stable d'un lancement à l'autre (pas de hashValue, qui change)
        let n = c.folderName.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[n % Self.palette.count]
    }

    var domains: [(String, [Course])] {
        var out: [(String, [Course])] = []
        for c in courses {
            if let i = out.firstIndex(where: { $0.0 == c.domain }) { out[i].1.append(c) } else { out.append((c.domain, [c])) }
        }
        return out
    }

    func select(_ c: Course) {
        selectedID = c.id
        query = ""
    }

    // MARK: Recherche dans tous les cours

    var results: [(Course, CourseSession, CourseItem)] { search(query) }

    func search(_ text: String) -> [(Course, CourseSession, CourseItem)] {
        let q = CourseLibrary.fold(text.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        let words = q.split(separator: " ").map(String.init)
        var out: [(Course, CourseSession, CourseItem)] = []
        for c in courses {
            let cname = CourseLibrary.fold(name(c) + " " + c.folderName + " " + (custom[c.id]?.aliases ?? ""))
            for s in c.sessions {
                for it in s.items {
                    let hay = cname + " " + CourseLibrary.fold(s.title + " " + it.url.lastPathComponent + " " + it.title)
                    if words.allSatisfy({ hay.contains($0) }) { out.append((c, s, it)) }
                }
            }
        }
        return Array(out.prefix(80))
    }

    // MARK: Index plein texte

    private var indexRunning = false

    /// Tous les documents lisibles des matières (y compris dans les dossiers de TP), hors éléments masqués.
    var indexableFiles: [URL] {
        var out: [URL] = []
        for c in courses {
            for sess in c.sessions {
                for it in sess.items {
                    if it.isFolder {
                        if let e = FileManager.default.enumerator(at: it.url, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) {
                            var n = 0
                            for case let f as URL in e where CourseIndex.indexable(f) {
                                out.append(f); n += 1
                                if n > 150 { break }
                            }
                        }
                    } else if CourseIndex.indexable(it.url) {
                        out.append(it.url)
                    }
                }
            }
        }
        return out
    }

    func indexIfNeeded() {
        guard !indexRunning, !courses.isEmpty else { return }
        indexRunning = true
        let files = indexableFiles
        DispatchQueue.global(qos: .utility).async { [weak self] in
            CourseIndex.shared.update(files: files) { done, total in
                DispatchQueue.main.async { self?.indexing = total > 0 && done < total ? (done, total) : nil }
            }
            DispatchQueue.main.async {
                self?.indexRunning = false
                self?.indexing = nil
                self?.indexedCount = CourseIndex.shared.count
                self?.searchContent()
            }
        }
    }

    private func searchContent() {
        searchWork?.cancel()
        let q = query
        guard q.trimmingCharacters(in: .whitespaces).count >= 3 else { hits = []; return }
        let w = DispatchWorkItem { [weak self] in
            let found = CourseIndex.shared.search(q)
            DispatchQueue.main.async { if self?.query == q { self?.hits = found } }
        }
        searchWork = w
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    /// Matière d'un fichier (pour afficher les résultats du contenu).
    func course(containing url: URL) -> Course? {
        courses.first { url.path.hasPrefix($0.url.path + "/") }
    }

    // MARK: Ouvrir

    /// Code / dossier de TP → VS Code Insiders ; .tex → éditeur LaTeX de Toolbox ; le reste → app par défaut.
    func open(_ item: CourseItem) {
        remember(item.url)
        let code: Set<String> = ["py", "c", "h", "cpp", "hpp", "java", "js", "ts", "php", "html", "css", "sh", "ml", "rs",
                                 "go", "cs", "kt", "swift", "sql", "json", "ipynb", "md", "txt", "csv", "ino", "makefile"]
        if item.isFolder {
            VSCode.open(item.url)
        } else if item.ext == "tex" {
            AppRouter.shared.incoming = [item.url]
        } else if code.contains(item.ext) || item.url.lastPathComponent.lowercased() == "makefile" {
            VSCode.open(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func remember(_ url: URL) {
        recents.removeAll { $0 == url.path }
        recents.insert(url.path, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        UserDefaults.standard.set(recents, forKey: "courses.recents")
    }

    /// Fichiers récemment ouverts, avec leur matière.
    var recentItems: [(Course, CourseItem)] {
        recents.compactMap { path in
            for c in courses {
                for s in c.sessions {
                    if let it = s.items.first(where: { $0.url.path == path }) { return (c, it) }
                }
            }
            return nil
        }
    }

    // MARK: Créer / importer

    /// Nouveau dossier TDn / TPn (numéro suivant) puis ouverture dans VS Code Insiders.
    func newSession(_ kind: CourseKind, in c: Course) {
        let n = c.nextNumber(kind)
        let dir = c.folder(for: kind).appendingPathComponent("\(kind.sessionPrefix)\(n)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            remember(dir)
            VSCode.open(dir)
            status = .ok("\(kind.sessionPrefix) \(n) créé dans \(name(c)) et ouvert dans VS Code Insiders.")
            scan()
        } catch {
            status = .err(error)
        }
    }

    /// Dernier TD ou TP sur lequel tu as travaillé (le plus récemment modifié) : ouvert directement.
    func latest(_ c: Course) -> CourseSession? {
        c.sessions.filter { ($0.kind == .td || $0.kind == .tp) && $0.number != nil && !CourseMarks.shared.isHidden(c, $0) }
            .max { $0.modified < $1.modified }
    }

    func openLatest(_ c: Course) {
        select(c)
        AppRouter.shared.show = .courses
        if let sess = latest(c), let first = sess.items.first(where: { !$0.isCorrection }) ?? sess.items.first {
            selectedItem = first
            open(first)
        } else {
            status = .info("Pas encore de TD/TP dans \(name(c)).")
        }
    }

    // MARK: Notes de séance

    static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Note du jour dans <matière>/notes/ (Markdown → VS Code Insiders, LaTeX → éditeur de Toolbox).
    func newNote(in c: Course, latex: Bool) {
        let dir = c.folder(for: .notes)
        let file = dir.appendingPathComponent(Self.dayStamp.string(from: Date()) + (latex ? ".tex" : ".md"))
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) {
                let date = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .none)
                let template = latex ? Self.latexNote(title: name(c), date: date) : "# \(name(c)) — \(date)\n\n"
                try template.write(to: file, atomically: true, encoding: .utf8)
            }
            remember(file)
            if latex { AppRouter.shared.incoming = [file] } else { VSCode.open(file) }
            scan()
        } catch {
            status = .err(error)
        }
    }

    static func latexNote(title: String, date: String) -> String {
        "\\documentclass[a4paper,11pt]{article}\n\\usepackage[utf8]{inputenc}\n\\usepackage[T1]{fontenc}\n"
        + "\\usepackage[french]{babel}\n\\usepackage{amsmath,amssymb}\n\\usepackage[margin=2cm]{geometry}\n\n"
        + "\\title{\(title)}\n\\date{\(date)}\n\\author{}\n\n\\begin{document}\n\\maketitle\n\n\n\n\\end{document}\n"
    }

    /// Photos du tableau : rangées dans notes/photos <date>/, puis lues par OCR (cherchables).
    func importPhotos(_ urls: [URL], into c: Course) {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        let dir = c.folder(for: .notes).appendingPathComponent("photos " + f.string(from: Date()), isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var done: [URL] = []
        for u in urls {
            let dest = FileUtils.unique(dir.appendingPathComponent(u.lastPathComponent))
            if (try? fm.copyItem(at: u, to: dest)) != nil { done.append(dest) }
        }
        status = .ok("\(done.count) photo(s) rangée(s) dans \(name(c)) › Notes. Le texte est lu en arrière-plan : il sera cherchable.", files: done)
        scan()
    }

    /// Fichiers déposés sur une matière : copiés dans cours/, TDs/, TPs/ ou CCs/ selon leur nom.
    func importFiles(_ urls: [URL], into c: Course, kind forced: CourseKind? = nil) {
        let fm = FileManager.default
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]
        let photos = urls.filter { imageExts.contains($0.pathExtension.lowercased()) && CourseKind.guess(fileName: $0.lastPathComponent) == .autre }
        if forced == nil && !photos.isEmpty { importPhotos(photos, into: c) }
        var done: [URL] = []
        for u in urls where forced != nil || !photos.contains(u) {
            let kind = forced ?? CourseKind.guess(fileName: u.lastPathComponent)
            let dir = kind == .autre ? c.url : c.folder(for: kind)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = FileUtils.unique(dir.appendingPathComponent(u.lastPathComponent))
            if (try? fm.copyItem(at: u, to: dest)) != nil { done.append(dest) }
        }
        if !done.isEmpty {
            status = .ok("\(done.count) fichier(s) rangé(s) dans \(name(c)) (copie : l'original n'a pas bougé).", files: done)
        } else if photos.isEmpty {
            status = .err("Rien n'a pu être copié.")
        }
        scan()
    }

    // MARK: Cours en ce moment (calendrier)

    func updateNow() {
        guard HomeStore.hasAccess, !courses.isEmpty else { now = nil; return }
        let start = Date().addingTimeInterval(-60), end = Date().addingTimeInterval(20 * 60)
        let list = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > Date() }
            .sorted { $0.startDate < $1.startDate }
        for e in list {
            let title = CourseLibrary.fold(e.title ?? "")
            if let c = courses.first(where: { matches(title, $0) }) {
                now = (c, e.title ?? "", e.endDate)
                let key = (e.eventIdentifier ?? title) + "\(e.startDate.timeIntervalSince1970)"
                if !notified.contains(key), e.startDate.timeIntervalSinceNow < 6 * 60,
                   UserDefaults.standard.object(forKey: "courses.notify") as? Bool ?? true {
                    notified.insert(key)
                    let last = latest(c).map { "\($0.title)" + ($0.subtitle.isEmpty ? "" : " (\($0.subtitle))") }
                    CourseAlerts.notify(course: c, name: name(c), event: e.title ?? name(c), latest: last)
                }
                return
            }
        }
        now = nil
    }

    /// Matière correspondant à un titre déjà « plié » (minuscules, sans accents).
    func courseMatching(_ folded: String) -> Course? { courses.first { matches(folded, $0) } }

    private func matches(_ title: String, _ c: Course) -> Bool {
        var keys = [name(c), c.name, CourseLibrary.prettify(c.folderName).replacingOccurrences(of: #" \(S\d\)"#, with: "",
                                                                                               options: .regularExpression)]
        keys += (custom[c.id]?.aliases ?? "").split(separator: ",").map { String($0) }
        return keys.map { CourseLibrary.fold($0).trimmingCharacters(in: .whitespaces) }
            .contains { $0.count >= 3 && title.contains($0) }
    }
}

// MARK: - Aperçu Coup d'œil

struct QuickLookPreview: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL)?.path != url?.path {
            v.previewItem = url as NSURL?
        }
    }
}

// MARK: - Vue

struct CoursesToolView: View {
    @ObservedObject var s: CoursesStore
    @ObservedObject var marks = CourseMarks.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .courses)
            if s.root == nil {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                    Text("Choisis le dossier où sont rangés tes cours.")
                    Button("Choisir le dossier…") { if let u = Panels.folder(prompt: "Mes cours sont ici") { s.root = u } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 210, idealWidth: 240, maxWidth: 320).tourTarget("courses.subjects")
                    middle.frame(minWidth: 420, idealWidth: 560).tourTarget("courses.middle")
                    preview.frame(minWidth: 280, idealWidth: 380).tourTarget("courses.preview")
                }
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
        .sheet(item: $s.editing) { c in CourseEditSheet(s: s, course: c) }
    }

    // MARK: Matières

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Chercher (noms et contenu)", text: $s.query)
                    .textFieldStyle(.plain)
                if !s.query.isEmpty {
                    Button { s.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .tourTarget("courses.search")

            List(selection: Binding(get: { s.selectedID }, set: { if let id = $0 { s.selectedID = id; s.query = "" } })) {
                ForEach(s.domains, id: \.0) { entry in
                    Section(entry.0) {
                        ForEach(entry.1) { c in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3).fill(s.color(c)).frame(width: 10, height: 10)
                                Text(s.name(c)).lineLimit(1)
                                Spacer()
                                if s.now?.course.id == c.id {
                                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.red)
                                        .help("Cours en ce moment")
                                }
                                let p = marks.progress(c)
                                if p.done > 0 {
                                    Circle().trim(from: 0, to: CGFloat(p.done) / CGFloat(max(1, p.total)))
                                        .stroke(s.color(c), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: 12, height: 12)
                                        .help("\(p.done)/\(p.total) séances faites")
                                }
                                Text("\(c.itemCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .tag(c.id)
                            .contextMenu {
                                Button("Renommer, couleur, alias…") { s.editing = c }
                                Button("Ouvrir dans VS Code Insiders") { VSCode.open(c.url) }
                                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            HStack {
                Button { s.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Relire le dossier")
                if s.scanning { ProgressView().controlSize(.small) }
                if let ix = s.indexing {
                    Text("Index \(ix.done)/\(ix.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Lecture du contenu des documents pour la recherche")
                }
                Spacer()
                Button("Dossier…") { if let u = Panels.folder(directory: s.root, prompt: "Mes cours sont ici") { s.root = u } }
                    .buttonStyle(.borderless).font(.caption)
                    .help(s.root?.path ?? "")
            }
        }
        .padding(.trailing, 8)
    }

    // MARK: Page de la matière ou résultats de recherche

    @ViewBuilder
    private var middle: some View {
        if !s.query.isEmpty {
            searchResults
        } else if let c = s.selected {
            coursePage(c)
        } else {
            Text("Aucune matière trouvée dans ce dossier.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchResults: some View {
        let results = s.results
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(results.isEmpty && s.hits.isEmpty ? "Aucun résultat" : "Fichiers : \(results.count)").font(.headline)
                ForEach(results, id: \.2.id) { r in
                    let c = r.0, session = r.1, item = r.2
                    HStack(spacing: 10) {
                        FileBadge(item: item)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(s.name(c)) · \(session.title)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(s.selectedItem == item ? s.color(c).opacity(0.18) : Color.primary.opacity(0.03)))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { s.open(item) }
                    .onTapGesture { s.selectedItem = item }
                }
                if !s.hits.isEmpty {
                    Text("Dans le contenu : \(s.hits.count)\(s.hits.count >= 40 ? "+" : "")").font(.headline).padding(.top, 8)
                    ForEach(s.hits) { h in
                        let c = s.course(containing: h.url)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "text.magnifyingglass").foregroundStyle(c.map { s.color($0) } ?? Color.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.url.lastPathComponent + (h.page.map { " — page \($0 + 1)" } ?? ""))
                                    .font(.callout.weight(.medium)).lineLimit(1)
                                Text(h.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                if let c = c { Text(s.name(c)).font(.caption2).foregroundStyle(s.color(c)) }
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(s.selectedHit == h ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.03)))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { s.remember(h.url); NSWorkspace.shared.open(h.url) }
                        .onTapGesture { s.selectedItem = nil; s.selectedHit = h }
                    }
                }
                if let ix = s.indexing {
                    HStack { ProgressView().controlSize(.small); Text("Indexation du contenu… \(ix.done)/\(ix.total)").font(.caption) }
                        .foregroundStyle(.secondary).padding(.top, 6)
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func coursePage(_ c: Course) -> some View {
        let color = s.color(c)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // En-tête
                HStack(alignment: .center, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10).fill(color.gradient).frame(width: 44, height: 44)
                        .overlay(Text(String(s.name(c).prefix(1))).font(.title2.bold()).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name(c)).font(.title2.bold())
                        Text(c.domain).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let last = s.latest(c) {
                        Button { s.openLatest(c) } label: { Label(last.title, systemImage: "play.fill") }
                            .help("Rouvrir le dernier TD/TP sur lequel tu as travaillé")
                    }
                    Menu {
                        Button("Nouveau TP \(c.nextNumber(.tp))") { s.newSession(.tp, in: c) }
                        Button("Nouveau TD \(c.nextNumber(.td))") { s.newSession(.td, in: c) }
                        Divider()
                        Button("Note du jour (Markdown, VS Code)") { s.newNote(in: c, latex: false) }
                        Button("Note du jour (LaTeX, éditeur Toolbox)") { s.newNote(in: c, latex: true) }
                        Button("Photos du tableau…") {
                            let urls = Panels.open([.image], multiple: true)
                            if !urls.isEmpty { s.importPhotos(urls, into: c) }
                        }
                    } label: { Label("Nouveau", systemImage: "plus") }
                        .fixedSize()
                        .help("TP/TD suivant, note du jour, photos du tableau")
                    Button { AppRouter.shared.trainFor = (s.name(c), c.folderName) } label: {
                        Label("S'entraîner", systemImage: "wand.and.stars")
                    }
                    .help("Composer un sujet avec les annales de cette matière (Annalyse)")
                    Button { VSCode.open(c.url) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                        .help("Ouvrir la matière dans VS Code Insiders")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([c.url]) } label: { Image(systemName: "folder") }
                        .help("Afficher dans le Finder")
                    Button { s.editing = c } label: { Image(systemName: "paintpalette") }
                        .help("Renommer, couleur, alias pour le calendrier")
                }

                progressBar(c)

                CourseExamBanner(course: c)

                if let n = s.now, n.course.id == c.id {
                    Label("Cours en ce moment : \(n.title) — jusqu'à \(Self.hour.string(from: n.end))", systemImage: "dot.radiowaves.left.and.right")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
                }

                ForEach(CourseKind.allCases) { kind in
                    let sessions = c.sessions(kind).filter { marks.showHidden || !marks.isHidden(c, $0) }
                    if !sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(kind.title).font(.headline)
                                Text("\(sessions.count)").font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], spacing: 10) {
                                ForEach(sessions) { session in sessionCard(session, course: c, color: color) }
                            }
                        }
                    }
                }
                let hiddenCount = marks.hiddenCount(c)
                if hiddenCount > 0 {
                    Toggle("Afficher les éléments masqués (\(hiddenCount))", isOn: $marks.showHidden)
                        .toggleStyle(.checkbox).font(.caption)
                }
                Text("Dépose des fichiers ici pour les ranger dans cette matière (copiés dans cours/, TDs/, TPs/ ou CCs/ d'après leur nom ; les photos vont dans Notes).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FileDrop.load(providers) { urls in s.importFiles(urls, into: c) }
            return true
        }
    }

    private func progressBar(_ c: Course) -> some View {
        let p = marks.progress(c)
        return HStack(spacing: 10) {
            ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                .tint(s.color(c))
            Text("\(p.done)/\(p.total) séances faites").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func sessionCard(_ session: CourseSession, course c: Course, color: Color) -> some View {
        let key = CourseMarks.key(c, session)
        let mark = marks.mark(c, session)
        let hiddenSession = marks.isHidden(c, session)
        let visible = session.items.filter { marks.showHidden || !marks.isHidden($0) }
        let corrections = visible.filter { $0.isCorrection }
        let shown = marks.revealed.contains(key) ? visible : visible.filter { !$0.isCorrection }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Menu {
                    ForEach(StudyMark.allCases) { m in
                        Button { marks.setMark(m, c, session) } label: { Label(m.title, systemImage: m.icon) }
                    }
                } label: {
                    Image(systemName: mark.icon).foregroundStyle(mark.color)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Avancement : \(mark.title)")
                Text(session.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(Self.day.string(from: session.modified)).font(.caption2).foregroundStyle(.secondary)
            }
            if !session.subtitle.isEmpty {
                Text(session.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(shown) { item in
                HStack(spacing: 6) {
                    FileBadge(item: item)
                    Text(item.isFolder ? item.url.lastPathComponent + "/" : item.url.lastPathComponent)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if item.isCorrection {
                        Text("corrigé").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.purple)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.12)))
                    }
                    if item.isFolder { Text("\(item.childCount)").font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(s.selectedItem == item ? color.opacity(0.22) : Color.clear))
                .opacity(marks.isHidden(item) ? 0.45 : 1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { s.open(item) }
                .onTapGesture { s.selectedItem = item }
                .help("Clic : aperçu · double-clic : ouvrir")
                .contextMenu {
                    Button(marks.isHidden(item) ? "Réafficher ce fichier" : "Masquer ce fichier") { marks.toggleHidden(item.url.path) }
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
            }
            if !corrections.isEmpty && !marks.revealed.contains(key) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { _ = marks.revealed.insert(key) }
                } label: {
                    Label("Voir le corrigé (\(corrections.count))", systemImage: "eye.slash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Le corrigé est caché pour ne pas tomber dessus avant d'avoir cherché")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(mark == .none ? Color.primary.opacity(0.035) : mark.color.opacity(0.08)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 10)
        }
        .opacity(hiddenSession ? 0.45 : 1)
        .contextMenu {
            ForEach(StudyMark.allCases) { m in
                Button { marks.setMark(m, c, session) } label: { Label(m.title, systemImage: m.icon) }
            }
            Divider()
            Button(hiddenSession ? "Réafficher cette séance" : "Masquer cette séance") { marks.toggleHidden(key) }
        }
    }

    // MARK: Aperçu

    @ViewBuilder
    private var preview: some View {
        if let h = s.selectedHit {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "text.magnifyingglass")
                    Text(h.url.lastPathComponent + (h.page.map { " — page \($0 + 1)" } ?? "")).font(.headline).lineLimit(1)
                    Spacer()
                }
                HStack {
                    Button { s.remember(h.url); NSWorkspace.shared.open(h.url) } label: { Label("Ouvrir", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.borderedProminent)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([h.url]) } label: { Image(systemName: "folder") }
                }
                if let page = h.page {
                    PDFHitPreview(url: h.url, page: page, query: s.query).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    QuickLookPreview(url: h.url).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.leading, 8)
        } else if let item = s.selectedItem {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    FileBadge(item: item)
                    Text(item.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button { s.open(item) } label: { Label(openLabel(item), systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.borderedProminent)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                        .help("Afficher dans le Finder")
                    if !item.isFolder && item.ext != "tex" {
                        Button { VSCode.open(item.url.deletingLastPathComponent()) } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }
                        .help("Ouvrir le dossier dans VS Code Insiders")
                    }
                    if item.ext == "pdf" {
                        Button { AppRouter.shared.incoming = [item.url] } label: { Image(systemName: "square.grid.2x2") }
                            .help("Ouvrir dans Toolbox (organiser, annoter…)")
                    }
                    if item.isImage {
                        Button {
                            if let t = CourseIndex.shared.text(of: item.url), !t.isEmpty {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(t, forType: .string)
                                ToastCenter.shared.show("Texte de la photo copié")
                            } else {
                                ToastCenter.shared.show("Texte pas encore lu (ou aucun texte sur la photo).")
                            }
                        } label: { Label("Copier le texte", systemImage: "text.viewfinder") }
                            .help("Texte de la photo, lu hors ligne")
                    }
                }
                if item.isFolder {
                    folderListing(item)
                }
                QuickLookPreview(url: item.isFolder ? (s.folderPreview ?? item.previewFile) : item.url)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.leading, 8)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "eye").font(.system(size: 32, weight: .light))
                Text("Clique un document pour l'aperçu,\ndouble-clique pour l'ouvrir.").multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Contenu d'un dossier de TP : clic = aperçu, double-clic = ouvrir, sous-dossier = Finder / VS Code.
    private func folderListing(_ item: CourseItem) -> some View {
        let files = CourseLibrary.listing(item.url)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Dossier · \(item.childCount) fichier(s) en tout").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.path) { f in
                        let dir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        HStack(spacing: 6) {
                            Image(systemName: dir ? "folder.fill" : "doc")
                                .foregroundStyle(dir ? Color.blue : Color.secondary)
                                .frame(width: 16)
                            Text(f.lastPathComponent + (dir ? "/" : "")).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(s.folderPreview == f ? Color.accentColor.opacity(0.2) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            s.remember(f)
                            if dir { VSCode.open(f) } else if f.pathExtension.lowercased() == "pdf" { NSWorkspace.shared.open(f) } else { VSCode.open(f) }
                        }
                        .onTapGesture { if !dir { s.folderPreview = f } }
                    }
                }
            }
            .frame(maxHeight: 170)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        }
    }

    private func openLabel(_ item: CourseItem) -> String {
        if item.isFolder { return "Ouvrir dans VS Code" }
        switch item.ext {
        case "tex": return "Ouvrir dans l'éditeur LaTeX"
        case "pdf": return "Ouvrir"
        case "py", "c", "cpp", "h", "java", "js", "php", "html", "css", "sh", "md", "txt", "ml", "ino": return "Ouvrir dans VS Code"
        default: return "Ouvrir"
        }
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM"
        return f
    }()
    static let hour: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH'h'mm"
        return f
    }()
}

/// Pastille d'icône selon le type de fichier.
struct FileBadge: View {
    let item: CourseItem

    var body: some View {
        let st = Self.style(item)
        Image(systemName: st.0)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(st.1))
    }

    static func style(_ item: CourseItem) -> (String, Color) {
        if item.isFolder { return ("folder.fill", .blue) }
        switch item.ext {
        case "pdf": return ("doc.richtext.fill", .red)
        case "tex": return ("function", .indigo)
        case "py": return ("chevron.left.forwardslash.chevron.right", Color(red: 0.21, green: 0.45, blue: 0.65))
        case "c", "h", "cpp", "hpp": return ("chevron.left.forwardslash.chevron.right", .gray)
        case "java", "js", "ts", "php", "html", "css": return ("chevron.left.forwardslash.chevron.right", .orange)
        case "sh": return ("terminal.fill", .black)
        case "png", "jpg", "jpeg", "heic", "gif": return ("photo.fill", .teal)
        case "md", "txt": return ("doc.text.fill", .secondary)
        case "pptx", "ppt", "key": return ("play.rectangle.fill", .orange)
        case "zip": return ("archivebox.fill", .brown)
        default: return ("doc.fill", .secondary)
        }
    }
}

/// Nom affiché, couleur et alias (noms utilisés dans le calendrier) d'une matière.
struct CourseEditSheet: View {
    @ObservedObject var s: CoursesStore
    let course: Course
    @StateObject private var form = CourseForm()

    final class CourseForm: ObservableObject {
        @Published var name = ""
        @Published var aliases = ""
        @Published var color = 0
        var loaded = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Matière : \(course.folderName)").font(.title3.bold())
            TextField("Nom affiché", text: $form.name)
            TextField("Autres noms (séparés par des virgules)", text: $form.aliases,
                      prompt: Text("Ex. : Analyse, ANA1 — comme dans ton emploi du temps"))
            Text("Les alias servent à reconnaître le cours dans ton calendrier pour la bannière « Cours en ce moment ».")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<CoursesStore.palette.count, id: \.self) { i in
                    Circle().fill(CoursesStore.palette[i]).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary, lineWidth: form.color == i ? 2.5 : 0).padding(-3))
                        .onTapGesture { form.color = i }
                }
            }
            HStack {
                Button("Par défaut") {
                    s.custom[course.id] = nil
                    s.editing = nil
                }
                Spacer()
                Button("Annuler") { s.editing = nil }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    let n = form.name.trimmingCharacters(in: .whitespaces)
                    s.custom[course.id] = CourseCustom(name: n.isEmpty || n == course.name ? nil : n, color: form.color,
                                                       aliases: form.aliases)
                    s.editing = nil
                    s.updateNow()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            guard !form.loaded else { return }
            form.loaded = true
            form.name = s.name(course)
            form.aliases = s.custom[course.id]?.aliases ?? ""
            form.color = CoursesStore.palette.firstIndex(of: s.color(course)) ?? 0
        }
    }
}

// MARK: - Widget d'accueil « Mes cours »

struct CoursesWidget: View {
    @ObservedObject var s: CoursesStore
    let openCourse: (Course) -> Void

    var body: some View {
        Card(title: "Mes cours", icon: "books.vertical.fill", tint: .orange) {
            if s.courses.isEmpty {
                Text(s.root == nil ? "Choisis ton dossier de cours dans l'onglet « Mes cours »." : "Lecture du dossier…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let n = s.now {
                Button { openCourse(n.course) } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("En ce moment : \(s.name(n.course))").font(.callout.weight(.semibold))
                        Spacer()
                        Text("jusqu'à \(CoursesToolView.hour.string(from: n.end))").font(.caption)
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .foregroundStyle(Color.white)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.gradient))
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(s.courses) { c in
                    Button { openCourse(c) } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 7).fill(s.color(c).gradient).frame(width: 28, height: 28)
                                .overlay(Text(String(s.name(c).prefix(1))).font(.callout.bold()).foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name(c)).font(.callout.weight(.medium)).lineLimit(1)
                                Text(summary(c)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(s.color(c).opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            let recent = s.recentItems.prefix(4)
            if !recent.isEmpty {
                Text("Ouverts récemment").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(Array(recent), id: \.1.id) { r in
                    Button { s.open(r.1) } label: {
                        HStack(spacing: 8) {
                            FileBadge(item: r.1)
                            Text(r.1.url.lastPathComponent).font(.caption).lineLimit(1)
                            Text(s.name(r.0)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func summary(_ c: Course) -> String {
        let kinds: [(CourseKind, String)] = [(.cours, "chap."), (.td, "TD"), (.tp, "TP"), (.cc, "CC")]
        let parts = kinds.compactMap { pair -> String? in
            let n = c.sessions(pair.0).count
            return n > 0 ? "\(n) \(pair.1)" : nil
        }
        return parts.joined(separator: " · ")
    }
}
