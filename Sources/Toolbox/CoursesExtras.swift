import SwiftUI
import AppKit
import Carbon
import UserNotifications
import PDFKit
import PDFCore

// MARK: - Avancement, éléments masqués, corrections dévoilées

enum StudyMark: Int, CaseIterable, Identifiable {
    case none = 0, review = 1, done = 2, mastered = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "Pas commencé"
        case .review: return "À revoir"
        case .done: return "Fait"
        case .mastered: return "Compris"
        }
    }

    var icon: String {
        switch self {
        case .none: return "circle"
        case .review: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .mastered: return "star.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .none: return .secondary
        case .review: return .orange
        case .done: return .green
        case .mastered: return .yellow
        }
    }
}

final class CourseMarks: ObservableObject {
    static let shared = CourseMarks()

    @Published private(set) var marks: [String: Int] = UserDefaults.standard.dictionary(forKey: "courses.marks") as? [String: Int] ?? [:]
    @Published private(set) var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "courses.hidden") ?? [])
    @Published var showHidden = false
    @Published var revealed: Set<String> = []        // séances dont on a affiché la correction (non mémorisé)

    static func key(_ c: Course, _ s: CourseSession) -> String { c.id + "|" + s.id }

    func mark(_ c: Course, _ s: CourseSession) -> StudyMark { StudyMark(rawValue: marks[Self.key(c, s)] ?? 0) ?? .none }

    func setMark(_ m: StudyMark, _ c: Course, _ s: CourseSession) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            marks[Self.key(c, s)] = m == .none ? nil : m.rawValue
        }
        UserDefaults.standard.set(marks, forKey: "courses.marks")
        if m == .mastered { ToastCenter.shared.show("« \(s.title) » compris, bravo !", cheer: true) }
    }

    /// Part des séances de cours / TD / TP faites ou comprises.
    func progress(_ c: Course) -> (done: Int, total: Int) {
        let list = c.sessions.filter { [.cours, .td, .tp].contains($0.kind) && !isHidden(c, $0) }
        let done = list.filter { mark(c, $0).rawValue >= StudyMark.done.rawValue }.count
        return (done, list.count)
    }

    func isHidden(_ c: Course, _ s: CourseSession) -> Bool { hidden.contains(Self.key(c, s)) }
    func isHidden(_ item: CourseItem) -> Bool { hidden.contains(item.url.path) }

    func toggleHidden(_ key: String) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if hidden.contains(key) { hidden.remove(key) } else { hidden.insert(key) }
        }
        UserDefaults.standard.set(Array(hidden), forKey: "courses.hidden")
    }

    func hiddenCount(_ c: Course) -> Int {
        c.sessions.reduce(0) { n, s in
            n + (isHidden(c, s) ? 1 : 0) + s.items.filter { isHidden($0) }.count
        }
    }
}

// MARK: - Notification au début d'un cours

enum CourseAlerts {
    static let category = "toolbox.course"

    static func setup() {
        let center = UNUserNotificationCenter.current()
        let open = UNNotificationAction(identifier: "open-latest", title: "Ouvrir le dernier TD/TP", options: [.foreground])
        let newTP = UNNotificationAction(identifier: "new-tp", title: "Nouveau TP", options: [.foreground])
        let show = UNNotificationAction(identifier: "show", title: "Voir la matière", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [open, newTP, show],
                                                                 intentIdentifiers: [], options: [])])
    }

    static func notify(course c: Course, name: String, event: String, latest: String?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(name) commence"
            content.body = latest.map { "\(event) — dernier travail : \($0). Ouvrir ?" } ?? "\(event) — ouvrir la matière ?"
            content.sound = .default
            content.categoryIdentifier = category
            content.userInfo = ["course": c.id]
            center.add(UNNotificationRequest(identifier: "course-" + c.id + "-" + String(Int(Date().timeIntervalSince1970 / 600)),
                                             content: content, trigger: nil))
        }
    }

    /// Réponse à la notification (clic ou bouton).
    static func handle(action: String, courseID: String) {
        let s = CoursesStore.shared
        guard let c = s.courses.first(where: { $0.id == courseID }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch action {
        case "open-latest": s.openLatest(c)
        case "new-tp": s.newSession(.tp, in: c)
        default:
            s.select(c)
            AppRouter.shared.show = .courses
        }
    }
}

// MARK: - Raccourci global ⌥Espace (même quand Toolbox est en arrière-plan)

