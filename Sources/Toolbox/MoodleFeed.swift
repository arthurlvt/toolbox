import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFCore

// MARK: - Moodle : devoirs à rendre, dépôts et annonces
//
// Mêmes jeton et cours suivis que la synchro des fichiers. Toutes les heures : devoirs (date limite, état du dépôt)
// et annonces des profs. Rappels 24 h et 3 h avant une date limite d'un devoir pas rendu, alerte pour chaque
// nouvelle annonce : dans la dynamic island et, si tu l'actives, en notification sur l'iPhone (ntfy).
// Déposer, remplacer ou retirer un dépôt demande toujours confirmation ; « Envoyer le devoir » (définitif) aussi.
// Notes : juste une alerte « nouvelle note » (île, jusqu'au clic, et iPhone) ; rien n'est gardé ni calculé.

/// Notifications sur l'iPhone par ntfy (appli gratuite) : le Mac publie sur un « sujet » secret auquel l'iPhone est abonné.
enum PushNotifier {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "push.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "push.enabled") }
    }
    static var server: String {
        get { UserDefaults.standard.string(forKey: "push.server") ?? "https://ntfy.sh" }
        set { UserDefaults.standard.set(newValue, forKey: "push.server") }
    }
    /// Sujet difficile à deviner (quiconque le connaît peut lire les notifications).
    static var topic: String {
        get {
            if let t = UserDefaults.standard.string(forKey: "push.topic"), !t.isEmpty { return t }
            let t = newTopic()
            UserDefaults.standard.set(t, forKey: "push.topic")
            return t
        }
        set { UserDefaults.standard.set(newValue, forKey: "push.topic") }
    }

    static func newTopic() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "toolbox-" + String((0..<16).map { _ in chars.randomElement()! })
    }

    static func send(title: String, body: String, url: URL? = nil, tags: [String] = [], priority: Int = 3, force: Bool = false,
                     done: ((Error?) -> Void)? = nil) {
        guard enabled || force, let base = URL(string: server) else { done?(MoodleError(L("Adresse du serveur invalide."))); return }
        var json: [String: Any] = ["topic": topic, "title": title, "message": body.isEmpty ? title : body,
                                   "priority": priority, "tags": tags]
        if let u = url { json["click"] = u.absoluteString }
        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let e: Error? = err ?? ((200..<300).contains(code) ? nil : MoodleError(String(format: L("Le serveur a répondu %lld."), code)))
            DispatchQueue.main.async { done?(e) }
        }.resume()
    }
}

final class MoodleFeed: ObservableObject {
    static let shared = MoodleFeed()
    private let d = UserDefaults.standard

    enum Tab: String, CaseIterable, Identifiable {
        case devoirs = "Devoirs", annonces = "Annonces"
        var id: String { rawValue }
    }

    struct Work: Identifiable {
        let a: Moodle.Assignment
        var status: Moodle.SubmissionStatus?
        let courseName: String
        var id: Int { a.id }
        var done: Bool { status?.isDone(a) ?? false }
        var due: Date? { status?.extension_ ?? a.due }
        var late: Bool { !done && (due.map { $0 < Date() } ?? false) }
        var files: [Moodle.SubmittedFile] { status?.files ?? [] }
        var isDraft: Bool { a.needsSubmitButton && status?.state != "submitted" && !files.isEmpty }
        var canEdit: Bool { a.acceptsFiles && (status?.canEdit ?? false) && !(a.cutoff.map { $0 < Date() } ?? false) }
    }

    struct News: Identifiable {
        let d: Moodle.Discussion
        let courseName: String
        let text: String
        var id: Int { d.key }
    }

    struct Pending {
        enum Action { case deposit([URL]), remove, submit }
        let action: Action
        let work: Work
    }

