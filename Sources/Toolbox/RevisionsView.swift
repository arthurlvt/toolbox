import SwiftUI
import AppKit
import EventKit
import Combine
import UniformTypeIdentifiers
import PDFCore

// MARK: - Modèle

struct RevisionLink: Codable, Hashable {
    var path: String
    var title: String
    var correction = false
}

struct RevisionTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var section: String
    var done = false
    var links: [RevisionLink] = []
    var sessionKey: String?          // séance de « Mes cours » liée (pour l'avancement)
    var training = false             // « S'entraîner » → Annalyse
}

struct RevisionPlan: Codable, Identifiable, Equatable {
    var id: String                   // identifiant de l'événement du calendrier, ou « manual-… »
    var title: String
    var date: Date?
    var courseID: String?
    var tasks: [RevisionTask] = []
    var manual = false
    var location: String?

    var done: Int { tasks.filter { $0.done }.count }
    var progress: Double { tasks.isEmpty ? 0 : Double(done) / Double(tasks.count) }
    var remaining: Int { tasks.count - done }

    var daysLeft: Int? {
        guard let d = date else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day
    }

    var isPast: Bool { (date ?? .distantFuture) < Calendar.current.startOfDay(for: Date()) }

    /// En retard : moins de 7 jours et moins de la moitié faite, ou moins de 3 jours et pas fini.
    var urgent: Bool {
        guard let d = daysLeft, !isPast, remaining > 0 else { return false }
        return (d <= 7 && progress < 0.5) || d <= 2
    }
}

// MARK: - Stockage et calendrier

final class RevisionsStore: ObservableObject {
    static let shared = RevisionsStore()

    @Published var plans: [RevisionPlan] = [] { didSet { if plans != oldValue { save() } } }
    @Published var selectedID: String?
    @Published var calendarID = UserDefaults.standard.string(forKey: "revisions.calendar") ?? "" {
        didSet { UserDefaults.standard.set(calendarID, forKey: "revisions.calendar"); refresh() }
    }
    @Published var newTask = ""
    @Published var creating = false
    @Published var draftTitle = ""
    @Published var draftDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @Published var draftCourseID = ""
    @Published var showPast = false

    let events = EKEventStore()
    private var bag: Set<AnyCancellable> = []