final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    /// id 1 : ⌥Espace (recherche dans les cours) ; 100… : apps (⌃⌥1…9).
    func register(id: UInt32 = 1, keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey),
                  action: @escaping () -> Void) {
        installHandler()
        unregister(id: id)
        actions[id] = action
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x54424F58), id: id)   // « TBOX »
        if RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &ref) == noErr, let r = ref {
            refs[id] = r
        }
    }

    func unregister(id: UInt32) {
        if let r = refs[id] { UnregisterEventHotKey(r) }
        refs[id] = nil
        actions[id] = nil
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { GlobalHotKey.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

// MARK: - Mini-recherche flottante dans les cours

final class QuickSearchState: ObservableObject {
    @Published var query = "" { didSet { selection = 0; refresh() } }
    @Published var selection = 0
    @Published var files: [(Course, CourseItem)] = []
    @Published var hits: [ContentHit] = []
    private var work: DispatchWorkItem?

    var count: Int { files.count + hits.count }

    func refresh() {
        let s = CoursesStore.shared
        let q = query
        files = Array(s.search(q).prefix(7)).map { ($0.0, $0.2) }
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in
            let found = CourseIndex.shared.search(q, limit: 6)
            DispatchQueue.main.async { if self?.query == q { self?.hits = found } }
        }
        work = w
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func run(_ index: Int) {
        if index < files.count {
            CoursesStore.shared.open(files[index].1)
        } else if index - files.count < hits.count {
            let h = hits[index - files.count]
            CoursesStore.shared.remember(h.url)
            NSWorkspace.shared.open(h.url)
        }
        QuickSearchPanel.shared.close()
    }
}

final class QuickSearchPanel {
    static let shared = QuickSearchPanel()
    private var panel: NSPanel?
    private var monitor: Any?
    let state = QuickSearchState()

    func toggle() { panel?.isVisible == true ? close() : open() }

    func open() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: QuickSearchView(state: state))
            panel = p
        }
        state.query = ""
        CoursesStore.shared.indexIfNeeded()
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    func close() {
        panel?.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.panel?.isKeyWindow == true else { return e }
            let st = self.state
            switch e.keyCode {
            case 125: if st.count > 0 { st.selection = (st.selection + 1) % st.count }; return nil
            case 126: if st.count > 0 { st.selection = (st.selection - 1 + st.count) % st.count }; return nil
            case 53: self.close(); return nil
            case 36, 76: st.run(st.selection); return nil
            default: return e
            }
        }
    }
}

struct QuickSearchView: View {
    @ObservedObject var state: QuickSearchState
    @ObservedObject var courses = CoursesStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill").font(.title3).foregroundStyle(Color.orange)
                FocusTextField(text: $state.query, placeholder: "Chercher dans tes cours (nom ou contenu)…")
                    .frame(height: 30)
                Text("⌥Espace").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if state.query.isEmpty {
                        let recent = courses.recentItems.prefix(6)
                        if !recent.isEmpty { header("Ouverts récemment") }
                        ForEach(Array(recent.enumerated()), id: \.offset) { _, r in
                            row(icon: FileBadge(item: r.1), title: r.1.url.lastPathComponent, subtitle: courses.name(r.0), selected: false)
                                .onTapGesture { courses.open(r.1); QuickSearchPanel.shared.close() }
                        }
                    }
                    if !state.files.isEmpty { header("Fichiers") }
                    ForEach(Array(state.files.enumerated()), id: \.offset) { i, f in
                        row(icon: FileBadge(item: f.1), title: f.1.url.lastPathComponent, subtitle: courses.name(f.0),
                            selected: state.selection == i)
                            .onTapGesture { state.run(i) }
                    }
                    if !state.hits.isEmpty { header("Dans le contenu") }
                    ForEach(Array(state.hits.enumerated()), id: \.element.id) { i, h in
                        row(icon: Image(systemName: "text.magnifyingglass").foregroundStyle(Color.accentColor).frame(width: 20),
                            title: h.url.lastPathComponent + (h.page.map { " — p. \($0 + 1)" } ?? ""),
                            subtitle: h.snippet, selected: state.selection == state.files.count + i)
                            .onTapGesture { state.run(state.files.count + i) }
                    }
                    if !state.query.isEmpty && state.count == 0 {
                        Text("Aucun résultat").foregroundStyle(.secondary).padding(14)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 620, height: 420)
        .background(.regularMaterial)
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
    }

    private func row<I: View>(icon: I, title: String, subtitle: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.2) : Color.clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Aperçu d'un PDF à la bonne page, passage surligné

struct PDFHitPreview: NSViewRepresentable {
    let url: URL
    let page: Int
    let query: String

    final class Coordinator { var key = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .underPageBackgroundColor
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        let key = "\(url.path)#\(page)#\(query)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
        guard let doc = v.document, let p = doc.page(at: min(page, max(0, doc.pageCount - 1))) else { return }
        v.go(to: p)
        let word = query.split(separator: " ").map(String.init).max(by: { $0.count < $1.count }) ?? query
        let found = doc.findString(word, withOptions: [.caseInsensitive, .diacriticInsensitive]).filter { $0.pages.contains(p) }
        found.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.55) }
        v.highlightedSelections = found
        if let first = found.first { v.go(to: first) }
    }
}