    @Published var works: [Work] = []
    @Published var news: [News] = []
    @Published var busy = false
    @Published var status: StatusMessage?
    @Published var lastRefresh: Date?
    @Published var tab: Tab = .devoirs
    @Published var confirm: Pending?
    @Published var showPush = false
    @Published var pushOn: Bool = PushNotifier.enabled { didSet { PushNotifier.enabled = pushOn } }
    @Published var pushTopic: String = PushNotifier.topic { didSet { PushNotifier.topic = pushTopic } }
    @Published var remindHours: Int { didSet { d.set(remindHours, forKey: "moodle.remindHours") } }
    @Published var gradesOn: Bool { didSet { d.set(gradesOn, forKey: "moodle.grades") } }
    /// Annonces déjà vues dans la page (pour le badge « Nouveau »).
    @Published var newsSeenAt: Date { didSet { d.set(newsSeenAt, forKey: "moodle.newsSeenAt") } }

    private var timer: Timer?
    private var started = false

    private var seenNews: Set<Int> {
        get { Set((d.array(forKey: "moodle.seenNews") as? [Int]) ?? []) }
        set { d.set(Array(newValue.sorted().suffix(2000)), forKey: "moodle.seenNews") }
    }
    /// Notes déjà signalées (clé id|note|date) et cours dont les notes existantes ont été vues une première fois.
    private var seenGrades: Set<String> {
        get { Set(d.stringArray(forKey: "moodle.seenGrades") ?? []) }
        set { d.set(Array(newValue), forKey: "moodle.seenGrades") }
    }
    private var gradeCourses: Set<Int> {
        get { Set((d.array(forKey: "moodle.gradeCourses") as? [Int]) ?? []) }
        set { d.set(Array(newValue), forKey: "moodle.gradeCourses") }
    }
    private var reminded: Set<String> {
        get { Set(d.stringArray(forKey: "moodle.reminded") ?? []) }
        set { d.set(Array(newValue), forKey: "moodle.reminded") }
    }

    static let remindChoices: [(Int, String)] = [(0, "Pas de rappel"), (3, "3 h avant"), (24, "24 h et 3 h avant"), (72, "3 jours, 24 h et 3 h avant")]

    init() {
        remindHours = UserDefaults.standard.object(forKey: "moodle.remindHours") as? Int ?? 24
        gradesOn = UserDefaults.standard.object(forKey: "moodle.grades") as? Bool ?? true
        newsSeenAt = UserDefaults.standard.object(forKey: "moodle.newsSeenAt") as? Date ?? Date()
    }

    var pendingCount: Int { works.filter { !$0.done && $0.a.acceptsFiles }.count }

    // MARK: Rafraîchir

