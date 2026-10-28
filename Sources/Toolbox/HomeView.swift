import SwiftUI
import AppKit
import Combine
import EventKit
import UniformTypeIdentifiers
import PDFCore

// MARK: - Fichiers récents de Toolbox

enum RecentFiles {
    static let key = "home.recents"

    static var list: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(12)), forKey: key)
    }
}

// MARK: - Dossiers VS Code

struct CodeFolder: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let pinned: Bool
}

enum VSCode {
    static let pinnedKey = "home.vscode.pinned"

    /// VS Code Insiders en priorité, VS Code classique sinon.
    static var app: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCodeInsiders")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
    }

    static func open(_ folder: URL) {
        if let app = app {
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else if let code = Editor.vscode {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: code)
            p.arguments = [folder.path]
            p.environment = Shell.environment
            try? p.run()
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    static var pinned: [URL] {
        (UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func setPinned(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map { $0.path }, forKey: pinnedKey)
    }
}

// MARK: - Événements du jour

struct DayEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String
    let color: Color
}

// MARK: - État de l'accueil

final class HomeStore: ObservableObject {
    @Published var appeared = false
    @Published var pinned: [URL] = VSCode.pinned
    @Published var vscodeRecents: [URL] = []
    @Published var recents: [URL] = []
    @Published var events: [DayEvent] = []
    @Published var calendarAccess: Bool?        // nil = jamais demandé
    @Published var now = Date()

    // Notes (pense-bête)
    @Published var noteDraft = ""
    @Published var pinnedNoteID = UserDefaults.standard.string(forKey: "home.notes.pinned") ?? "" {
        didSet { UserDefaults.standard.set(pinnedNoteID, forKey: "home.notes.pinned") }
    }
    @Published var pinnedTitle = ""
    @Published var pinnedText = ""
    @Published var recentNotes: [AppleNotes.Summary] = []
    @Published var notesStatus = ""
    @Published var notesBusy = false

    // GitHub
    @Published var repos: [GitHubRepo] = []
    @Published var githubStatus = ""
    @Published var githubLoading = false
    @Published var githubVia = ""
    @Published var cloning: String?
    @Published var githubUser = UserDefaults.standard.string(forKey: "home.github.user") ?? "" {
        didSet { UserDefaults.standard.set(githubUser, forKey: "home.github.user") }
    }
    @Published var cloneFolder: URL = {
        if let p = UserDefaults.standard.string(forKey: "home.github.clonedir") { return URL(fileURLWithPath: p) }
        let guess = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Nextcloud/cours/projets-perso/github")
        return FileManager.default.fileExists(atPath: guess.path)
            ? guess : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
    }() {
        didSet { UserDefaults.standard.set(cloneFolder.path, forKey: "home.github.clonedir") }
    }

    private let store = EKEventStore()
    private var clock: Timer?

    // Widgets : disposition, météo, connexion (leurs changements redessinent l'accueil)
    let layout = HomeLayoutStore()
    let weather = WeatherStore()
    let net = Connectivity()
    let exams = ExamsStore()
    @Published var pokeDate: Date?
    private var sinks: [AnyCancellable] = []

    init() {
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.now = Date()
            self?.weather.refresh()          // au plus toutes les 15 min
        }
        for publisher in [layout.objectWillChange, weather.objectWillChange, net.objectWillChange, exams.objectWillChange] {
            sinks.append(publisher.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        // Retour de la connexion : on actualise la météo.
        sinks.append(net.$online.removeDuplicates().sink { [weak self] on in
            if on { DispatchQueue.main.async { self?.weather.refresh() } }
        })
    }

    func refresh() {
        recents = RecentFiles.list
        pinned = VSCode.pinned.filter { FileManager.default.fileExists(atPath: $0.path) }
        runInBackground({ VSCodeRecents.folders(limit: 10) }) { [weak self] r in
            if case .success(let list) = r { self?.vscodeRecents = list }
        }
        loadEvents()
        loadRepos()
        loadPinnedNote()
    }

    // Notes

    func loadPinnedNote() {
        let id = pinnedNoteID
        guard !id.isEmpty else { pinnedTitle = ""; pinnedText = ""; return }
        runInBackground({ try AppleNotes.read(id: id) }) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let c):
                self.pinnedTitle = c.name
                var text = AppleNotes.plainText(c.html)
                // Le corps commence par le titre : on ne le répète pas.
                if text.hasPrefix(c.name) { text = String(text.dropFirst(c.name.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
                self.pinnedText = text
                self.notesStatus = ""
            case .failure(let e):
                self.notesStatus = e.localizedDescription
            }
        }
    }

    func loadRecentNotes() {
        runInBackground({ try AppleNotes.recent() }) { [weak self] r in
            switch r {
            case .success(let list): self?.recentNotes = list
            case .failure(let e): self?.notesStatus = e.localizedDescription
            }
        }
    }

    func pinNote(_ id: String) {
        pinnedNoteID = id
        loadPinnedNote()
    }

    func unpinNote() {
        pinnedNoteID = ""
        pinnedTitle = ""
        pinnedText = ""
    }

    /// Nouvelle note à partir du brouillon (la première ligne sert de titre).
    func createNote() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notesBusy = true
        runInBackground({ try AppleNotes.create(text) }) { [weak self] r in
            guard let self = self else { return }
            self.notesBusy = false
            switch r {
            case .success(let id):
                self.noteDraft = ""
                self.notesStatus = "Note créée dans Notes."
                if self.pinnedNoteID.isEmpty { self.pinNote(id) }
                self.loadRecentNotes()
            case .failure(let e):
                self.notesStatus = e.localizedDescription
            }
        }
    }

    /// Ajoute le brouillon à la fin de la note épinglée.
    func appendToPinned() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = pinnedNoteID
        guard !text.isEmpty, !id.isEmpty else { return }
        notesBusy = true
        runInBackground({ try AppleNotes.append(text, to: id) }) { [weak self] r in
            guard let self = self else { return }
            self.notesBusy = false
            switch r {
            case .success:
                self.noteDraft = ""
                self.notesStatus = ""
                self.loadPinnedNote()
            case .failure(let e):
                self.notesStatus = e.localizedDescription
            }
        }
    }

    // GitHub

    func loadRepos() {
        let user = githubUser
        githubLoading = true
        runInBackground({ try GitHub.repos(user: user, limit: 8) }) { [weak self] r in
            guard let self = self else { return }
            self.githubLoading = false
            switch r {
            case .success(let (list, via)):
                self.repos = list
                self.githubVia = via
                self.githubStatus = list.isEmpty ? "Aucun dépôt." : ""
            case .failure(let e):
                self.repos = []
                self.githubStatus = e.localizedDescription
            }
        }
    }

    /// Le clone local du dépôt s'il existe : dossier de clonage, dossiers épinglés ou récents de VS Code.
    func localClone(_ repo: GitHubRepo) -> URL? {
        let fm = FileManager.default
        let inFolder = cloneFolder.appendingPathComponent(repo.name)
        if fm.fileExists(atPath: inFolder.appendingPathComponent(".git").path) { return inFolder }
        return (pinned + vscodeRecents).first {
            $0.lastPathComponent.caseInsensitiveCompare(repo.name) == .orderedSame
                && fm.fileExists(atPath: $0.appendingPathComponent(".git").path)
        }
    }

    func cloneAndOpen(_ repo: GitHubRepo) {
        cloning = repo.id
        let folder = cloneFolder
        runInBackground({ try GitHub.clone(repo, into: folder) }) { [weak self] r in
            guard let self = self else { return }
            self.cloning = nil
            switch r {
            case .success(let dir):
                self.pin(dir)
                VSCode.open(dir)
            case .failure(let e):
                self.githubStatus = e.localizedDescription
            }
        }
    }

    var githubProfile: URL {
        let login = repos.first.map { String($0.fullName.split(separator: "/").first ?? "") } ?? githubUser
        return URL(string: "https://github.com/" + login) ?? URL(string: "https://github.com")!
    }

    // VS Code

    var codeFolders: [CodeFolder] {
        let pinnedPaths = Set(pinned.map { $0.path })
        return pinned.map { CodeFolder(url: $0, pinned: true) }
            + vscodeRecents.filter { !pinnedPaths.contains($0.path) }.prefix(8).map { CodeFolder(url: $0, pinned: false) }
    }

    func pin(_ url: URL) {
        guard !pinned.contains(where: { $0.path == url.path }) else { return }
        pinned.append(url)
        VSCode.setPinned(pinned)
    }

    func unpin(_ url: URL) {
        pinned.removeAll { $0.path == url.path }
        VSCode.setPinned(pinned)
    }

    func addFolder() {
        if let u = Panels.folder(prompt: "Épingler ce dossier") { pin(u) }
    }

    // Calendrier

    static var hasAccess: Bool {
        // 3 = .fullAccess (macOS 14+) / .authorized (avant)
        EKEventStore.authorizationStatus(for: .event).rawValue == 3
    }

    func loadEvents() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if Self.hasAccess {
            calendarAccess = true
            fetchEvents()
        } else if status == .notDetermined {
            calendarAccess = nil
        } else {
            calendarAccess = false
        }
    }

    func requestAccess() {
        let done: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                self.calendarAccess = granted
                if granted { self.fetchEvents() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in done(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in done(granted) }
        }
    }

    private func fetchEvents() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .sorted { (x: EKEvent, y: EKEvent) -> Bool in
                if x.isAllDay != y.isAllDay { return x.isAllDay }
                return x.startDate < y.startDate
            }
            .map { e in
                DayEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                         title: e.title ?? "(sans titre)", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                         location: e.location ?? "", color: Color(nsColor: e.calendar?.color ?? .systemBlue))
            }
        events = found
    }

    static func openCalendar() {
        let app = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        NSWorkspace.shared.open(app)
    }

    // Mascotte

    /// Humeur : endormie la nuit, sinon selon la météo (si elle est connue).
    var mascotMood: MascotMood {
        let h = Calendar.current.component(.hour, from: now)
        if h >= 23 || h < 6 { return .sleepy }
        guard net.online, let w = weather.now else { return .normal }
        switch w.code {
        case 0, 1: return w.isDay ? .sunny : .normal
        case 51...67, 80...82, 95...99: return .rainy
        case 71...77, 85, 86: return .snowy
        default: return .normal
        }
    }

    func poke() { pokeDate = Date() }

    // Salutation

    var greeting: String {
        let h = Calendar.current.component(.hour, from: now)
        let first = UserProfile.firstName
        let hello = h < 5 ? "Bonne nuit" : (h < 18 ? "Bonjour" : "Bonsoir")
        return first.isEmpty ? hello : "\(hello) \(first)"
    }
}