    var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/Revisions.json")
    }

    init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([RevisionPlan].self, from: data) {
            plans = list
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        // les matières arrivent après l'analyse du dossier de cours
        CoursesStore.shared.$courses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(plans) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Calendrier des CC

    var calendars: [EKCalendar] { HomeStore.hasAccess ? events.calendars(for: .event) : [] }

    /// Le calendrier choisi, sinon celui qui ressemble à « CCs/Soutenance », « Examens », « Partiels »…
    var examCalendar: EKCalendar? {
        if let c = calendars.first(where: { $0.calendarIdentifier == calendarID }) { return c }
        return calendars.first { c in
            let t = CourseLibrary.fold(c.title)
            return t.range(of: #"(^|[^a-z])(ccs?|soutenances?|examens?|partiels?|exams?|controles?|ds)([^a-z]|$)"#,
                           options: .regularExpression) != nil
        }
    }

    func refresh() {
        guard HomeStore.hasAccess, let cal = examCalendar else { return }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 150, to: start) else { return }
        let evs = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: [cal]))
        let courses = CoursesStore.shared
        var list = plans
        for e in evs {
            let id = e.eventIdentifier ?? "\(e.title ?? "")|\(Int(e.startDate.timeIntervalSince1970))"
            let title = e.title ?? "CC"
            let course = courses.course(matchingTitle: title)
            if let i = list.firstIndex(where: { $0.id == id }) {
                // l'événement a pu être renommé ou déplacé
                list[i].title = title
                list[i].date = e.startDate
                list[i].location = e.location
                if list[i].courseID == nil, let c = course {
                    list[i].courseID = c.id
                    if list[i].tasks.isEmpty { list[i].tasks = Self.tasks(for: c) }
                }
            } else {
                list.append(RevisionPlan(id: id, title: title, date: e.startDate, courseID: course?.id,
                                         tasks: course.map(Self.tasks(for:)) ?? Self.genericTasks(), location: e.location))
            }
        }
        // un CC supprimé du calendrier : on garde la checklist seulement si elle a été commencée
        let ids = Set(evs.map { $0.eventIdentifier ?? "\($0.title ?? "")|\(Int($0.startDate.timeIntervalSince1970))" })
        list.removeAll { p in !p.manual && !p.isPast && !ids.contains(p.id) && p.done == 0 }
        list.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        if list != plans { plans = list }
        if selectedID == nil { selectedID = next?.id }
    }

    /// Le prochain CC (épinglé).
    var next: RevisionPlan? { plans.first { !$0.isPast && $0.date != nil } }
    var upcoming: [RevisionPlan] { plans.filter { !$0.isPast } }
    var past: [RevisionPlan] { plans.filter { $0.isPast }.reversed() }

    func plan(for course: Course) -> RevisionPlan? { upcoming.first { $0.courseID == course.id } }

    func course(_ p: RevisionPlan) -> Course? { CoursesStore.shared.courses.first { $0.id == p.courseID } }

    // MARK: Checklist

    static func tasks(for c: Course) -> [RevisionTask] {
        let marks = CourseMarks.shared
        var list: [RevisionTask] = []
        let kinds: [(CourseKind, String)] = [(.cours, "Relire"), (.td, "Refaire"), (.tp, "Revoir"), (.cc, "Faire")]
        for (kind, verb) in kinds {
            for s in c.sessions(kind) where !marks.isHidden(c, s) {
                let main = s.items.filter { !$0.isCorrection && !marks.isHidden($0) }
                let corr = s.items.filter { $0.isCorrection }
                var links = main.prefix(4).map { RevisionLink(path: $0.url.path, title: $0.url.lastPathComponent) }
                links += corr.prefix(2).map { RevisionLink(path: $0.url.path, title: $0.url.lastPathComponent, correction: true) }
                let title = "\(verb) \(kind == .cc ? "l'annale " : "")\(s.title)" + (s.subtitle.isEmpty ? "" : " · \(s.subtitle)")
                let already = marks.mark(c, s).rawValue >= StudyMark.mastered.rawValue
                list.append(RevisionTask(title: title, section: kind.title, done: already && kind == .cours,
                                         links: links, sessionKey: CourseMarks.key(c, s)))
            }
        }
        list += genericTasks()
        return list
    }

    static func genericTasks() -> [RevisionTask] {
        [RevisionTask(title: "S'entraîner sur un sujet type", section: "Entraînement", training: true),
         RevisionTask(title: "Faire une fiche de synthèse", section: "Entraînement")]
    }

    func update(_ planID: String, _ change: (inout RevisionPlan) -> Void) {
        guard let i = plans.firstIndex(where: { $0.id == planID }) else { return }
        change(&plans[i])
    }

    func taskBinding(_ planID: String, _ taskID: UUID) -> Binding<RevisionTask> {
        Binding(get: {
            self.plans.first { $0.id == planID }?.tasks.first { $0.id == taskID } ?? RevisionTask(title: "", section: "")
        }, set: { t in
            self.update(planID) { p in
                if let k = p.tasks.firstIndex(where: { $0.id == taskID }) { p.tasks[k] = t }
            }
        })
    }

    func toggle(_ planID: String, _ task: RevisionTask) {
        var finished = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            update(planID) { p in
                if let k = p.tasks.firstIndex(where: { $0.id == task.id }) { p.tasks[k].done.toggle() }
                finished = p.remaining == 0 && !p.tasks.isEmpty
            }
        }
        // séance cochée → « Fait » dans Mes cours
        if !task.done, let key = task.sessionKey { markDone(key) }
        if finished { ToastCenter.shared.show("Checklist terminée, tu es prêt pour ce CC ! 💪", cheer: true, seconds: 4) }
    }

    private func markDone(_ key: String) {
        let cs = CoursesStore.shared
        for c in cs.courses where key.hasPrefix(c.id + "|") {
            if let s = c.sessions.first(where: { CourseMarks.key(c, $0) == key }),
               CourseMarks.shared.mark(c, s).rawValue < StudyMark.done.rawValue {
                CourseMarks.shared.setMark(.done, c, s)
            }
        }
    }

    func addTask(to planID: String) {
        let t = newTask.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        withAnimation { update(planID) { $0.tasks.append(RevisionTask(title: t, section: "Perso")) } }
        newTask = ""
    }

    func addFiles(_ urls: [URL], to planID: String) {
        withAnimation {
            update(planID) { p in
                for u in urls {
                    p.tasks.append(RevisionTask(title: "Revoir \(u.deletingPathExtension().lastPathComponent)", section: "Perso",
                                                links: [RevisionLink(path: u.path, title: u.lastPathComponent)]))
                }
            }
        }
    }

    func remove(_ planID: String, _ task: RevisionTask) {
        withAnimation { update(planID) { $0.tasks.removeAll { $0.id == task.id } } }
    }

    /// Ajoute les séances apparues depuis (nouveau TD, nouveau chapitre…) sans toucher au reste.
    func refill(_ planID: String) {
        guard let p = plans.first(where: { $0.id == planID }), let c = course(p) else { return }
        let have = Set(p.tasks.compactMap { $0.sessionKey })
        let fresh = Self.tasks(for: c).filter { $0.sessionKey != nil && !have.contains($0.sessionKey ?? "") }
        withAnimation { update(planID) { $0.tasks += fresh } }
        ToastCenter.shared.show(fresh.isEmpty ? "Rien de nouveau dans \(CoursesStore.shared.name(c))." : "\(fresh.count) séance\(fresh.count > 1 ? "s" : "") ajoutée\(fresh.count > 1 ? "s" : "") ✓")
    }

    func setCourse(_ planID: String, _ courseID: String) {
        guard let c = CoursesStore.shared.courses.first(where: { $0.id == courseID }) else { return }
        update(planID) { p in
            p.courseID = courseID
            let custom = p.tasks.filter { $0.sessionKey == nil && !$0.training && $0.section == "Perso" }
            p.tasks = Self.tasks(for: c) + custom
        }
    }

    func createManual() {
        let title = draftTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let course = CoursesStore.shared.courses.first { $0.id == draftCourseID }
        let p = RevisionPlan(id: "manual-" + UUID().uuidString, title: title, date: draftDate, courseID: course?.id,
                             tasks: course.map(Self.tasks(for:)) ?? Self.genericTasks(), manual: true)
        plans.append(p)
        plans.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        selectedID = p.id
        creating = false
        draftTitle = ""
    }

    func delete(_ planID: String) {
        plans.removeAll { $0.id == planID }
        if selectedID == planID { selectedID = next?.id }
    }

    // MARK: Ouvrir

    func open(_ link: RevisionLink) {
        let cs = CoursesStore.shared
        for c in cs.courses {
            for s in c.sessions {
                if let item = s.items.first(where: { $0.url.path == link.path }) { cs.open(item); return }
            }
        }
        let u = URL(fileURLWithPath: link.path)
        if u.pathExtension.lowercased() == "tex" { AppRouter.shared.incoming = [u] } else { NSWorkspace.shared.open(u) }
    }

    func train(_ p: RevisionPlan) {
        if let c = course(p) {
            AppRouter.shared.trainFor = (CoursesStore.shared.name(c), c.folderName)
        } else {
            AppRouter.shared.show = .annales
        }
    }
}