    func start() {
        guard !started, MoodleStore.shared.connected else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.refreshIfDue()
            self?.checkReminders()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.refreshIfDue() }
    }

    func refreshIfDue() {
        guard !busy, MoodleStore.shared.connected else { return }
        if let l = lastRefresh, Date().timeIntervalSince(l) < 3600 { return }
        refresh(silent: true)
    }

    func refresh(silent: Bool = false) {
        let m = MoodleStore.shared
        guard !busy, let c = m.client else { return }
        let follow = Array(m.followed)
        guard !follow.isEmpty else {
            if !silent { status = .info(L("Choisis tes cours à suivre (bouton Moodle de Mes cours).")) }
            return
        }
        var names = Dictionary(uniqueKeysWithValues: m.courses.map { ($0.id, Moodle.subjectName($0.fullname)) })
        let uid = m.userID
        let wantGrades = gradesOn
        busy = true
        if !silent { status = nil }
        runInBackground({ () -> ([Work], [News], [(Int, String, Moodle.GradeItem)]) in
            if names.isEmpty, uid != 0, let list = try? c.courses(user: uid) {
                for x in list { names[x.id] = Moodle.subjectName(x.fullname) }
            }
            let limit = Date().addingTimeInterval(-45 * 86400)
            var works: [Work] = []
            for a in try c.assignments(courses: follow) {
                if let due = a.due, due < limit { continue }          // vieux devoirs : on oublie
                let st = try? c.submissionStatus(assign: a.id)
                works.append(Work(a: a, status: st, courseName: names[a.course] ?? "Cours \(a.course)"))
            }
            var news: [News] = []
            let forums = ((try? c.forums(courses: follow)) ?? []).filter { $0.type == "news" }
            for f in forums {
                for dd in (try? c.discussions(forum: f.id)) ?? [] {
                    news.append(News(d: dd, courseName: names[f.course] ?? f.name ?? "", text: Moodle.plainText(dd.message ?? "")))
                }
            }
            var grades: [(Int, String, Moodle.GradeItem)] = []
            if wantGrades, uid != 0 {
                for id in follow {
                    for g in (try? c.gradeItems(course: id, user: uid)) ?? [] where g.isPublished {
                        grades.append((id, names[id] ?? "Cours \(id)", g))
                    }
                }
            }
            return (works, news, grades)
        }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let (w, n, g)):
                self.works = w.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                self.news = n.sorted { $0.d.date > $1.d.date }
                self.lastRefresh = Date()
                self.announce(n)
                if wantGrades { self.announceGrades(g, courses: follow) }
                self.checkReminders()
                if !silent {
                    self.status = .ok(String(format: L("%lld devoir(s) à rendre, %lld annonce(s)."), self.pendingCount, n.count))
                }
            case .failure(let e):
                if !silent { self.status = .err(e) }
            }
        }
    }

    // MARK: Alertes

    private func url(_ path: String) -> URL? { URL(string: MoodleStore.shared.root + path) }

    func link(_ w: Work) -> URL? { url("/mod/assign/view.php?id=\(w.a.cmid)") }
    func link(_ n: News) -> URL? { url("/mod/forum/discuss.php?d=\(n.d.key)") }

    private func notify(icon: String, color: Color, title: String, subtitle: String, url: URL?, tags: [String], priority: Int = 3) {
        NotchController.shared.alert(NotchAlert(icon: icon, color: color, title: title, subtitle: subtitle), seconds: 7)
        PushNotifier.send(title: title, body: subtitle, url: url, tags: tags, priority: priority)
    }

    /// Nouvelles annonces : alerte pour chacune (les 3 plus récentes), sauf au tout premier passage.
    private func announce(_ list: [News]) {
        var seen = seenNews
        let firstTime = !d.bool(forKey: "moodle.newsInit")
        let fresh = list.filter { !seen.contains($0.id) }
        fresh.forEach { seen.insert($0.id) }
        seenNews = seen
        if firstTime { d.set(true, forKey: "moodle.newsInit"); return }
        for n in fresh.sorted(by: { $0.d.date > $1.d.date }).prefix(3) {
            notify(icon: "megaphone.fill", color: .orange, title: n.courseName + " : " + n.d.title,
                   subtitle: String(n.text.prefix(180)), url: link(n), tags: ["loudspeaker"])
        }
        if fresh.count > 3 {
            PushNotifier.send(title: String(format: L("%lld autres annonces Moodle"), fresh.count - 3), body: "", tags: ["loudspeaker"])
        }
    }

    /// Nouvelles notes : une alerte qui reste dans l'île jusqu'au clic, et une notification iPhone.
    /// Premier passage d'un cours : ses notes déjà là sont juste mémorisées, sans alerte.
    private func announceGrades(_ list: [(Int, String, Moodle.GradeItem)], courses: [Int]) {
        var seen = seenGrades
        let known = gradeCourses
        var fresh: [(String, Moodle.GradeItem)] = []
        for (course, name, g) in list where !seen.contains(g.key) {
            seen.insert(g.key)
            if known.contains(course) { fresh.append((name, g)) }
        }
        seenGrades = seen
        gradeCourses = known.union(courses)
        guard !fresh.isEmpty else { return }
        for (name, g) in fresh.prefix(5) {
            PushNotifier.send(title: L("Note publiée") + " · " + name, body: (g.itemname ?? L("Note")) + " : " + g.text,
                              tags: ["memo"], priority: 4)
        }
        let alert: NotchAlert
        if fresh.count == 1, let one = fresh.first {
            let (name, g) = one
            alert = NotchAlert(icon: "graduationcap.fill", color: .mint, title: L("Note publiée") + " · " + name,
                               subtitle: (g.itemname ?? L("Note")) + " : " + g.text, sticky: true)
        } else {
            alert = NotchAlert(icon: "graduationcap.fill", color: .mint,
                               title: String(format: L("%lld nouvelles notes"), fresh.count),
                               subtitle: fresh.map { $0.0 + " " + $0.1.text }.joined(separator: " · "), sticky: true)
        }
        NotchController.shared.alert(alert)
    }

    /// Rappels avant la date limite des devoirs pas encore rendus (un seul par palier, le plus proche).
    func checkReminders() {
        guard remindHours > 0 else { return }
        let steps = [72, 24, 3].filter { $0 <= remindHours || $0 == 3 }
        var done = reminded
        let now = Date()
        for w in works where !w.done && w.a.acceptsFiles {
            guard let due = w.due, due > now else { continue }
            let left = due.timeIntervalSince(now) / 3600
            let hit = steps.filter { Double($0) >= left }
            guard let smallest = hit.min(), !done.contains("\(w.id)|\(smallest)") else { continue }
            hit.forEach { done.insert("\(w.id)|\($0)") }
            let when = Self.dueText(due)
            let what = w.isDraft ? L("déposé mais pas envoyé") : L("pas encore rendu")
            notify(icon: "clock.badge.exclamationmark.fill", color: smallest <= 3 ? .red : .orange,
                   title: w.a.name, subtitle: w.courseName + " · " + when + " · " + what, url: link(w),
                   tags: ["hourglass"], priority: smallest <= 3 ? 5 : 4)
        }
        reminded = done
    }

    static func dueText(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        let abs = d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return abs + " (" + f.localizedString(for: d, relativeTo: Date()) + ")"
    }

    // MARK: Déposer, remplacer, retirer, envoyer

    func choose(_ w: Work) {
        let urls = Panels.open([.item], multiple: w.a.maxFiles > 1)
        if !urls.isEmpty { prepare(w, urls) }
    }

    /// Vérifie ce que Moodle refuserait de toute façon, puis demande confirmation.
    func prepare(_ w: Work, _ urls: [URL]) {
        guard w.canEdit else { status = .err(L("Ce devoir ne peut plus être modifié.")); return }
        if w.a.maxFiles > 0, urls.count > w.a.maxFiles {
            status = .err(String(format: L("Ce devoir accepte %lld fichier(s) au maximum."), w.a.maxFiles)); return
        }
        if let bad = urls.first(where: { !w.a.accepts(fileName: $0.lastPathComponent) }) {
            status = .err(String(format: L("« %@ » n'est pas d'un type accepté (%@)."), bad.lastPathComponent, w.a.fileTypes)); return
        }
        if w.a.maxBytes > 0, let big = urls.first(where: { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > w.a.maxBytes }) {
            status = .err(String(format: L("« %@ » dépasse la taille maximale (%@)."), big.lastPathComponent,
                                 ByteCountFormatter.string(fromByteCount: Int64(w.a.maxBytes), countStyle: .file))); return
        }
        if let dir = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
            status = .err(String(format: L("« %@ » est un dossier : compresse-le d'abord en .zip."), dir.lastPathComponent)); return
        }
        confirm = Pending(action: .deposit(urls), work: w)
    }

    func askRemove(_ w: Work) { confirm = Pending(action: .remove, work: w) }
    func askSubmit(_ w: Work) { confirm = Pending(action: .submit, work: w) }

    func confirmTitle(_ p: Pending) -> String {
        switch p.action {
        case .deposit: return p.work.files.isEmpty ? L("Déposer sur Moodle ?") : L("Remplacer ton dépôt ?")
        case .remove: return L("Retirer ton dépôt ?")
        case .submit: return L("Envoyer le devoir pour de bon ?")
        }
    }

    func confirmMessage(_ p: Pending) -> String {
        let w = p.work
        var lines: [String] = [w.a.name + " — " + w.courseName]
        if let due = w.due { lines.append(L("Date limite") + " : " + Self.dueText(due)) }
        switch p.action {
        case .deposit(let urls):
            lines.append(L("Fichier(s) envoyé(s)") + " : " + urls.map { $0.lastPathComponent }.joined(separator: ", "))
            if !w.files.isEmpty {
                lines.append(L("Ils remplaceront ce qui est déposé maintenant") + " : "
                             + w.files.compactMap { $0.filename }.joined(separator: ", "))
            }
            if w.a.needsSubmitButton {
                lines.append(L("Ce devoir demande de cliquer « Envoyer le devoir » ensuite : tant que ce n'est pas fait, ton prof considère qu'il n'est pas rendu."))
            }
            if w.late { lines.append(L("⚠️ La date limite est passée : le dépôt sera marqué en retard.")) }
        case .remove:
            lines.append(L("Les fichiers déposés seront retirés de Moodle") + " : " + w.files.compactMap { $0.filename }.joined(separator: ", "))
            lines.append(L("Ils restent bien sûr sur ton Mac."))
        case .submit:
            lines.append(L("Après l'envoi, tu ne pourras plus modifier ni retirer ton dépôt (sauf si le prof le rouvre)."))
            if w.a.requiresSubmissionStatement {
                lines.append(L("En envoyant, tu confirmes la déclaration du devoir : ce travail est le tien, sauf les parties citées."))
            }
        }
        return lines.joined(separator: "\n\n")
    }

    func perform(_ p: Pending, alsoSubmit: Bool = false) {
        let m = MoodleStore.shared
        guard let c = m.client else { return }
        confirm = nil
        busy = true
        let uid = m.userID
        let id = p.work.a.id
        status = .info(L("Envoi à Moodle…"))
        runInBackground({ () -> Moodle.SubmissionStatus in
            switch p.action {
            case .deposit(let urls):
                let draft = try c.uploadDraft(urls)
                try c.saveSubmission(assign: id, draft: draft)
                if alsoSubmit { try c.submitForGrading(assign: id) }
            case .remove:
                try c.removeSubmission(assign: id, user: uid)
            case .submit:
                try c.submitForGrading(assign: id)
            }
            return try c.submissionStatus(assign: id)
        }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let st):
                if let i = self.works.firstIndex(where: { $0.id == id }) { self.works[i].status = st }
                let w = self.works.first { $0.id == id }
                switch p.action {
                case .deposit:
                    let names = (w?.files ?? []).compactMap { $0.filename }.joined(separator: ", ")
                    if w?.done == true {
                        self.status = .ok(L("Rendu ✓ Moodle a bien reçu") + " : " + names)
                    } else {
                        self.status = .ok(L("Déposé (brouillon) : pense à « Envoyer le devoir ».") + " " + names)
                    }
                case .remove: self.status = .ok(L("Dépôt retiré de Moodle."))
                case .submit:
                    let msg: StatusMessage = w?.done == true ? .ok(L("Devoir envoyé ✓")) : .err(L("Moodle n'a pas pris l'envoi : vérifie sur le site."))
                    self.status = msg
                }
            case .failure(let e):
                self.status = .err(e)
                self.refresh(silent: true)
            }
        }
    }
}

