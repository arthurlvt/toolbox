import SwiftUI
import AppKit
import WebKit
import Security
import PDFCore

// MARK: - Synchronisation avec Moodle (e-uapv)
//
// Connexion par la page de l'ENT dans une petite fenêtre (le mot de passe reste entre toi et la fac), jeton gardé
// dans le trousseau. Ensuite : tes cours → leurs fichiers → triés dans « Mes cours » comme un import (cours / TD /
// TP / CC), en rejoignant tes matières. Seuls les fichiers nouveaux ou modifiés sont téléchargés ; rien n'est
// jamais supprimé, et un fichier remplacé par le prof garde son ancienne version à côté.

enum Keychain {
    static let service = "fr.arthur.toolbox.moodle"

    static func save(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

final class MoodleStore: ObservableObject {
    static let shared = MoodleStore()
    private let d = UserDefaults.standard

    // réglages
    @Published var base: String { didSet { d.set(base, forKey: "moodle.base") } }
    @Published private(set) var root: String { didSet { d.set(root, forKey: "moodle.root") } }      // wwwroot de l'année
    @Published private(set) var userName: String { didSet { d.set(userName, forKey: "moodle.user") } }
    @Published var followed: Set<Int> { didSet { d.set(Array(followed), forKey: "moodle.followed") } }
    /// cours Moodle → dossier de la matière (vide = nouvelle matière au premier téléchargement)
    @Published var mapping: [String: String] { didSet { d.set(mapping, forKey: "moodle.mapping") } }
    @Published var autoHours: Int { didSet { d.set(autoHours, forKey: "moodle.autoHours"); scheduleAuto() } }
    @Published private(set) var lastSync: Date? { didSet { d.set(lastSync, forKey: "moodle.lastSync") } }

    // état
    @Published var courses: [Moodle.Course] = []
    @Published var busy = false
    @Published var progress = ""
    @Published var status: StatusMessage?
    @Published var showSheet = false

    private var userID: Int { d.integer(forKey: "moodle.userid") }
    private var autoTimer: Timer?
    private var loginWindow: MoodleLoginWindow?

    /// Fichiers déjà récupérés : clé → date de modification côté Moodle.
    private var synced: [String: Int] {
        get { (d.dictionary(forKey: "moodle.synced") as? [String: Int]) ?? [:] }
        set { d.set(newValue, forKey: "moodle.synced") }
    }

    static let autoChoices: [(Int, String)] = [(0, "Seulement à la main"), (3, "Toutes les 3 h"), (12, "Toutes les 12 h"), (24, "Une fois par jour")]

    init() {
        let d = UserDefaults.standard
        base = d.string(forKey: "moodle.base") ?? "https://e-uapv.univ-avignon.fr"
        root = d.string(forKey: "moodle.root") ?? ""
        userName = d.string(forKey: "moodle.user") ?? ""
        followed = Set((d.array(forKey: "moodle.followed") as? [Int]) ?? [])
        mapping = (d.dictionary(forKey: "moodle.mapping") as? [String: String]) ?? [:]
        autoHours = d.object(forKey: "moodle.autoHours") as? Int ?? 3
        lastSync = d.object(forKey: "moodle.lastSync") as? Date
    }

    var token: String? { Keychain.read(account: "token") }
    var connected: Bool { token != nil && !root.isEmpty }

    private var client: Moodle.Client? {
        guard let t = token, let u = URL(string: root) else { return nil }
        return Moodle.Client(root: u, token: t)
    }

    // MARK: Connexion

    func login() {
        guard let b = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = .err(L("Adresse invalide."))
            return
        }
        busy = true
        status = .info(L("Recherche du site…"))
        runInBackground({ try Moodle.publicConfig(b) }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let site):
                self.root = site.wwwroot
                let passport = String(Int.random(in: 100_000_000...999_999_999))
                guard let url = Moodle.launchURL(site: site, passport: passport) else { return }
                self.status = .info(L("Connecte-toi à l'ENT dans la fenêtre qui s'ouvre."))
                self.loginWindow = MoodleLoginWindow(url: url) { [weak self] token in
                    self?.loginWindow = nil
                    if let t = token { self?.finishLogin(token: t) } else { self?.status = nil }
                }
                self.loginWindow?.show()
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    private func finishLogin(token: String) {
        Keychain.save(token, account: "token")
        guard let c = client else { return }
        busy = true
        status = .info(L("Connecté, récupération de tes cours…"))
        runInBackground({ () -> (Moodle.SiteInfo, [Moodle.Course]) in
            let info = try c.siteInfo()
            return (info, try c.courses(user: info.userid))
        }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let (info, list)):
                self.d.set(info.userid, forKey: "moodle.userid")
                self.userName = info.fullname
                self.setCourses(list, firstTime: self.followed.isEmpty)
                self.status = .ok(String(format: L("%lld cours trouvés. Choisis ceux à suivre, puis Synchroniser."), list.count))
                self.scheduleAuto()
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    func logout() {
        Keychain.delete(account: "token")
        userName = ""
        courses = []
        status = .info(L("Déconnecté. Tes fichiers déjà téléchargés restent dans tes cours."))
        autoTimer?.invalidate()
        objectWillChange.send()
    }

    /// Liste des cours ; au premier passage, on suit ceux de l'année en cours et on devine la matière.
    private func setCourses(_ list: [Moodle.Course], firstTime: Bool) {
        let now = Int(Date().timeIntervalSince1970)
        courses = list.sorted { $0.fullname.localizedCaseInsensitiveCompare($1.fullname) == .orderedAscending }
        if firstTime {
            followed = Set(list.filter { ($0.enddate ?? 0) == 0 || ($0.enddate ?? 0) > now }.map { $0.id })
        }
        let existing = CoursesStore.shared.courses.map { (course: $0, name: CoursesStore.shared.name($0),
                                                          aliases: CoursesStore.shared.custom[$0.id]?.aliases ?? "") }
        var m = mapping
        for c in list where m[String(c.id)] == nil {
            let g = CourseImport.Group(name: Moodle.subjectName(c.fullname), domain: "", aliases: c.shortname, files: [], target: nil)
            if let found = CourseImport.match(g, in: existing) { m[String(c.id)] = found.url.path }
        }
        mapping = m
    }

    func refreshCourses() {
        guard let c = client else { return }
        busy = true
        runInBackground({ () -> [Moodle.Course] in
            let uid = try (self.userID != 0 ? self.userID : c.siteInfo().userid)
            return try c.courses(user: uid)
        }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let list): self.setCourses(list, firstTime: false)
            case .failure(let e): self.status = .err(e)
            }
        }
    }

    func target(of course: Moodle.Course) -> URL? {
        guard let p = mapping[String(course.id)], !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    func setTarget(_ u: URL?, for course: Moodle.Course) {
        mapping[String(course.id)] = u?.path ?? ""
    }

    // MARK: Synchronisation

    /// Télécharge les fichiers nouveaux ou modifiés des cours suivis et les range dans « Mes cours ».
    func sync(silent: Bool = false) {
        guard !busy, let c = client else { return }
        let follow = courses.isEmpty ? Array(followed) : courses.filter { followed.contains($0.id) }.map { $0.id }
        guard !follow.isEmpty else {
            if !silent { status = .info(L("Choisis au moins un cours à suivre.")) }
            return
        }
        let names = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, $0) })
        let mapping = self.mapping
        let known = synced
        let root = CoursesStore.shared.root ?? {
            let r = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Cours", isDirectory: true)
            try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            CoursesStore.shared.root = r
            return r
        }()
        busy = true
        progress = L("Lecture des cours…")
        if !silent { status = nil }