extension CoursesStore {
    /// Matière dont le nom (ou un alias) apparaît dans le titre d'un événement.
    func course(matchingTitle title: String) -> Course? {
        courseMatching(CourseLibrary.fold(title))
    }
}

// MARK: - Vue

struct RevisionsToolView: View {
    @ObservedObject var r: RevisionsStore
    @ObservedObject var courses = CoursesStore.shared

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM 'à' HH:mm"
        return f
    }()
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM"
        return f
    }()

    static func countdown(_ d: Int?) -> String {
        guard let d = d else { return "" }
        if d < 0 { return "passé" }
        if d == 0 { return "aujourd'hui" }
        if d == 1 { return "demain" }
        return "J-\(d)"
    }

    static func color(_ p: RevisionPlan) -> Color {
        if p.remaining == 0 && !p.tasks.isEmpty { return .green }
        if p.urgent { return .red }
        guard let d = p.daysLeft else { return .secondary }
        return d <= 7 ? .orange : .mint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .revisions)
            if !HomeStore.hasAccess {
                Label("Autorise l'accès au Calendrier pour retrouver tes CC (Réglages Système → Confidentialité → Calendriers).",
                      systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(Color.orange)
            }
            if let n = r.next { PinnedExam(r: r, p: n) }
            HSplitView {
                sidebar.frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
                Group {
                    if let id = r.selectedID, let p = r.plans.first(where: { $0.id == id }) {
                        PlanDetail(r: r, p: p)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "checklist").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                            Text("Les CC de ton calendrier apparaissent ici avec une checklist prête.").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 460)
                .padding(.leading, 12)
            }
        }
        .padding(20)
        .onAppear { r.refresh() }
        .sheet(isPresented: $r.creating) { NewRevisionSheet(r: r) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: Binding(get: { r.selectedID }, set: { r.selectedID = $0 })) {
                Section("À venir") {
                    if r.upcoming.isEmpty {
                        Text("Aucun CC à venir 🎉").foregroundStyle(.secondary)
                    }
                    ForEach(r.upcoming) { p in row(p).tag(p.id) }
                }
                if !r.past.isEmpty {
                    Section {
                        if r.showPast {
                            ForEach(r.past) { p in row(p).tag(p.id) }
                        }
                    } header: {
                        Button { withAnimation { r.showPast.toggle() } } label: {
                            Label("Passés (\(r.past.count))", systemImage: r.showPast ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            Button { r.creating = true } label: { Label("Nouvelle révision", systemImage: "plus") }
                .buttonStyle(.borderless)
            HStack(spacing: 4) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Picker("", selection: $r.calendarID) {
                    Text(r.calendarID.isEmpty ? "Auto : \(r.examCalendar?.title ?? "aucun")" : "Auto").tag("")
                    ForEach(r.calendars, id: \.calendarIdentifier) { c in Text(c.title).tag(c.calendarIdentifier) }
                }
                .labelsHidden()
                .help("Calendrier où sont tes CC et soutenances")
            }
            .font(.caption)
        }
    }

    private func row(_ p: RevisionPlan) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
                Circle().trim(from: 0, to: p.progress).stroke(Self.color(p), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).lineLimit(1)
                Text([p.date.map { Self.shortDate.string(from: $0) }, r.course(p).map { courses.name($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Self.countdown(p.daysLeft)).font(.caption.weight(.bold)).foregroundStyle(Self.color(p))
        }
    }
}

/// Le prochain CC, épinglé en haut.
struct PinnedExam: View {
    @ObservedObject var r: RevisionsStore
    let p: RevisionPlan

    var body: some View {
        let color = RevisionsToolView.color(p)
        let d = p.daysLeft ?? 0
        HStack(spacing: 16) {
            VStack(spacing: 0) {
                Text(d <= 0 ? "Auj." : (d == 1 ? "Dem." : "J-\(d)"))
                    .font(.system(size: d > 1 ? 26 : 20, weight: .heavy, design: .rounded))
                Text("Prochain CC").font(.system(size: 9, weight: .semibold)).opacity(0.8)
            }
            .foregroundStyle(Color.white)
            .frame(width: 84, height: 64)
            .background(RoundedRectangle(cornerRadius: 14).fill(color.gradient))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(p.title).font(.title3.bold())
                    if p.urgent {
                        Label("en retard", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.bold)).foregroundStyle(Color.red)
                    }
                }
                Text([p.date.map { RevisionsToolView.dateFormat.string(from: $0) }, p.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                ProgressView(value: p.progress).tint(color).frame(maxWidth: 420)
                Text(pace(p)).font(.caption).foregroundStyle(p.urgent ? Color.red : Color.secondary)
            }
            Spacer()
            Button("Réviser") { r.selectedID = p.id }.buttonStyle(.borderedProminent)
            Button { r.train(p) } label: { Label("S'entraîner", systemImage: "wand.and.stars") }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(p.urgent ? 0.6 : 0.2)))
    }

    func pace(_ p: RevisionPlan) -> String {
        if p.tasks.isEmpty { return "Ajoute des tâches à la checklist." }
        if p.remaining == 0 { return "Checklist terminée ✓ (\(p.tasks.count) tâches)" }
        let days = max(1, p.daysLeft ?? 1)
        let perDay = Int((Double(p.remaining) / Double(days)).rounded(.up))
        return "\(p.done)/\(p.tasks.count) faites · encore \(p.remaining) : environ \(perDay) par jour pour finir à temps"
    }
}