// MARK: - Vue

struct HomeView: View {
    @ObservedObject var home: HomeStore
    let openTool: (Tool) -> Void
    let openFile: (URL) -> Void
    let newLatex: () -> Void

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()
    private static let hourFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        ZStack {
            AnimatedBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                        .appear(home.appeared, delay: 0)
                    if home.layout.editing {
                        WidgetTray(layout: home.layout, online: home.net.online)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    WidgetFlowLayout(spacing: 18) {
                        ForEach(Array(visibleSlots.enumerated()), id: \.element.id) { index, slot in
                            widget(slot.widget)
                                .appear(home.appeared, delay: 0.08 + Double(index) * 0.05)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                                .modifier(EditableWidget(widget: slot.widget, layout: home.layout))
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            home.refresh()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) { home.appeared = true }
        }
    }

    /// Widgets affichés, dans l'ordre choisi. La météo n'apparaît qu'avec une connexion internet.
    private var visibleSlots: [WidgetSlot] {
        home.layout.slots.filter { slot in
            guard slot.visible else { return false }
            switch slot.widget {
            case .weather: return home.net.online
            case .recents: return !home.recents.isEmpty || home.layout.editing
            default: return true
            }
        }
    }

    @ViewBuilder
    private func widget(_ w: HomeWidget) -> some View {
        switch w {
        case .quickActions:
            Card(title: w.title, icon: w.icon, tint: .pink) { quickActions }
        case .vscode: codeCard
        case .today: todayCard
        case .notes: notesCard
        case .weather: WeatherWidget(weather: home.weather)
        case .apps: AppsWidget()
        case .courses:
            CoursesWidget(s: CoursesStore.shared) { c in
                CoursesStore.shared.select(c)
                openTool(.courses)
            }
        case .exams: ExamsWidget(exams: home.exams)
        case .grades: GradesWidget { openTool(.grades) }
        case .planning: PlanningWidget { openTool(.planning) }
        case .nextShift: NextShiftWidget { openTool(.planning) }
        case .nextExam: NextExamWidget { openTool(.revisions) }
        case .mac: MacStatusWidget()
        case .clipboard: ClipboardWidget()
        case .watch: WatchWidget()
        case .github: githubCard
        case .recents:
            if home.recents.isEmpty {
                Card(title: w.title, icon: w.icon, tint: .teal) {
                    Text("Les fichiers ouverts dans Toolbox apparaîtront ici.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                recentCard
            }
        case .tools:
            Card(title: w.title, icon: w.icon, tint: .indigo) { toolsGrid }
        }
    }

    // MARK: En-tête

    private var hero: some View {
        HStack(spacing: 20) {
            FeuilleMascot(mood: home.mascotMood, poke: home.pokeDate)
                .frame(width: 118, height: 104)
                .contentShape(Rectangle())
                .onTapGesture { home.poke() }
                .help("Coucou !")
            VStack(alignment: .leading, spacing: 4) {
                Text(home.greeting)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(Self.dayFormat.string(from: home.now).capitalized(with: Locale(identifier: "fr_FR"))
                     + " · " + Self.hourFormat.string(from: home.now))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Toolbox · PDF, LaTeX et annales, 100 % sur ton Mac")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !home.layout.editing {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { home.layout.editing = true }
                } label: {
                    Label("Personnaliser", systemImage: "slider.horizontal.3")
                }
                .help("Ajouter, retirer et redimensionner les widgets (pour les déplacer : leur poignée en haut)")
            }
        }
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
            QuickAction(title: "Nouveau document LaTeX", icon: "square.and.pencil", color: .indigo) { newLatex() }
            QuickAction(title: "Capture → texte", icon: "text.viewfinder", color: .teal) { ScreenText.capture() }
            QuickAction(title: "Signer un PDF", icon: "signature", color: .blue) { openTool(.sign) }
            QuickAction(title: "Fusionner des PDF", icon: "doc.on.doc", color: .purple) { openTool(.merge) }
            QuickAction(title: "Compresser", icon: "arrow.down.right.and.arrow.up.left", color: .green) { openTool(.compress) }
            QuickAction(title: "Comparer deux PDF", icon: "plus.forwardslash.minus", color: .orange) { openTool(.compare) }
            QuickAction(title: "Déposer une annale", icon: "graduationcap", color: .red) { openTool(.annales) }
        }
    }

    // MARK: VS Code

    private var codeCard: some View {
        Card(title: "Projets VS Code Insiders", icon: "chevron.left.forwardslash.chevron.right", tint: .blue) {
            if home.codeFolders.isEmpty {
                Text("Épingle tes dossiers de projets pour les ouvrir dans VS Code Insiders en un clic.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(home.codeFolders) { f in
                HStack(spacing: 10) {
                    Image(systemName: f.pinned ? "pin.fill" : "clock")
                        .foregroundStyle(f.pinned ? Color.orange : Color.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                        Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Button { VSCode.open(f.url) } label: { Label("Ouvrir", systemImage: "arrow.up.forward.app") }
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { VSCode.open(f.url) }
                .contextMenu {
                    Button("Ouvrir dans VS Code Insiders") { VSCode.open(f.url) }
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                    Divider()
                    if f.pinned {
                        Button("Désépingler") { home.unpin(f.url) }
                    } else {
                        Button("Épingler") { home.pin(f.url) }
                    }
                }
            }
            HStack {
                Button { home.addFolder() } label: { Label("Épingler un dossier…", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                if VSCode.app == nil && Editor.vscode == nil {
                    Text("VS Code Insiders introuvable").font(.caption).foregroundStyle(Color.orange)
                }
            }
            .padding(.top, 4)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FileDrop.load(providers) { urls in
                for u in urls where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { home.pin(u) }
            }
            return true
        }
    }

    // MARK: GitHub

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .short
        return f
    }()

    private var githubCard: some View {
        Card(title: "GitHub", icon: "chevron.left.slash.chevron.right", tint: .primary,
             accessory: AnyView(HStack(spacing: 8) {
                 if home.githubLoading { ProgressView().controlSize(.small) }
                 Button { home.loadRepos() } label: { Image(systemName: "arrow.clockwise") }
                     .buttonStyle(.borderless).help("Actualiser")
                 Menu {
                     Button("Nouveau dépôt sur GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/new")!) }
                     Button("Mes notifications") { NSWorkspace.shared.open(URL(string: "https://github.com/notifications")!) }
                     Divider()
                     Button("Dossier de clonage : \(home.cloneFolder.lastPathComponent)…") {
                         if let u = Panels.folder(directory: home.cloneFolder, prompt: "Cloner ici") { home.cloneFolder = u }
                     }
                 } label: { Image(systemName: "ellipsis.circle") }
                     .menuStyle(.borderlessButton).fixedSize()
                 Button("Ouvrir GitHub") { NSWorkspace.shared.open(home.githubProfile) }.controlSize(.small)
             })) {
            if home.repos.isEmpty {
                if home.githubVia != "gh" {
                    HStack {
                        TextField("Ton nom d'utilisateur GitHub", text: $home.githubUser)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit { home.loadRepos() }
                        Button("Afficher mes dépôts") { home.loadRepos() }
                    }
                }
                if !home.githubStatus.isEmpty {
                    Text(home.githubStatus).font(.caption).foregroundStyle(.secondary)
                }
                if GitHub.ghPath == nil {
                    Text("Astuce : avec « brew install gh » puis « gh auth login », tes dépôts privés apparaissent aussi.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], spacing: 8) {
                    ForEach(home.repos) { repo in repoRow(repo) }
                }
                if !home.githubStatus.isEmpty {
                    Text(home.githubStatus).font(.caption).foregroundStyle(Color.orange)
                }
            }
        }
    }

    private func repoRow(_ repo: GitHubRepo) -> some View {
        let local = home.localClone(repo)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed.fill")
                .foregroundStyle(repo.isPrivate ? Color.orange : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.callout.weight(.semibold)).lineLimit(1)
                if !repo.description.isEmpty {
                    Text(repo.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if !repo.language.isEmpty {
                        HStack(spacing: 3) {
                            Circle().fill(LanguageColors.of(repo.language)).frame(width: 7, height: 7)
                            Text(repo.language)
                        }
                    }
                    if repo.stars > 0 { Label("\(repo.stars)", systemImage: "star") }
                    if let d = repo.pushed { Text(Self.relative.localizedString(for: d, relativeTo: home.now)) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { NSWorkspace.shared.open(repo.url) } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless).help("Ouvrir sur GitHub")
            if let local = local {
                Button { VSCode.open(local) } label: { Label("Ouvrir", systemImage: "arrow.up.forward.app") }
                    .controlSize(.small)
                    .help("Ouvrir \(local.path) dans VS Code Insiders")
            } else if home.cloning == repo.id {
                ProgressView().controlSize(.small)
            } else {
                Button { home.cloneAndOpen(repo) } label: { Label("Cloner", systemImage: "square.and.arrow.down") }
                    .controlSize(.small)
                    .help("Cloner dans \(home.cloneFolder.path) puis ouvrir dans VS Code Insiders")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .contextMenu {
            Button("Ouvrir sur GitHub") { NSWorkspace.shared.open(repo.url) }
            Button("Copier l'adresse de clonage") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(repo.cloneURL, forType: .string)
            }
            if let local = local {
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([local]) }
            }
        }
    }

    // MARK: Notes

    private static let postit = Color(red: 1.0, green: 0.93, blue: 0.62)

    private var notesCard: some View {
        Card(title: "Pense-bête", icon: "note.text", tint: .orange,
             accessory: AnyView(HStack(spacing: 8) {
                 if home.notesBusy { ProgressView().controlSize(.small) }
                 Menu {
                     if home.recentNotes.isEmpty {
                         Text("Chargement des notes…")
                     }
                     ForEach(home.recentNotes) { n in
                         Button(n.name) { home.pinNote(n.id) }
                     }
                     if !home.pinnedNoteID.isEmpty {
                         Divider()
                         Button("Désépingler") { home.unpinNote() }
                     }
                 } label: { Label("Épingler", systemImage: "pin") }
                     .menuStyle(.borderlessButton).fixedSize()
                     .onAppear { home.loadRecentNotes() }
                 Button("Notes") { AppleNotes.openApp() }.controlSize(.small)
             })) {
            // Saisie rapide
            TextField("Note rapide… (1re ligne = titre, ⌘↩ pour créer)", text: $home.noteDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            HStack {
                Button { home.createNote() } label: { Label("Nouvelle note", systemImage: "square.and.pencil") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(home.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || home.notesBusy)
                if !home.pinnedNoteID.isEmpty {
                    Button { home.appendToPinned() } label: { Label("Ajouter à l'épinglée", systemImage: "text.append") }
                        .disabled(home.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || home.notesBusy)
                }
            }
            .controlSize(.small)

            // Note épinglée, façon post-it
            if !home.pinnedNoteID.isEmpty && !home.pinnedTitle.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "pin.fill").foregroundStyle(Color.red).rotationEffect(.degrees(30))
                        Text(home.pinnedTitle).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Button { home.loadPinnedNote() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Recharger")
                        Button { AppleNotes.show(id: home.pinnedNoteID) } label: { Image(systemName: "arrow.up.forward.app") }
                            .buttonStyle(.borderless).help("Ouvrir dans Notes")
                    }
                    if !home.pinnedText.isEmpty {
                        ScrollView {
                            Text(home.pinnedText)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                }
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 6).fill(Self.postit))
                .shadow(color: .black.opacity(0.12), radius: 4, x: 1, y: 3)
                .rotationEffect(.degrees(-0.6))
                .onTapGesture(count: 2) { AppleNotes.show(id: home.pinnedNoteID) }
            } else if home.pinnedNoteID.isEmpty {
                Text("Épingle une note (bouton en haut) pour l'avoir toujours sous les yeux ici.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !home.notesStatus.isEmpty {
                Text(home.notesStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Calendrier

    private var todayCard: some View {
        Card(title: "Aujourd'hui", icon: "calendar", tint: .red,
             accessory: AnyView(Button("Calendrier") { HomeStore.openCalendar() }.controlSize(.small))) {
            switch home.calendarAccess {
            case nil:
                Text("Affiche ici les événements du jour de ton app Calendrier.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Autoriser l'accès au calendrier") { home.requestAccess() }
                    .buttonStyle(.borderedProminent)
            case false?:
                Text("Accès au calendrier refusé. Tu peux l'autoriser dans Réglages Système → Confidentialité et sécurité → Calendriers → Toolbox.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Ouvrir les réglages") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(u)
                    }
                }
            case true?:
                if home.events.isEmpty {
                    Label("Rien de prévu aujourd'hui.", systemImage: "sun.max")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(home.events) { e in
                    let past = !e.allDay && e.end < home.now
                    let ongoing = !e.allDay && e.start <= home.now && e.end > home.now
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(e.color).frame(width: 4, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text(e.allDay ? "Toute la journée"
                                 : Self.hourFormat.string(from: e.start) + " – " + Self.hourFormat.string(from: e.end)
                                   + (e.location.isEmpty ? "" : " · " + e.location))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if ongoing {
                            Text("en cours").font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.red))
                        }
                    }
                    .opacity(past ? 0.45 : 1)
                }
            }
        }
    }

    // MARK: Fichiers récents

    private var recentCard: some View {
        Card(title: "Ouverts récemment dans Toolbox", icon: "clock.arrow.circlepath", tint: .teal) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(home.recents, id: \.self) { url in
                        Button { openFile(url) } label: {
                            VStack(spacing: 6) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 42, height: 42)
                                Text(url.lastPathComponent).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(width: 110, height: 92)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                    }
                }
            }
        }
    }

    // MARK: Outils

    private var toolsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            ForEach(Tool.allCases.filter { $0 != .home }) { tool in
                ToolTile(tool: tool) { openTool(tool) }
            }
        }
    }
}

// MARK: - Petits composants

extension View {
    /// Apparition en fondu + glissement, décalée dans le temps.
    func appear(_ shown: Bool, delay: Double) -> some View {
        self.opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(delay), value: shown)
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    var accessory: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
                Spacer()
                if let a = accessory { a }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06)))
    }
}