        runInBackground({ [weak self] () -> (CourseImport.Result, [String: Int], [Int: [URL]], Int, Int) in
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-moodle-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            var newSynced = known
            var groups: [CourseImport.Group] = []
            var groupCourse: [Int] = []
            var large = 0, failed = 0
            for (i, id) in follow.enumerated() {
                let title = names[id].map { Moodle.subjectName($0.fullname) } ?? "Cours \(id)"
                DispatchQueue.main.async { self?.progress = "\(i + 1)/\(follow.count) · " + title }
                let sections: [Moodle.Section]
                do { sections = try c.contents(course: id) } catch { failed += 1; continue }
                let (files, skipped) = Moodle.files(of: sections, course: id)
                large += skipped
                let todo = files.filter { known[$0.key] != $0.timemodified }
                guard !todo.isEmpty else { continue }
                var g = CourseImport.Group(name: title, domain: "", aliases: names[id]?.shortname ?? "", files: [], target: nil)
                if let p = mapping[String(id)], !p.isEmpty, FileManager.default.fileExists(atPath: p) { g.target = URL(fileURLWithPath: p) }
                for (j, f) in todo.enumerated() {
                    DispatchQueue.main.async { self?.progress = "\(i + 1)/\(follow.count) · \(title) · \(j + 1)/\(todo.count)" }
                    var local = stage.appendingPathComponent(String(id), isDirectory: true)
                    for comp in f.components { local.appendPathComponent(comp) }
                    do { try c.download(f.fileurl, to: local) } catch { failed += 1; continue }
                    let (kind, rel) = CourseImport.classify(f.components)
                    g.files.append(CourseImport.File(source: local, kind: kind, relative: rel))
                    newSynced[f.key] = f.timemodified
                }
                if !g.files.isEmpty {
                    groups.append(g)
                    groupCourse.append(id)
                }
            }
            let plan = CourseImport.Plan(groups: groups, workDir: nil, fromToolbox: false)
            let res = try CourseImport.apply(plan, root: root)
            // nouvelles matières créées : on retient leur dossier pour la prochaine fois
            var created: [Int: [URL]] = [:]
            var k = 0
            for (gi, g) in groups.enumerated() where g.target == nil && k < res.newSubjects.count {
                created[groupCourse[gi], default: []].append(res.newSubjects[k])
                k += 1
            }
            return (res, newSynced, created, large, failed)
        }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            self.progress = ""
            switch r {
            case .success(let (res, newSynced, created, large, failed)):
                self.synced = newSynced
                for (id, dirs) in created { if let first = dirs.first { self.mapping[String(id)] = first.path } }
                self.lastSync = Date()
                var text = res.copied.isEmpty ? L("Tout est à jour.") : String(format: L("%lld nouveau(x) fichier(s)."), res.copied.count)
                if !res.newSubjects.isEmpty { text += " " + String(format: L("%lld nouvelle(s) matière(s)"), res.newSubjects.count) + "." }
                if large > 0 { text += " " + String(format: L("%lld fichier(s) trop lourd(s) ignoré(s) (vidéos…)."), large) }
                if failed > 0 { text += " " + String(format: L("%lld échec(s)."), failed) }
                let msg: StatusMessage = res.copied.isEmpty ? .info(text) : .ok(text, files: Array(res.copied.prefix(20)))
                self.status = msg
                if !res.copied.isEmpty {
                    CoursesStore.shared.scan()
                    NotchController.shared.alert(NotchAlert(icon: "arrow.down.doc.fill", color: .blue, title: L("Nouveaux cours sur e-uapv"),
                                                            subtitle: Self.summary(res.copied)), seconds: 6)
                }
            case .failure(let e):
                self.status = .err(e)
                if (e as? MoodleError)?.text.contains("expirée") == true { Keychain.delete(account: "token"); self.objectWillChange.send() }
            }
        }
    }

    /// « 2 fichiers en Bases de maths, 1 en Analyse 1 »
    static func summary(_ files: [URL]) -> String {
        guard let root = CoursesStore.shared.root else { return String(format: L("%lld nouveau(x) fichier(s)."), files.count) }
        var bySubject: [String: Int] = [:]
        for f in files {
            let rel = f.path.replacingOccurrences(of: root.path + "/", with: "")
            let parts = rel.split(separator: "/").map(String.init)
            // la matière : le dossier juste au-dessus de cours/TDs/TPs/CCs
            let idx = parts.firstIndex { CourseKind.from(folder: $0) != nil } ?? max(0, parts.count - 2)
            let subject = idx > 0 ? parts[idx - 1] : (parts.first ?? "?")
            bySubject[subject, default: 0] += 1
        }
        return bySubject.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value) · \($0.key)" }.joined(separator: ", ")
    }

    // MARK: Synchro automatique

    func scheduleAuto() {
        autoTimer?.invalidate()
        autoTimer = nil
        guard autoHours > 0, connected else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.autoIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.autoIfDue() }
    }

    private func autoIfDue() {
        guard autoHours > 0, connected, !busy else { return }
        if let l = lastSync, Date().timeIntervalSince(l) < Double(autoHours) * 3600 { return }
        sync(silent: true)
    }
}