struct PlanDetail: View {
    @ObservedObject var r: RevisionsStore
    @ObservedObject var courses = CoursesStore.shared
    let p: RevisionPlan
    @StateObject private var drop = HoverFlag()

    var sections: [String] {
        var seen: [String] = []
        for t in p.tasks where !seen.contains(t.section) { seen.append(t.section) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections, id: \.self) { sec in
                        let tasks = p.tasks.filter { $0.section == sec }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(sec).font(.headline)
                                Text("\(tasks.filter { $0.done }.count)/\(tasks.count)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    Button("Tout cocher") { tasks.filter { !$0.done }.forEach { r.toggle(p.id, $0) } }
                                    Button("Retirer cette section", role: .destructive) {
                                        withAnimation { r.update(p.id) { $0.tasks.removeAll { $0.section == sec } } }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).fixedSize()
                            }
                            ForEach(tasks) { t in TaskRow(r: r, p: p, task: r.taskBinding(p.id, t.id)) }
                        }
                    }
                    HStack {
                        TextField("Ajouter une tâche (ex. « Refaire l'exo 3 du CC1 »)…", text: $r.newTask)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { r.addTask(to: p.id) }
                        Button("Ajouter") { r.addTask(to: p.id) }.disabled(r.newTask.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Glisse un fichier ici pour l'ajouter à la checklist.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.bottom, 16)
            }
        }
        .fileDrop(types: [.item], isTargeted: Binding(get: { drop.on }, set: { drop.on = $0 })) { urls in r.addFiles(urls, to: p.id) }
        .overlay {
            if drop.on {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if p.manual {
                    TextField("Titre", text: Binding(get: { p.title }, set: { v in r.update(p.id) { $0.title = v } }))
                        .font(.title2.bold()).textFieldStyle(.plain)
                } else {
                    Text(p.title).font(.title2.bold())
                    Image(systemName: "calendar").foregroundStyle(.secondary).help("Vient de ton calendrier")
                }
                Spacer()
                Text(RevisionsToolView.countdown(p.daysLeft)).font(.title3.bold()).foregroundStyle(RevisionsToolView.color(p))
            }
            HStack(spacing: 10) {
                if p.manual {
                    DatePicker("", selection: Binding(get: { p.date ?? Date() }, set: { v in r.update(p.id) { $0.date = v } }))
                        .labelsHidden().fixedSize()
                } else if let d = p.date {
                    Text(RevisionsToolView.dateFormat.string(from: d)).foregroundStyle(.secondary)
                }
                Picker("Matière", selection: Binding(get: { p.courseID ?? "" }, set: { r.setCourse(p.id, $0) })) {
                    Text("Aucune").tag("")
                    ForEach(courses.courses) { c in Text(courses.name(c)).tag(c.id) }
                }
                .frame(width: 240)
                .help("Changer de matière refait la checklist (tes tâches perso sont gardées)")
                Spacer()
                if let c = r.course(p) {
                    Button { CoursesStore.shared.select(c); AppRouter.shared.show = .courses } label: {
                        Label("Mes cours", systemImage: "books.vertical")
                    }
                }
                Button { r.train(p) } label: { Label("S'entraîner", systemImage: "wand.and.stars") }
                Menu {
                    Button("Ajouter les nouvelles séances de la matière") { r.refill(p.id) }
                    Divider()
                    Button(p.manual ? "Supprimer cette révision" : "Effacer la checklist (le CC reste dans le calendrier)", role: .destructive) {
                        r.delete(p.id)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            ProgressView(value: p.progress).tint(RevisionsToolView.color(p))
            Text(PinnedExam(r: r, p: p).pace(p)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TaskRow: View {
    @ObservedObject var r: RevisionsStore
    let p: RevisionPlan
    @Binding var task: RevisionTask
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { r.toggle(p.id, task) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(task.done ? Color.green : Color.secondary)
                    .scaleEffect(task.done ? 1.08 : 1)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Tâche", text: $task.title)
                    .textFieldStyle(.plain)
                    .foregroundStyle(task.done ? Color.secondary : Color.primary)
                if !task.links.isEmpty || task.training {
                    HStack(spacing: 6) {
                        ForEach(task.links, id: \.self) { l in linkChip(l) }
                        if task.training {
                            Button { r.train(p) } label: {
                                Label("Annalyse", systemImage: "wand.and.stars").font(.caption)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            Spacer()
            if hover.on {
                Button { r.remove(p.id, task) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(task.done ? Color.green.opacity(0.06) : Color.primary.opacity(hover.on ? 0.05 : 0.025)))
        .onHover { hover.on = $0 }
        .contextMenu {
            Button(task.done ? "Décocher" : "Cocher") { r.toggle(p.id, task) }
            Button("Supprimer", role: .destructive) { r.remove(p.id, task) }
        }
    }

    private func linkChip(_ l: RevisionLink) -> some View {
        let ext = (l.path as NSString).pathExtension.lowercased()
        var isDir: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: l.path, isDirectory: &isDir) && isDir.boolValue
        let icon = l.correction ? "eye.slash" : (folder ? "folder.fill" : (ext == "pdf" ? "doc.richtext.fill" : (ext == "tex" ? "function" : "doc.fill")))
        let color: Color = l.correction ? .secondary : (folder ? .blue : (ext == "pdf" ? .red : .indigo))
        return Button { r.open(l) } label: {
            Label(l.correction ? "Corrigé" : (l.title as NSString).deletingPathExtension, systemImage: icon)
                .font(.caption).lineLimit(1)
                .foregroundStyle(color)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .opacity(l.correction && !task.done ? 0.6 : 1)
        .help(l.correction ? "Corrigé (à ouvrir après avoir cherché 😉)" : l.title)
    }
}

struct NewRevisionSheet: View {
    @ObservedObject var r: RevisionsStore
    @ObservedObject var courses = CoursesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nouvelle révision").font(.title2.bold())
            Text("Pour un CC qui n'est pas dans ton calendrier (ceux du calendrier ont déjà leur checklist).")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Titre", text: $r.draftTitle, prompt: Text("Révision CC2 Analyse"))
                DatePicker("Date", selection: $r.draftDate)
                Picker("Matière", selection: $r.draftCourseID) {
                    Text("Aucune").tag("")
                    ForEach(courses.courses) { c in Text(courses.name(c)).tag(c.id) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler") { r.creating = false }.keyboardShortcut(.cancelAction)
                Button("Créer") { r.createManual() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(r.draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Widget d'accueil et bandeau dans Mes cours

struct NextExamWidget: View {
    @ObservedObject var r = RevisionsStore.shared
    let open: () -> Void

    var body: some View {
        Card(title: "Prochain CC", icon: "checklist", tint: .mint,
             accessory: AnyView(Button("Réviser", action: open).buttonStyle(.borderless))) {
            if let p = r.next {
                let color = RevisionsToolView.color(p)
                HStack(alignment: .firstTextBaseline) {
                    Text(p.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(RevisionsToolView.countdown(p.daysLeft)).font(.title3.bold()).foregroundStyle(color)
                }
                if let d = p.date {
                    Text(RevisionsToolView.dateFormat.string(from: d)).font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: p.progress).tint(color)
                if p.urgent {
                    Label(PinnedExam(r: r, p: p).pace(p), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.red)
                }
                ForEach(p.tasks.filter { !$0.done }.prefix(3)) { t in
                    HStack(spacing: 6) {
                        Button { r.toggle(p.id, t) } label: { Image(systemName: "circle").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                        Text(t.title).font(.callout).lineLimit(1)
                        Spacer()
                        if let l = t.links.first(where: { !$0.correction }) {
                            Button { r.open(l) } label: { Image(systemName: "arrow.up.right.square") }
                                .buttonStyle(.borderless).help("Ouvrir \(l.title)")
                        }
                    }
                }
            } else {
                Text(HomeStore.hasAccess ? "Aucun CC à venir dans ton calendrier 🎉" : "Autorise le Calendrier pour voir tes CC.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Bandeau en haut d'une matière quand un CC approche.
struct CourseExamBanner: View {
    @ObservedObject var r = RevisionsStore.shared
    let course: Course

    var body: some View {
        if let p = r.plan(for: course) {
            let color = RevisionsToolView.color(p)
            HStack(spacing: 10) {
                Image(systemName: p.urgent ? "exclamationmark.triangle.fill" : "checklist").foregroundStyle(color)
                Text("\(p.title) \(RevisionsToolView.countdown(p.daysLeft))").font(.callout.weight(.semibold))
                Text("· \(p.done)/\(p.tasks.count) révisé").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Réviser") {
                    r.selectedID = p.id
                    AppRouter.shared.show = .revisions
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.10)))
        }
    }
}