extension Moodle.Assignment {
    var requiresSubmissionStatement: Bool { requiresubmissionstatement == 1 }
}

// MARK: - Page « Moodle »

struct MoodleToolView: View {
    @ObservedObject var f = MoodleFeed.shared
    @ObservedObject var m = MoodleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .moodle)
            if !m.connected {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connecte-toi à e-uapv pour voir tes devoirs à rendre et les annonces de tes profs.")
                        .foregroundStyle(.secondary)
                    Button("Se connecter à l'ENT…") { m.showSheet = true }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 20)
                Spacer()
            } else {
                HStack {
                    Picker("", selection: $f.tab) {
                        ForEach(MoodleFeed.Tab.allCases) { t in
                            Text(L(t.rawValue) + (t == .devoirs && f.pendingCount > 0 ? " (\(f.pendingCount))" : "")).tag(t)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    if f.busy { ProgressView().controlSize(.small) }
                    if let l = f.lastRefresh {
                        Text(L("Mis à jour") + " " + l.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { f.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(f.busy).help("Rafraîchir")
                    Button { f.showPush.toggle() } label: {
                        Image(systemName: f.pushOn ? "bell.badge.fill" : "bell")
                    }
                    .buttonStyle(.borderless).help("Rappels et notifications sur l'iPhone")
                    .popover(isPresented: $f.showPush, arrowEdge: .bottom) { MoodlePushSettings() }
                    Button { m.showSheet = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Cours suivis, synchro des fichiers")
                }
                if let s = f.status { StatusBanner(message: s) }
                ScrollView {
                    if f.tab == .devoirs { assignments } else { announcements }
                }
            }
        }
        .padding(20)
        .sheet(isPresented: $m.showSheet) { MoodleSheet() }
        .alert(f.confirm.map { f.confirmTitle($0) } ?? "",
               isPresented: Binding(get: { f.confirm != nil }, set: { if !$0 { f.confirm = nil } }),
               presenting: f.confirm) { p in
            switch p.action {
            case .deposit:
                Button(p.work.a.needsSubmitButton ? L("Déposer (brouillon)") : L("Déposer")) { f.perform(p) }
                if p.work.a.needsSubmitButton && p.work.status?.canSubmit != false {
                    Button(L("Déposer et envoyer le devoir")) { f.perform(p, alsoSubmit: true) }
                }
            case .remove:
                Button(L("Retirer le dépôt"), role: .destructive) { f.perform(p) }
            case .submit:
                Button(L("Envoyer le devoir")) { f.perform(p) }
            }
            Button(L("Annuler"), role: .cancel) { f.confirm = nil }
        } message: { p in
            Text(f.confirmMessage(p))
        }
        .onAppear { if m.connected && f.lastRefresh == nil { f.refresh(silent: true) } }
        .onDisappear { if f.tab == .annonces { f.newsSeenAt = Date() } }
    }

    // MARK: Devoirs

    @ViewBuilder
    private var assignments: some View {
        let late = f.works.filter { $0.late && $0.a.acceptsFiles }
        let todo = f.works.filter { !$0.done && !$0.late }
        let done = f.works.filter { $0.done }.sorted { ($0.due ?? .distantPast) > ($1.due ?? .distantPast) }
        VStack(alignment: .leading, spacing: 14) {
            if f.works.isEmpty {
                Text(f.busy ? L("Chargement…") : L("Aucun devoir dans tes cours suivis."))
                    .foregroundStyle(.secondary).padding(.top, 20)
            }
            section(L("En retard"), late, color: .red)
            section(L("À rendre"), todo, color: .orange)
            section(L("Rendus"), done, color: .green)
            Text("Glisse un fichier sur un devoir pour le déposer. Rien n'est envoyé sans ta confirmation.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [MoodleFeed.Work], color: Color) -> some View {
        if !list.isEmpty {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text("\(list.count)").font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(0.2)))
            }
            ForEach(list) { w in row(w) }
        }
    }

    private func row(_ w: MoodleFeed.Work) -> some View {
        let tint: Color = w.done ? .green : (w.late ? .red : (w.isDraft ? .orange : .secondary))
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(w.a.name).font(.body.weight(.semibold)).lineLimit(2)
                    badge(w)
                }
                Text(w.courseName + (w.due.map { " · " + MoodleFeed.dueText($0) } ?? " · " + L("pas de date limite")))
                    .font(.caption).foregroundStyle(w.late ? Color.red : .secondary)
                if !w.a.acceptsFiles {
                    Text("Pas de dépôt de fichier (texte en ligne, papier…) : voir sur Moodle.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !w.a.fileTypes.isEmpty || w.a.maxFiles > 1 {
                    Text(L("Accepte") + " : " + (w.a.fileTypes.isEmpty ? L("tous les types") : w.a.fileTypes)
                         + (w.a.maxFiles > 1 ? " · " + String(format: L("%lld fichiers max"), w.a.maxFiles) : ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(w.files, id: \.self) { file in
                    Label(file.filename ?? "?", systemImage: "doc.fill").font(.caption)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if w.canEdit {
                    Button(w.files.isEmpty ? L("Déposer…") : L("Remplacer…")) { f.choose(w) }
                    if !w.files.isEmpty {
                        Button { f.askRemove(w) } label: { Image(systemName: "trash") }.help("Retirer le dépôt")
                    }
                    if w.isDraft && (w.status?.canSubmit ?? false) {
                        Button("Envoyer le devoir") { f.askSubmit(w) }.buttonStyle(.borderedProminent)
                    }
                }
                Button { if let u = f.link(w) { NSWorkspace.shared.open(u) } } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Ouvrir sur Moodle")
            }
            .controlSize(.small)
            .disabled(f.busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard w.canEdit else { return false }
            FileDrop.load(providers) { urls in if !urls.isEmpty { f.prepare(w, urls) } }
            return true
        }
    }

    private func badge(_ w: MoodleFeed.Work) -> some View {
        let (text, color): (String, Color) = w.done ? (L("Rendu"), .green)
            : w.isDraft ? (L("Brouillon, pas envoyé"), .orange)
            : w.late ? (L("En retard"), .red) : (L("Pas rendu"), .secondary)
        return Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }

    // MARK: Annonces

    private var announcements: some View {
        VStack(alignment: .leading, spacing: 10) {
            if f.news.isEmpty {
                Text(f.busy ? L("Chargement…") : L("Aucune annonce dans tes cours suivis."))
                    .foregroundStyle(.secondary).padding(.top, 20)
            }
            ForEach(f.news) { n in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if n.d.date > f.newsSeenAt {
                            Text("Nouveau").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.25))).foregroundStyle(Color.orange)
                        }
                        Text(n.courseName).font(.caption.weight(.semibold)).foregroundStyle(Color.orange)
                        Text("· " + (n.d.userfullname ?? "") + " · " + n.d.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { if let u = f.link(n) { NSWorkspace.shared.open(u) } } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.borderless).help("Ouvrir sur Moodle")
                    }
                    Text(n.d.title).font(.body.weight(.semibold))
                    Text(n.text).font(.callout).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rappels et notifications iPhone

struct MoodlePushSettings: View {
    @ObservedObject var f = MoodleFeed.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rappels et notifications").font(.headline)
            Picker("Rappels de date limite", selection: $f.remindHours) {
                ForEach(MoodleFeed.remindChoices, id: \.0) { Text(L($0.1)).tag($0.0) }
            }
            .fixedSize()
            Toggle("Prévenir des nouvelles notes", isOn: $f.gradesOn)
            Text("Rappels et nouvelles annonces s'affichent dans la dynamic island. Une nouvelle note y reste jusqu'à ce que tu cliques dessus ; rien n'est gardé ni calculé.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Aussi sur mon iPhone (ntfy)", isOn: $f.pushOn)
            Text("1. Installe l'appli gratuite « ntfy » sur l'iPhone.\n2. « + » → abonne-toi au sujet ci-dessous (serveur ntfy.sh).\n3. Envoie un test. Le Mac doit être allumé (même en veille légère) pour que les notifications partent.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Sujet", text: $f.pushTopic).textFieldStyle(.roundedBorder).font(.body.monospaced())
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.pushTopic, forType: .string) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copier")
                Button { f.pushTopic = PushNotifier.newTopic() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .help("Nouveau sujet (l'ancien ne recevra plus rien)")
            }
            Text("Le sujet sert de mot de passe : ne le partage pas. Les notifications passent par le serveur public ntfy.sh.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Envoyer un test") {
                    PushNotifier.send(title: L("Toolbox"), body: L("Les notifications Moodle arriveront ici."), tags: ["white_check_mark"],
                                      force: true) { err in
                        let msg: StatusMessage = err == nil ? .ok(L("Test envoyé : regarde ton iPhone.")) : .err(err!)
                        f.status = msg
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