// MARK: - Fenêtre de connexion (page de l'ENT)

final class MoodleLoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let window: NSWindow
    private let web: WKWebView
    private var done: ((String?) -> Void)?

    init(url: URL, done: @escaping (String?) -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()          // rien ne reste après la connexion
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.done = done
        super.init()
        window.title = L("Connexion à l'ENT")
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        web.navigationDelegate = self
        web.load(URLRequest(url: url))
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(_ token: String?) {
        let d = done
        done = nil
        window.delegate = nil
        window.close()
        d?(token)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, u.scheme == "moodlemobile" {
            decisionHandler(.cancel)
            finish(Moodle.token(fromRedirect: u))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // le jeton peut aussi arriver dans l'adresse d'une redirection refusée
        if let u = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL, u.scheme == "moodlemobile" {
            finish(Moodle.token(fromRedirect: u))
        }
    }

    func windowWillClose(_ notification: Notification) {
        let d = done
        done = nil
        d?(nil)
    }
}

// MARK: - Feuille « Synchroniser avec e-uapv »

struct MoodleSheet: View {
    @ObservedObject var m = MoodleStore.shared
    @ObservedObject var courses = CoursesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.title).foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Synchroniser avec Moodle").font(.title3.weight(.semibold))
                    Text(m.connected ? L("Connecté") + " : " + m.userName + " · " + m.root.replacingOccurrences(of: "https://", with: "")
                                     : L("Récupère tout seul les fichiers de tes cours, triés par matière."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fermer") { m.showSheet = false }.keyboardShortcut(.cancelAction)
            }

            if !m.connected {
                Form {
                    TextField("Adresse du Moodle", text: $m.base, prompt: Text("https://e-uapv.univ-avignon.fr"))
                    Text("La connexion se fait sur la page habituelle de l'ENT, dans une fenêtre de Toolbox : ton mot de passe n'est jamais vu ni gardé par Toolbox, seul un jeton d'accès est rangé dans le trousseau du Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    if m.busy { ProgressView().controlSize(.small) }
                    Button("Se connecter à l'ENT") { m.login() }.buttonStyle(.borderedProminent).disabled(m.busy)
                }
            } else {
                HStack {
                    Text("Cours à suivre").font(.headline)
                    Spacer()
                    Button { m.refreshCourses() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Recharger la liste des cours")
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(m.courses) { c in courseRow(c) }
                        if m.courses.isEmpty {
                            Text(m.busy ? L("Chargement…") : L("Aucun cours : recharge la liste."))
                                .foregroundStyle(.secondary).padding()
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 340)
                HStack {
                    Picker("Synchro automatique", selection: $m.autoHours) {
                        ForEach(MoodleStore.autoChoices, id: \.0) { Text(L($0.1)).tag($0.0) }
                    }
                    .fixedSize()
                    Spacer()
                    if let l = m.lastSync {
                        Text(L("Dernière synchro") + " : " + l.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
                HStack {
                    Button("Se déconnecter") { m.logout() }.buttonStyle(.borderless).font(.caption)
                    Spacer()
                    if m.busy {
                        ProgressView().controlSize(.small)
                        Text(m.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button("Synchroniser") { m.sync() }
                        .buttonStyle(.borderedProminent)
                        .disabled(m.busy || m.followed.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            if let s = m.status { StatusBanner(message: s) }
        }
        .padding(22)
        .frame(width: 640)
        .onAppear { if m.connected && m.courses.isEmpty { m.refreshCourses() } }
    }

    private func courseRow(_ c: Moodle.Course) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { m.followed.contains(c.id) },
                                     set: { on in if on { m.followed.insert(c.id) } else { m.followed.remove(c.id) } }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(Moodle.subjectName(c.fullname)).font(.callout.weight(.medium)).lineLimit(1)
                Text(c.fullname).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Picker("", selection: Binding(get: { m.target(of: c) }, set: { m.setTarget($0, for: c) })) {
                Text("Nouvelle matière").tag(URL?.none)
                Divider()
                ForEach(courses.courses) { cc in Text(courses.name(cc)).tag(Optional(cc.url)) }
            }
            .labelsHidden()
            .frame(width: 200)
            .disabled(!m.followed.contains(c.id))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .opacity(m.followed.contains(c.id) ? 1 : 0.6)
    }
}