final class HoverFlag: ObservableObject { @Published var on = false }

struct QuickAction: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.body.weight(.semibold))
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(hover.on ? Color.white : color)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(hover.on ? color : color.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .scaleEffect(hover.on ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: hover.on)
        .onHover { hover.on = $0 }
    }
}

struct ToolTile: View {
    let tool: Tool
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tool.icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 11).fill(tool.color.gradient))
                    .rotationEffect(.degrees(hover.on ? -6 : 0))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title).font(.callout.weight(.semibold))
                    Text(tool.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover.on ? tool.color.opacity(0.6) : Color.primary.opacity(0.06)))
            .shadow(color: tool.color.opacity(hover.on ? 0.25 : 0), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .scaleEffect(hover.on ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover.on)
        .onHover { hover.on = $0 }
    }
}

/// Humeur de la mascotte : selon la météo, l'heure… ou une bonne nouvelle.
enum MascotMood: Equatable {
    case normal, sunny, rainy, snowy, sleepy, party
}

/// Mascotte « Feuille » : une petite page qui rebondit, cligne des yeux et agite sa clé à molette.
/// Lunettes de soleil s'il fait beau, parapluie s'il pleut, bonnet s'il neige, endormie la nuit,
/// et un saut avec des cœurs quand on clique dessus (`poke`).
/// Dessinée dans un repère 260 × 230 (le même que la maquette), mise à l'échelle.
struct FeuilleMascot: View {
    var mood: MascotMood = .normal
    var poke: Date? = nil

