import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers

/// Statut Discord (« Rich Presence ») : Toolbox parle directement à l'app Discord du Mac par son
/// canal local (socket $TMPDIR/discord-ipc-0). Rien ne passe par internet depuis Toolbox.
final class DiscordPresence: ObservableObject {
    static let shared = DiscordPresence()

    @Published var enabled = UserDefaults.standard.bool(forKey: "discord.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "discord.enabled")
            if enabled { refresh(force: true) } else { clear() }
        }
    }
    @Published var clientID = UserDefaults.standard.string(forKey: "discord.client") ?? "" {
        didSet {
            UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "discord.client")
            disconnect()
            if enabled { refresh(force: true) }
        }
    }
    @Published var showFileNames = UserDefaults.standard.bool(forKey: "discord.files") {
        didSet { UserDefaults.standard.set(showFileNames, forKey: "discord.files"); refresh(force: true) }
    }
    @Published var status = "Désactivé"
    @Published var connectedAs: String?
    @Published var preview: (details: String, state: String) = ("", "")

    /// Fourni par la fenêtre principale : (ligne 1, ligne 2) selon l'outil ouvert.
    var provider: () -> (String, String) = { ("Sur Toolbox", "PDF, LaTeX & cours") }

    private let queue = DispatchQueue(label: "fr.arthur.toolbox.discord")
    private var fd: Int32 = -1
    private var lastSent = Date.distantPast
    private var pending: DispatchWorkItem?
    private var timer: Timer?
    private let startedAt = Int(Date().timeIntervalSince1970)
    private var lastActivity = ""

    func start() {
        guard timer == nil else { return }
        // rafraîchit (erreurs LaTeX, cours en cours…) et retente la connexion si Discord vient d'être ouvert
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
        if enabled { refresh(force: true) }
    }

    // MARK: Mise à jour (au plus une toutes les 5 s, comme le demande Discord)

    func refresh(force: Bool = false) {
        let p = provider()
        preview = (p.0, p.1)
        guard enabled else { return }
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { status = "Colle l'identifiant de ton application Discord dans les réglages."; return }
        let activity = Self.activity(details: p.0, state: p.1, start: startedAt)
        let key = p.0 + "|" + p.1
        guard force || key != lastActivity || fd < 0 else { return }
        lastActivity = key
        pending?.cancel()
        let wait = max(0, 5 - Date().timeIntervalSince(lastSent))
        let work = DispatchWorkItem { [weak self] in self?.send(activity, clientID: id) }
        pending = work
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    func clear() {
        pending?.cancel()
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.fd >= 0 { _ = self.setActivity(nil) }
            self.closeSocket()
            DispatchQueue.main.async { self.status = "Désactivé"; self.connectedAs = nil; self.lastActivity = "" }
        }
    }

    private func disconnect() {
        queue.async { [weak self] in self?.closeSocket() }
        connectedAs = nil
        lastActivity = ""
    }

    static func activity(details: String, state: String, start: Int) -> [String: Any] {
        func clip(_ s: String) -> String {
            let t = s.count < 2 ? s + "  " : s
            return String(t.prefix(120))
        }
        return [
            "details": clip(details),
            "state": clip(state),
            "timestamps": ["start": start],
            "assets": ["large_image": "toolbox", "large_text": "Toolbox — PDF, LaTeX & cours, 100 % local"],
        ]
    }

    // MARK: Connexion locale à Discord

    private func send(_ activity: [String: Any], clientID: String) {
        lastSent = Date()
        if fd < 0 {
            guard connect(clientID: clientID) else { return }
        }
        if !setActivity(activity) {
            // Discord a peut-être redémarré : une nouvelle tentative
            closeSocket()
            if connect(clientID: clientID) { _ = setActivity(activity) }
        }
    }

    private func connect(clientID: String) -> Bool {
        guard let s = openSocket() else {
            DispatchQueue.main.async { self.status = "Discord n'est pas ouvert (ou pas trouvé)."; self.connectedAs = nil }
            return false
        }
        fd = s
        guard write(op: 0, ["v": 1, "client_id": clientID]), let ready = readFrame() else {
            closeSocket()
            DispatchQueue.main.async { self.status = "Discord n'a pas répondu." }
            return false
        }
        if ready.op == 1, (ready.json["evt"] as? String) == "READY" {
            let user = ((ready.json["data"] as? [String: Any])?["user"] as? [String: Any])?["username"] as? String
            DispatchQueue.main.async {
                self.connectedAs = user
                self.status = user.map { "Connecté à Discord (\($0))." } ?? "Connecté à Discord."
            }
            return true
        }
        closeSocket()
        let message = (ready.json["message"] as? String) ?? "connexion refusée"
        DispatchQueue.main.async { self.status = "Discord refuse : \(message) (identifiant d'application correct ?)" }
        return false
    }

    private func setActivity(_ activity: [String: Any]?) -> Bool {
        var args: [String: Any] = ["pid": Int(getpid())]
        if let a = activity { args["activity"] = a }
        let ok = write(op: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString])
        if ok { _ = readFrame() }
        return ok
    }

    private func openSocket() -> Int32? {
        let dirs = [NSTemporaryDirectory(), ProcessInfo.processInfo.environment["TMPDIR"] ?? "", "/tmp/"]
        for dir in dirs where !dir.isEmpty {
            for i in 0..<10 {
                let path = (dir as NSString).appendingPathComponent("discord-ipc-\(i)")
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let s = socket(AF_UNIX, SOCK_STREAM, 0)
                guard s >= 0 else { continue }
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(path.utf8.prefix(103))
                withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                    for (k, b) in bytes.enumerated() { buf[k] = b }
                    buf[bytes.count] = 0
                }
                let r = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                if r == 0 { return s }
                close(s)
            }
        }
        return nil
    }

    private func closeSocket() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func write(op: UInt32, _ json: [String: Any]) -> Bool {
        guard fd >= 0, let payload = try? JSONSerialization.data(withJSONObject: json) else { return false }
        var frame = Data()
        var o = op.littleEndian, n = UInt32(payload.count).littleEndian
        frame.append(Data(bytes: &o, count: 4))
        frame.append(Data(bytes: &n, count: 4))
        frame.append(payload)
        return frame.withUnsafeBytes { buf -> Bool in
            var sent = 0
            while sent < frame.count {
                let w = Darwin.write(fd, buf.baseAddress!.advanced(by: sent), frame.count - sent)
                if w <= 0 { return false }
                sent += w
            }
            return true
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            while got < count {
                let r = read(fd, buf.baseAddress!.advanced(by: got), count - got)
                if r <= 0 { return false }
                got += r
            }
            return true
        }
        return ok ? data : nil
    }

    private func readFrame() -> (op: UInt32, json: [String: Any])? {
        guard let header = readExactly(8) else { return nil }
        let op = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let len = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.littleEndian)
        guard len >= 0, len < 1_000_000, let body = readExactly(len) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return (op, json)
    }

    // MARK: Textes (un peu absurdes, c'est le but)

    static func text(for tool: Tool, latex: LatexModel, home: HomeStore, showFiles: Bool) -> (String, String) {
        let courses = CoursesStore.shared
        switch tool {
        case .home:
            switch home.mascotMood {
            case .sunny: return ("Sur l'accueil de Toolbox", "La Feuille bronze ☀️")
            case .rainy: return ("Sur l'accueil de Toolbox", "La Feuille s'abrite sous son parapluie ☔")
            case .snowy: return ("Sur l'accueil de Toolbox", "La Feuille a sorti le bonnet ❄️")
            case .sleepy: return ("Travaille encore à cette heure-ci", "La Feuille, elle, dort 😴")
            default: return ("Sur l'accueil de Toolbox", "Admire sa mascotte")
            }
        case .courses:
            if let n = courses.now {
                return ("En plein cours de \(courses.name(n.course))", "Prend des notes (promis) ✍️")
            }
            if let c = courses.selected {
                let p = CourseMarks.shared.progress(c)
                return ("Révise \(courses.name(c))", p.total > 0 ? "\(p.done)/\(p.total) séances faites" : "Range ses cours")
            }
            return ("Range ses cours", "Enfin organisé 📚")
        case .latex:
            guard let tex = latex.texURL else { return ("Fixe une page LaTeX blanche", "L'inspiration arrive…") }
            let what = showFiles ? "Écrit \(tex.lastPathComponent)" : "Écrit du LaTeX"
            if latex.compiling { return (what, "Compile… 🤞") }
            if latex.lastSuccess == false {
                let n = max(1, latex.errorCount)
                return (what, "Se bat avec \(n) erreur\(n > 1 ? "s" : "") LaTeX 😭")
            }
            if latex.lastSuccess == true { return (what, "Ça compile du premier coup ✅") }
            return (what, "Tape des \\begin{} à la chaîne")
        case .annales: return ("Fouille la banque d'annales", "Cherche le sujet qui tombera 🔮")
        case .revisions:
            if let p = RevisionsStore.shared.next, let d = p.daysLeft {
                return ("Révise pour un CC", d <= 1 ? "C'est pour \(d == 0 ? "aujourd'hui" : "demain") 😰" : "J-\(d), \(Int(p.progress * 100)) % de la checklist ✅")
            }
            return ("Révise", "Coche des cases ✅")
        case .grades: return ("Calcule sa moyenne", "Compte sur la compensation 🙏")
        case .calc: return ("Trace des courbes", "f(x) = tout va bien 📈")
        case .planning: return ("Regarde son planning", "Calcule ses heures 🍟")
        case .compare: return ("Joue au jeu des 7 différences", "Entre deux PDF 🔍")
        case .sign: return ("Signe des documents", "Sans avoir lu les conditions ✍️")
        case .compress: return ("Compresse des PDF", "Chaque octet compte")
        case .merge: return ("Fusionne des PDF", "1 + 1 = 1")
        case .split: return ("Découpe des PDF", "Avec une précision chirurgicale ✂️")
        case .organize: return ("Range ses pages", "Le Marie Kondo du PDF")
        case .ocr: return ("Apprend à lire à un scan", "OCR en cours 👓")
        case .stamp: return ("Numérote des pages", "1, 2, 3… soleil")
        case .security: return ("Cadenasse des PDF 🔒", "Mot de passe : ********")
        case .convert: return ("Convertit des fichiers", "Alchimiste des formats ⚗️")
        case .layout: return ("Fait de la mise en page", "2 pages par feuille, c'est écolo 🌱")
        case .batch: return ("Automatise tout", "Pendant ce temps, il boit un café ☕")
        }
    }

    /// Icône 512 px pour l'application Discord (Rich Presence → Art Assets, nom « toolbox »).
    static func exportIcon() {
        guard let icon = NSApp.applicationIconImage,
              let out = Panels.save(suggested: "toolbox.png", type: .png, directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")) else { return }
        let size = NSSize(width: 512, height: 512)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep = rep else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: out)
            NSWorkspace.shared.activateFileViewerSelecting([out])
        }
    }
}