    static let ink = Color(red: 0.29, green: 0.25, blue: 0.82)        // #4a3fd1
    static let face = Color(red: 0.17, green: 0.14, blue: 0.27)       // #2b2346
    static let cheek = Color(red: 1.0, green: 0.62, blue: 0.71)       // #ff9db5
    static let fold = Color(red: 0.87, green: 0.89, blue: 1.0)        // #dfe2ff
    static let lines = Color(red: 0.79, green: 0.80, blue: 0.96)      // #c9ccf5
    static let wrench = Color(red: 1.0, green: 0.70, blue: 0.28)      // #ffb347

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let since = poke.map { t - $0.timeIntervalSinceReferenceDate } ?? 99
            Canvas { ctx, size in
                let k = min(size.width / 260, size.height / 230)
                ctx.translateBy(x: (size.width - 260 * k) / 2, y: (size.height - 230 * k) / 2)
                ctx.scaleBy(x: k, y: k)
                Self.draw(&ctx, t: t, mood: mood, since: since)
            }
        }
    }

    static func draw(_ ctx: inout GraphicsContext, t: Double, mood: MascotMood, since: Double) {
        let sleepy = mood == .sleepy
        let party = mood == .party
        let speed = party ? 4.2 : (sleepy ? 0.9 : 2.4)
        let hop = abs(sin(t * speed)) * (sleepy ? 0.15 : 1)        // 0 au sol, 1 en haut du saut
        // Saut de joie après un clic (1,1 s)
        let pokeJump = since >= 0 && since < 1.1 ? sin(since / 1.1 * .pi) : 0
        let lift = hop * 9 + pokeJump * 34
        let squash = hop < 0.15 && pokeJump == 0 ? 1 - (0.15 - hop) * 0.25 : 1
        let cycle = t.truncatingRemainder(dividingBy: 3.8)
        let blink: CGFloat = (cycle < 0.13 || (cycle > 0.3 && cycle < 0.4 && Int(t / 3.8) % 3 == 0)) ? 0.12 : 1
        let wiggle = sin(t * (party ? 9 : 3.4)) * (party ? 26 : 14)
        let stroke = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

        // Ombre (rétrécit quand la feuille est en l'air)
        let air = min(1, hop * 0.6 + pokeJump)
        let sw = 124 * (1 - air * 0.35)
        ctx.fill(Path(ellipseIn: CGRect(x: 130 - sw / 2, y: 203, width: sw, height: 18)),
                 with: .color(face.opacity(0.10 + 0.04 * (1 - air))))

        // Météo autour : pluie ou neige qui tombe
        if mood == .rainy || mood == .snowy {
            for i in 0..<9 {
                let x = 20 + Double(i) * 27 + sin(Double(i) * 3.1) * 8
                let y = (t * (mood == .rainy ? 140 : 35) + Double(i) * 47).truncatingRemainder(dividingBy: 210)
                if mood == .rainy {
                    var drop = Path()
                    drop.move(to: CGPoint(x: x, y: y))
                    drop.addLine(to: CGPoint(x: x - 3, y: y + 10))
                    ctx.stroke(drop, with: .color(Color.blue.opacity(0.35)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                } else {
                    let dx = sin(t * 1.5 + Double(i)) * 6
                    ctx.fill(Path(ellipseIn: CGRect(x: x + dx - 3, y: y - 3, width: 6, height: 6)), with: .color(Color.cyan.opacity(0.55)))
                }
            }
        }

        var c = ctx
        c.translateBy(x: 130, y: 210 - lift)
        c.rotate(by: .degrees(pokeJump * sin(since * 12) * 6))
        c.scaleBy(x: 2 - squash, y: squash)
        c.translateBy(x: -130, y: -210)

        // Pieds
        for x in [98.0, 144.0] {
            c.fill(Path(roundedRect: CGRect(x: x, y: 200, width: 18, height: 10), cornerRadius: 5), with: .color(ink))
        }

        // Parapluie tenu par le bras gauche (derrière la tête)
        if mood == .rainy {
            var handle = Path()
            handle.move(to: CGPoint(x: 52, y: 130))
            handle.addLine(to: CGPoint(x: 70, y: 22))
            c.stroke(handle, with: .color(face), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            var canopy = Path()
            canopy.addArc(center: CGPoint(x: 72, y: 22), radius: 62, startAngle: .degrees(190), endAngle: .degrees(350), clockwise: false)
            for k in 0..<4 {   // bord festonné
                let x0 = 72 + 62 * cos(350 * .pi / 180) - Double(k) * 30.5
                canopy.addQuadCurve(to: CGPoint(x: x0 - 30.5, y: 22 + 62 * sin(350 * .pi / 180)),
                                    control: CGPoint(x: x0 - 15, y: 22 + 62 * sin(350 * .pi / 180) + 10))
            }
            canopy.closeSubpath()
            c.fill(canopy, with: .linearGradient(Gradient(colors: [Color(red: 0.36, green: 0.75, blue: 1.0), Color(red: 0.2, green: 0.5, blue: 0.95)]),
                                                 startPoint: CGPoint(x: 0, y: -40), endPoint: CGPoint(x: 0, y: 20)))
        }

        // Bras
        var arms = Path()
        arms.move(to: CGPoint(x: 64, y: 150))
        if mood == .rainy {
            arms.addQuadCurve(to: CGPoint(x: 52, y: 128), control: CGPoint(x: 52, y: 146))
        } else {
            let raise = party ? -18 + sin(t * 9) * 6 : sin(t * 3.4 + 1) * 3
            arms.addQuadCurve(to: CGPoint(x: 50, y: 128 + raise), control: CGPoint(x: 50, y: 144))
        }
        arms.move(to: CGPoint(x: 188, y: 150))
        arms.addQuadCurve(to: CGPoint(x: 216, y: party ? 116 : 134), control: CGPoint(x: 212, y: 154))
        c.stroke(arms, with: .color(ink), style: stroke)

        // Clé à molette
        var w = c
        w.translateBy(x: 214, y: party ? 112 : 118)
        w.rotate(by: .degrees(35 + wiggle))
        w.fill(Path(roundedRect: CGRect(x: -4, y: -2, width: 8, height: 30), cornerRadius: 4), with: .color(wrench))
        var head = Path(ellipseIn: CGRect(x: -12, y: -21, width: 24, height: 24))
        head.addRect(CGRect(x: -5, y: -22, width: 10, height: 12))
        w.fill(head, with: .color(wrench), style: FillStyle(eoFill: true))

        // Corps (la page)
        var body = Path()
        body.move(to: CGPoint(x: 78, y: 40))
        body.addLine(to: CGPoint(x: 156, y: 40))
        body.addLine(to: CGPoint(x: 188, y: 72))
        body.addArc(tangent1End: CGPoint(x: 188, y: 204), tangent2End: CGPoint(x: 64, y: 204), radius: 14)
        body.addArc(tangent1End: CGPoint(x: 64, y: 204), tangent2End: CGPoint(x: 64, y: 40), radius: 14)
        body.addArc(tangent1End: CGPoint(x: 64, y: 40), tangent2End: CGPoint(x: 156, y: 40), radius: 14)
        body.closeSubpath()
        c.fill(body, with: .linearGradient(Gradient(colors: [.white, fold.opacity(0.6)]),
                                           startPoint: CGPoint(x: 0, y: 40), endPoint: CGPoint(x: 0, y: 204)))
        c.stroke(body, with: .color(ink), style: stroke)

        // Coin replié (il bat un peu pendant le saut)
        let flap = 22 * (1 - 0.18 * max(hop, pokeJump))
        var corner = Path()
        corner.move(to: CGPoint(x: 156, y: 40))
        corner.addLine(to: CGPoint(x: 156, y: 40 + flap))
        corner.addQuadCurve(to: CGPoint(x: 166, y: 50 + flap), control: CGPoint(x: 156, y: 50 + flap))
        corner.addLine(to: CGPoint(x: 188, y: 72))
        corner.closeSubpath()
        c.fill(corner, with: .color(fold))
        c.stroke(corner, with: .color(ink), style: stroke)

        // Lignes de texte
        c.fill(Path(roundedRect: CGRect(x: 88, y: 62, width: 48, height: 6), cornerRadius: 3), with: .color(lines))
        c.fill(Path(roundedRect: CGRect(x: 88, y: 76, width: 36, height: 6), cornerRadius: 3), with: .color(lines))

        // Bonnet de neige
        if mood == .snowy {
            var hat = Path()
            hat.move(to: CGPoint(x: 70, y: 52))
            hat.addQuadCurve(to: CGPoint(x: 182, y: 52), control: CGPoint(x: 126, y: -6))
            hat.closeSubpath()
            c.fill(hat, with: .color(Color(red: 0.92, green: 0.26, blue: 0.32)))
            c.fill(Path(roundedRect: CGRect(x: 64, y: 44, width: 124, height: 16), cornerRadius: 8), with: .color(.white))
            c.stroke(Path(roundedRect: CGRect(x: 64, y: 44, width: 124, height: 16), cornerRadius: 8), with: .color(ink.opacity(0.5)), lineWidth: 2)
            c.fill(Path(ellipseIn: CGRect(x: 114, y: 4, width: 22, height: 22)), with: .color(.white))
        }

        // Yeux
        let look = sin(t * 0.7) * 2
        let happyEyes = party || pokeJump > 0
        for cx in [108.0, 152.0] {
            if sleepy || happyEyes {
                // yeux fermés : ‿ (endormi) ou ^ (content)
                var e = Path()
                e.move(to: CGPoint(x: cx - 9, y: 124))
                e.addQuadCurve(to: CGPoint(x: cx + 9, y: 124), control: CGPoint(x: cx, y: happyEyes ? 112 : 132))
                c.stroke(e, with: .color(face), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            } else if mood != .sunny {
                let h = 22 * blink
                c.fill(Path(ellipseIn: CGRect(x: cx - 9 + look, y: 124 - h / 2, width: 18, height: h)), with: .color(face))
                if blink > 0.5 {
                    c.fill(Path(ellipseIn: CGRect(x: cx + look - 0.4, y: 116.6, width: 6.8, height: 6.8)), with: .color(.white))
                }
            }
        }

        // Lunettes de soleil
        if mood == .sunny && !happyEyes {
            for cx in [108.0, 152.0] {
                let lens = Path(roundedRect: CGRect(x: cx - 15, y: 112, width: 30, height: 22), cornerRadius: 9)
                c.fill(lens, with: .linearGradient(Gradient(colors: [face, Color(red: 0.35, green: 0.3, blue: 0.55)]),
                                                   startPoint: CGPoint(x: 0, y: 112), endPoint: CGPoint(x: 0, y: 134)))
                var shine = Path()
                shine.move(to: CGPoint(x: cx - 8, y: 128))
                shine.addLine(to: CGPoint(x: cx + 2, y: 117))
                c.stroke(shine, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            var bridge = Path()
            bridge.move(to: CGPoint(x: 123, y: 118))
            bridge.addQuadCurve(to: CGPoint(x: 137, y: 118), control: CGPoint(x: 130, y: 113))
            c.stroke(bridge, with: .color(face), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }

        // Joues (plus roses quand elle est contente)
        for cx in [94.0, 166.0] {
            c.fill(Path(ellipseIn: CGRect(x: cx - 10, y: 140, width: 20, height: 12)),
                   with: .color(cheek.opacity(happyEyes ? 1 : 0.8)))
        }

        // Bouche
        var mouth = Path()
        if sleepy {
            mouth.addEllipse(in: CGRect(x: 125, y: 143 + sin(t * 0.9) * 1.5, width: 10, height: 8 + sin(t * 0.9) * 2))
            c.fill(mouth, with: .color(face))
        } else {
            let open = happyEyes ? 14.0 : 8 + hop * 5
            mouth.move(to: CGPoint(x: 120, y: 144))
            mouth.addQuadCurve(to: CGPoint(x: 140, y: 144), control: CGPoint(x: 130, y: 144 + open))
            if happyEyes {
                mouth.closeSubpath()
                c.fill(mouth, with: .color(face))
            } else {
                c.stroke(mouth, with: .color(face), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            }
        }

        // Z z z quand elle dort
        if sleepy {
            for i in 0..<3 {
                let p = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                c.opacity = 1 - p
                c.draw(Text("z").font(.system(size: 16 + CGFloat(i) * 5, weight: .heavy, design: .rounded)).foregroundColor(ink),
                       at: CGPoint(x: 196 + p * 30 + Double(i) * 6, y: 60 - p * 50))
            }
            c.opacity = 1
        }

        // Cœurs après un clic
        if pokeJump > 0 || (since >= 1.1 && since < 1.6) {
            for i in 0..<3 {
                let p = min(1, since / 1.6)
                let x = 90 + Double(i) * 40 + sin(since * 5 + Double(i)) * 6
                ctx.opacity = 1 - p
                ctx.draw(Text("♥").font(.system(size: 22 + CGFloat(i % 2) * 6)).foregroundColor(Color.pink),
                         at: CGPoint(x: x, y: 40 - p * 60 - lift * 0.5))
            }
            ctx.opacity = 1
        }

        // Confettis en mode fête
        if party {
            let colors: [Color] = [.pink, .orange, .yellow, .green, .blue, .purple]
            for i in 0..<14 {
                let x = Double(i) * 19 + 4 + sin(t * 2 + Double(i)) * 8
                let y = (t * 70 + Double(i) * 37).truncatingRemainder(dividingBy: 200) - 10
                var piece = ctx
                piece.translateBy(x: x, y: y)
                piece.rotate(by: .radians(t * 4 + Double(i)))
                piece.fill(Path(CGRect(x: -3, y: -5, width: 6, height: 10)), with: .color(colors[i % colors.count]))
            }
        }
    }
}

/// Fond animé : des taches de couleur floues qui dérivent lentement.
struct AnimatedBackdrop: View {
    private let blobs: [(Color, Double, Double, Double)] = [
        (.indigo, 0.11, 0.0, 0.42), (.pink, 0.08, 1.7, 0.36), (.teal, 0.07, 3.1, 0.40),
        (.orange, 0.09, 4.4, 0.30), (.purple, 0.06, 5.6, 0.34),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for (color, speed, phase, radius) in blobs {
                    let x = size.width * (0.5 + 0.38 * cos(t * speed + phase))
                    let y = size.height * (0.35 + 0.28 * sin(t * speed * 1.3 + phase * 0.7))
                    let r = min(size.width, size.height) * radius
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(color.opacity(0.22)))
                }
            }
            .blur(radius: 70)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Couleurs des langages, façon GitHub.
enum LanguageColors {
    static let table: [String: Color] = [
        "Python": Color(red: 0.21, green: 0.45, blue: 0.65), "Swift": Color(red: 0.94, green: 0.32, blue: 0.22),
        "TeX": Color(red: 0.24, green: 0.38, blue: 0.09), "JavaScript": Color(red: 0.95, green: 0.88, blue: 0.36),
        "TypeScript": Color(red: 0.19, green: 0.47, blue: 0.78), "C": Color(red: 0.33, green: 0.33, blue: 0.33),
        "Java": Color(red: 0.69, green: 0.45, blue: 0.10), "HTML": Color(red: 0.89, green: 0.30, blue: 0.15),
        "CSS": Color(red: 0.34, green: 0.24, blue: 0.49), "OCaml": Color(red: 0.94, green: 0.48, blue: 0.03),
    ]

    static func of(_ language: String) -> Color { table[language] ?? .gray }
}