// MARK: - Fenêtre Réglages (⌘,)

final class GeneralSettings: ObservableObject {
    static let shared = GeneralSettings()

    @Published var searchHotKey = UserDefaults.standard.object(forKey: "courses.hotkey") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(searchHotKey, forKey: "courses.hotkey")
            if searchHotKey {
                GlobalHotKey.shared.register { QuickSearchPanel.shared.toggle() }
            } else {
                GlobalHotKey.shared.unregister(id: 1)
            }
        }
    }
    @Published var firstName = UserProfile.firstName {
        didSet { if UserProfile.firstName != firstName { UserProfile.firstName = firstName } }
    }
    @Published var courseNotify = UserDefaults.standard.object(forKey: "courses.notify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(courseNotify, forKey: "courses.notify") }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("Général", systemImage: "person.crop.circle") }
            DiscordSettings()
                .tabItem { Label("Discord", systemImage: "gamecontroller.fill") }
            ShortcutSettings()
                .tabItem { Label("Raccourcis", systemImage: "keyboard") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

struct DiscordSettings: View {
    @ObservedObject var d = DiscordPresence.shared

    var body: some View {
        Form {
            Toggle("Afficher ce que je fais dans Toolbox sur mon statut Discord", isOn: $d.enabled)
            TextField("Identifiant de l'application Discord", text: $d.clientID, prompt: Text("Ex. : 1234567890123456789"))
            Toggle("Montrer les noms de fichiers (sinon : « Écrit du LaTeX »)", isOn: $d.showFileNames)
            Label(d.status, systemImage: d.connectedAs != nil ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(d.connectedAs != nil ? Color.green : Color.secondary)
                .font(.callout)
            GroupBox("Aperçu") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Joue à Toolbox").font(.callout.bold())
                        Text(d.preview.details).font(.callout)
                        Text(d.preview.state).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(6)
            }
            GroupBox("Mise en place (une seule fois, 1 minute)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Ouvre le portail développeur de Discord et clique « New Application ». Le nom que tu choisis (ex. « Toolbox ») s'affiche après « Joue à ».")
                    Button("Ouvrir discord.com/developers/applications") {
                        NSWorkspace.shared.open(URL(string: "https://discord.com/developers/applications")!)
                    }
                    Text("2. Copie l'« Application ID » (page General Information) et colle-le ci-dessus.")
                    Text("3. Facultatif, pour l'icône : Rich Presence → Art Assets → ajoute une image nommée « toolbox ».")
                    Button("Enregistrer l'icône de Toolbox (toolbox.png)…") { DiscordPresence.exportIcon() }
                    Text("Discord doit être ouvert sur ce Mac, et « Afficher mon activité » activé dans ses réglages (Confidentialité de l'activité).")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        .formStyle(.grouped)
        .onAppear { d.refresh() }
    }
}

struct ShortcutSettings: View {
    @ObservedObject var g = GeneralSettings.shared
    @ObservedObject var apps = AppShortcutsStore.shared

    var body: some View {
        Form {
            Toggle("⌥Espace : chercher dans mes cours depuis n'importe quelle app", isOn: $g.searchHotKey)
            Toggle("⌃⌥1 … ⌃⌥9 : lancer les apps du widget « Mes apps »", isOn: $apps.hotKeysOn)
            Toggle("Notification au début d'un cours (d'après le calendrier)", isOn: $g.courseNotify)
            Text("Dans l'app : ⌘K palette de commandes · ⇧⌘T capture → texte · ⌘B compiler (LaTeX) · ⇧⌘N nouveau document LaTeX")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct GeneralTab: View {
    @ObservedObject var g = GeneralSettings.shared
    @ObservedObject var courses = CoursesStore.shared

    var body: some View {
        Form {
            TextField("Ton prénom", text: $g.firstName)
            LabeledContent("Dossier de cours") {
                HStack {
                    Text(courses.root?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Aucun")
                        .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                    Button("Choisir…") {
                        if let u = Panels.folder(directory: courses.root, prompt: "Mes cours sont ici") { courses.root = u }
                    }
                }
            }
            Button("Relancer la configuration de bienvenue") { OnboardingState.shared.restart() }
            MacAlertSettings()
        }
        .formStyle(.grouped)
    }
}

final class MacAlertState: ObservableObject {
    @Published var enabled = BatteryReminder.enabled { didSet { BatteryReminder.enabled = enabled } }
    @Published var threshold = BatteryReminder.threshold { didSet { BatteryReminder.threshold = threshold } }
    @Published var message = ""
}

struct MacAlertSettings: View {
    @StateObject private var st = MacAlertState()

    var body: some View {
        Section("Mon Mac") {
            Toggle("Alerte sur l'iPhone quand la batterie du Mac est basse", isOn: $st.enabled)
            if st.enabled {
                Picker("Seuil", selection: $st.threshold) {
                    ForEach([30, 25, 20, 15, 10], id: \.self) { Text("\($0) %").tag($0) }
                }
                Text("Toolbox crée un rappel « 🔋 Recharge ton Mac » dans l'app Rappels : il sonne sur l'iPhone (iCloud) et se coche tout seul quand tu branches le Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Tester l'alerte") {
                        let m = MacStatusStore.shared
                        if BatteryReminder.hasAccess {
                            BatteryReminder.post(m.battery?.percent ?? 18, minutesLeft: m.battery?.minutesLeft)
                            st.message = "Rappel créé : il sonne sur l'iPhone dans environ une minute."
                        } else {
                            BatteryReminder.requestAccess { ok in
                                st.message = ok ? "Accès accordé, clique encore sur « Tester »." : "Autorise Toolbox dans Réglages Système → Confidentialité → Rappels."
                            }
                        }
                    }
                    if !st.message.isEmpty { Text(st.message).font(.caption) }
                }
            }
        }
    }
}
