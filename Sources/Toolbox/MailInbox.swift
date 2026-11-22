import SwiftUI
import AppKit
import PDFCore

// MARK: - Mails (fac + boîte perso) par l'app Mail
//
// Toolbox ne se connecte à aucun serveur et ne voit aucun mot de passe : il pilote l'app Mail (AppleScript), où tes
// comptes sont déjà configurés (Outlook/Hotmail, Partage de la fac, Gmail…). Il lit les derniers mails de chaque boîte
// de réception, les classe par importance avec des règles simples (fac et profs en haut, pubs en bas, tes propres
// règles par expéditeur), et agit dessus dans Mail : lu / non lu, drapeau, archiver, supprimer. Notification (île
// dynamique, iPhone via ntfy) pour un nouveau mail important non lu.

enum MailBridge {
    static let sep = "\u{1F}"     // champs
    static let rec = "\u{1E}"     // mails

    struct Message: Identifiable, Hashable {
        let account: String
        let mailbox: String
        let mailID: Int
        let sender: String
        let subject: String
        let date: Date
        var read: Bool
        var flagged: Bool
        let messageID: String
        let snippet: String
        var id: String { account + "|" + String(mailID) }

        /// « Jean Dupont <jean.dupont@univ-avignon.fr> » → adresse seule, en minuscules
        var address: String {
            if let a = sender.range(of: "<"), let b = sender.range(of: ">", range: a.upperBound..<sender.endIndex) {
                return String(sender[a.upperBound..<b.lowerBound]).lowercased()
            }
            return sender.trimmingCharacters(in: .whitespaces).lowercased()
        }
        var senderName: String {
            if let a = sender.range(of: "<") {
                let n = sender[..<a.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                if !n.isEmpty { return n }
            }
            return address
        }
        var domain: String { address.split(separator: "@").last.map(String.init) ?? "" }
        var openURL: URL? {
            guard !messageID.isEmpty else { return nil }
            let enc = messageID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? messageID
            return URL(string: "message://%3C" + enc + "%3E")
        }
    }

    static func run(_ script: String, _ args: [String] = []) throws -> String {
        let out = try Shell.run("/usr/bin/osascript", ["-e", script] + args)
        guard out.status == 0 else {
            let t = out.text
            if t.contains("-1743") || t.contains("Not authorized") || t.contains("pas autorisé") {
                throw PDFToolError.commandFailed(L("Toolbox n'a pas le droit de piloter Mail. Autorise-le dans Réglages Système → Confidentialité et sécurité → Automatisation → Toolbox → Mail."))
            }
            if t.contains("-1728") || t.contains("Can’t get") || t.contains("Impossible d’obtenir") {
                throw PDFToolError.commandFailed(L("Mail introuvable (déplacé ou supprimé entre-temps ?)."))
            }
            throw PDFToolError.commandFailed("Mail : " + String(t.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))
        }
        return out.text
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }

    /// Lance Mail en arrière-plan (caché) pour qu'il relève le courrier.
    static func launchHidden() {
        guard !isRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    private static let inboxFinder = """
        on findInbox(acc)
            tell application "Mail"
                repeat with nm in {"INBOX", "Inbox", "Boîte de réception", "Boite de reception"}
                    try
                        return mailbox (nm as text) of acc
                    end try
                end repeat
            end tell
            return missing value
        end findInbox
        """

    /// Derniers mails de la boîte de réception de chaque compte actif (les `limit` plus récents).
    static func recent(limit: Int, snippets: Int) throws -> [Message] {
        let script = inboxFinder + """

        on run argv
            set sep to item 1 of argv
            set rs to item 2 of argv
            set lim to (item 3 of argv) as integer
            set snipLim to (item 4 of argv) as integer
            set nowDate to current date
            set out to ""
            tell application "Mail"
                repeat with acc in (every account whose enabled is true)
                    set accName to name of acc
                    set ib to my findInbox(acc)
                    if ib is not missing value then
                        set ibName to name of ib
                        set n to count of messages of ib
                        if n > lim then set n to lim
                        repeat with i from 1 to n
                            try
                                set m to message i of ib
                                set offs to ((date received of m) - nowDate) as integer
                                set snip to ""
                                if i ≤ snipLim then
                                    try
                                        set c to content of m
                                        if (length of c) > 240 then set c to text 1 thru 240 of c
                                        set snip to c
                                    end try
                                end if
                                set mid to ""
                                try
                                    set mid to message id of m
                                end try
                                set out to out & accName & sep & ibName & sep & (id of m) & sep & (sender of m) & sep & (subject of m) & sep & offs & sep & (read status of m) & sep & (flagged status of m) & sep & mid & sep & snip & rs
                            end try
                        end repeat
                    end if
                end repeat
            end tell
            return out
        end run
        """
        let now = Date()
        return try run(script, [sep, rec, String(limit), String(snippets)]).components(separatedBy: rec).compactMap { r in
            let f = r.components(separatedBy: sep)
            guard f.count >= 10, let id = Int(f[2].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            let acc = f[0].trimmingCharacters(in: .newlines)
            let snippet = f[9...].joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Message(account: acc, mailbox: f[1], mailID: id, sender: f[3], subject: f[4].isEmpty ? L("(sans objet)") : f[4],
                           date: now.addingTimeInterval(TimeInterval(Int(f[5]) ?? 0)), read: f[6] == "true", flagged: f[7] == "true",
                           messageID: f[8], snippet: snippet)
        }
    }

    enum Action: String { case read, unread, flag, unflag, archive, trash }

    /// Agit sur un mail dans Mail. Archiver : vers le dossier « Archive(s) » du compte (ou l'archive de Mail).
    static func perform(_ a: Action, on m: Message) throws {
        let script = """
        on run argv
            set accName to item 1 of argv
            set ibName to item 2 of argv
            set mid to (item 3 of argv) as integer
            set act to item 4 of argv
            tell application "Mail"
                set acc to account accName
                set m to (first message of mailbox ibName of acc whose id is mid)
                if act is "read" then
                    set read status of m to true
                else if act is "unread" then
                    set read status of m to false
                else if act is "flag" then
                    set flagged status of m to true
                else if act is "unflag" then
                    set flagged status of m to false
                else if act is "trash" then
                    delete m
                else if act is "archive" then
                    set dest to missing value
                    repeat with nm in {"Archive", "Archives", "Archivé", "Archiver", "Archived"}
                        try
                            set dest to mailbox (nm as text) of acc
                            exit repeat
                        end try
                    end repeat
                    if dest is missing value then
                        set read status of m to true
                        error "noarchive"
                    end if
                    set read status of m to true
                    move m to dest
                end if
            end tell
            return "ok"
        end run
        """
        do {
            try run(script, [m.account, m.mailbox, String(m.mailID), a.rawValue])
        } catch let e as PDFToolError where "\(e)".contains("noarchive") {
            throw PDFToolError.commandFailed(String(format: L("Pas de dossier « Archive » sur le compte %@ : crée-le dans Mail (clic droit sur le compte → Nouvelle boîte)."), m.account))
        }
    }
}

// MARK: - Importance

enum MailImportance: Int, Comparable, CaseIterable {
    case low = 0, normal = 1, high = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .high: return L("Important")
        case .normal: return L("Normal")
        case .low: return L("Pubs et newsletters")
        }
    }
    var color: Color {
        switch self {
        case .high: return .red
        case .normal: return .blue
        case .low: return .secondary
        }
    }

    static let schoolDomains = ["univ-avignon.fr", "alumni.univ-avignon.fr", "etudiant.univ-avignon.fr", "crous-aix-marseille.fr",
                                "etudiant.gouv.fr", "messervices.etudiant.gouv.fr", "parcoursup.fr", "campusfrance.org"]
    static let robots = #"^(no-?reply|ne-?pas-?repondre|donotreply|newsletters?|news|marketing|promo(tions?)?|offres?|info(rmations?)?|hello|bonjour|contact|team|equipe|notifications?|mailer|communication|deals?)([._+-].*)?@"#
    static let urgentWords = #"\b(examens?|partiels?|cc ?[0-9]?|controles?|convocations?|rattrapages?|notes?|resultats?|inscriptions?|scolarite|bourses?|crous|annule|annulation|reporte|report|urgent|important|emploi du temps|edt|salle|stages?|jury|date limite|deadline|a rendre|rendu|soutenance|absence|justificatif|attestation|certificat)\b"#
    static let promoWords = #"(\bpromo|\boffre|soldes|black friday|cyber monday|newsletter|code promo|livraison offerte|derniers jours|-[0-9]{1,2} ?%|[0-9]{1,2} ?% de reduction|decouvrez|webinar|jusqu.a -|bon plan|vente privee|abonnez|exclusivite|gratuit pendant)"#

    /// Règles, dans l'ordre : les tiennes (adresse puis domaine) → pub évidente → fac / mot-clé urgent → robot → normal.
    static func of(_ m: MailBridge.Message, rules: [String: Int], schoolAccounts: Set<String>) -> MailImportance {
        if let r = rules[m.address] ?? rules["@" + m.domain], let lvl = MailImportance(rawValue: r) { return lvl }
        let subject = CourseLibrary.fold(m.subject)
        let robot = m.address.range(of: robots, options: .regularExpression) != nil
        let school = schoolDomains.contains { m.domain == $0 || m.domain.hasSuffix("." + $0) }
        if subject.range(of: promoWords, options: .regularExpression) != nil && !school { return .low }
        if school && !robot { return .high }
        if schoolAccounts.contains(m.account) && !robot { return .high }
        if subject.range(of: urgentWords, options: .regularExpression) != nil && (school || !robot) { return .high }
        if robot { return school ? .normal : .low }
        return .normal
    }
}

// MARK: - Magasin

final class MailStore: ObservableObject {
    static let shared = MailStore()
    private let d = UserDefaults.standard

    enum Filter: String, CaseIterable, Identifiable {
        case important = "Importants", unread = "Non lus", all = "Tous"
        var id: String { rawValue }
    }

    @Published var messages: [MailBridge.Message] = []
    @Published var busy = false
    @Published var status: StatusMessage?
    @Published var lastRefresh: Date?
    @Published var filter: Filter = .important
    @Published var account: String = ""          // "" = tous
    @Published var showSettings = false

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "mail.enabled"); schedule() } }
    @Published var keepMailOpen: Bool { didSet { d.set(keepMailOpen, forKey: "mail.keepOpen") } }
    @Published var notifyImportant: Bool { didSet { d.set(notifyImportant, forKey: "mail.notify") } }
    @Published var perAccount: Int { didSet { d.set(perAccount, forKey: "mail.limit") } }
    /// Comptes de la fac : tout mail d'une vraie personne y est important.
    @Published var schoolAccounts: Set<String> { didSet { d.set(Array(schoolAccounts), forKey: "mail.schoolAccounts") } }
    /// adresse ou « @domaine » → importance choisie par toi
    @Published var rules: [String: Int] { didSet { d.set(rules, forKey: "mail.rules") } }

    private var timer: Timer?
    private var seen: Set<String> {
        get { Set(d.stringArray(forKey: "mail.seen") ?? []) }
        set { d.set(Array(newValue.suffix(3000)), forKey: "mail.seen") }
    }

    init() {
        let u = UserDefaults.standard
        enabled = u.bool(forKey: "mail.enabled")
        keepMailOpen = u.object(forKey: "mail.keepOpen") as? Bool ?? true
        notifyImportant = u.object(forKey: "mail.notify") as? Bool ?? true
        perAccount = u.object(forKey: "mail.limit") as? Int ?? 40
        schoolAccounts = Set(u.stringArray(forKey: "mail.schoolAccounts") ?? [])
        rules = (u.dictionary(forKey: "mail.rules") as? [String: Int]) ?? [:]
    }

    var accounts: [String] { Array(Set(messages.map { $0.account })).sorted() }

    func importance(_ m: MailBridge.Message) -> MailImportance {
        MailImportance.of(m, rules: rules, schoolAccounts: schoolAccounts)
    }

    var visible: [MailBridge.Message] {
        messages.filter { m in
            (account.isEmpty || m.account == account) && {
                switch filter {
                case .important: return importance(m) == .high || m.flagged
                case .unread: return !m.read
                case .all: return true
                }
            }()
        }
    }

    var unreadImportant: Int { messages.filter { !$0.read && importance($0) == .high }.count }

    // MARK: Rafraîchir

    /// Toutes les 5 min si activé. Mail fermé : relancé caché si tu l'as demandé, sinon on attend.
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh(silent: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.refresh(silent: true) }
    }

    func refresh(silent: Bool = false) {
        guard !busy else { return }
        if !MailBridge.isRunning {
            if keepMailOpen || !silent { MailBridge.launchHidden() } else { return }
        }
        busy = true
        if !silent { status = nil }
        let limit = perAccount
        runInBackground({ try MailBridge.recent(limit: limit, snippets: 25) }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let list):
                self.messages = list.sorted { $0.date > $1.date }
                self.lastRefresh = Date()
                self.notifyNew()
                if !silent {
                    self.status = list.isEmpty
                        ? .info(L("Aucun mail trouvé : ajoute tes comptes dans l'app Mail (Mail → Réglages → Comptes)."))
                        : .ok(String(format: L("%lld mails, dont %lld importants non lus."), list.count, self.unreadImportant))
                }
            case .failure(let e):
                // Mail qui démarre : on réessaie une fois un peu plus tard
                if !silent { self.status = .err(e) }
            }
        }
    }

    /// Nouveau mail important non lu → île dynamique + iPhone. Au tout premier passage : mémorisés sans alerte.
    private func notifyNew() {
        var s = seen
        let first = !d.bool(forKey: "mail.seenInit")
        let fresh = messages.filter { !s.contains($0.id) }
        fresh.forEach { s.insert($0.id) }
        seen = s
        if first { d.set(true, forKey: "mail.seenInit"); return }
        guard notifyImportant else { return }
        let important = fresh.filter { !$0.read && importance($0) == .high && $0.date > Date().addingTimeInterval(-86400 * 2) }
        for m in important.prefix(3) {
            NotchController.shared.alert(NotchAlert(icon: "envelope.badge.fill", color: .blue, title: m.senderName,
                                                    subtitle: m.subject), seconds: 8)
            PushNotifier.send(title: "✉️ " + m.senderName, body: m.subject + (m.snippet.isEmpty ? "" : "\n" + String(m.snippet.prefix(140))),
                              tags: ["email"], priority: 4)
        }
    }

    // MARK: Actions

    func act(_ a: MailBridge.Action, _ m: MailBridge.Message) {
        guard let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
        let before = messages[i]
        // tout de suite à l'écran, Mail suit
        switch a {
        case .read: messages[i].read = true
        case .unread: messages[i].read = false
        case .flag: messages[i].flagged = true
        case .unflag: messages[i].flagged = false
        case .archive, .trash: messages.remove(at: i)
        }
        runInBackground({ try MailBridge.perform(a, on: m) }) { [weak self] r in
            guard let self = self else { return }
            if case .failure(let e) = r {
                self.status = .err(e)
                if let j = self.messages.firstIndex(where: { $0.id == m.id }) { self.messages[j] = before }
                else { self.messages.append(before); self.messages.sort { $0.date > $1.date } }
            } else if a == .trash {
                self.status = .ok(L("Mis à la corbeille dans Mail."))
            } else if a == .archive {
                self.status = .ok(L("Archivé."))
            }
        }
    }

    func open(_ m: MailBridge.Message) {
        if let u = m.openURL { NSWorkspace.shared.open(u) }
        if !m.read { act(.read, m) }
    }

    /// Règle par expéditeur (ou tout son domaine) ; nil = enlever la règle.
    func setRule(_ lvl: MailImportance?, for m: MailBridge.Message, wholeDomain: Bool) {
        let key = wholeDomain ? "@" + m.domain : m.address
        rules[key] = lvl?.rawValue
    }

    func toggleSchool(_ acc: String) {
        if schoolAccounts.contains(acc) { schoolAccounts.remove(acc) } else { schoolAccounts.insert(acc) }
    }
}

// MARK: - Page « Mails »

struct MailToolView: View {
    @ObservedObject var s = MailStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .mail)
            if !s.enabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Toolbox lit tes mails dans l'app Mail : ajoute-y d'abord tes comptes (Mail → Réglages → Comptes), puis active.")
                        .foregroundStyle(.secondary)
                    Text("Aucun mot de passe n'est donné à Toolbox. macOS te demandera d'autoriser Toolbox à piloter Mail.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Activer les mails") { s.enabled = true; s.refresh() }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 20)
                Spacer()
            } else {
                HStack(spacing: 10) {
                    Picker("", selection: $s.filter) {
                        ForEach(MailStore.Filter.allCases) { f in
                            Text(L(f.rawValue) + (f == .important && s.unreadImportant > 0 ? " (\(s.unreadImportant))" : "")).tag(f)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if s.accounts.count > 1 {
                        Picker("", selection: $s.account) {
                            Text("Tous les comptes").tag("")
                            ForEach(s.accounts, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Spacer()
                    if s.busy { ProgressView().controlSize(.small) }
                    if let l = s.lastRefresh {
                        Text(L("Mis à jour") + " " + l.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { s.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(s.busy).help("Rafraîchir")
                    Button { s.showSettings.toggle() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Réglages des mails")
                        .popover(isPresented: $s.showSettings, arrowEdge: .bottom) { MailSettingsView() }
                }
                if let st = s.status { StatusBanner(message: st) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if s.visible.isEmpty {
                            Text(s.busy ? L("Chargement…") : (s.filter == .important ? L("Rien d'important. 🎉") : L("Aucun mail.")))
                                .foregroundStyle(.secondary).padding(.top, 20)
                        }
                        ForEach(s.visible) { m in MailRow(m: m) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if s.enabled && s.lastRefresh == nil { s.refresh(silent: true) } }
    }
}

struct MailRow: View {
    let m: MailBridge.Message
    @ObservedObject var s = MailStore.shared

    var body: some View {
        let lvl = s.importance(m)
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(m.read ? Color.clear : Color.accentColor).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if lvl == .high { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.red).font(.caption) }
                    Text(m.senderName).font(.body.weight(m.read ? .regular : .semibold)).lineLimit(1)
                    if m.flagged { Image(systemName: "flag.fill").foregroundStyle(Color.orange).font(.caption) }
                    Spacer()
                    Text(Self.when(m.date)).font(.caption).foregroundStyle(.secondary)
                }
                Text(m.subject).font(.callout.weight(m.read ? .regular : .medium)).lineLimit(1)
                if !m.snippet.isEmpty {
                    Text(m.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(m.account).font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { s.open(m) }
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Button { s.act(m.read ? .unread : .read, m) } label: {
                        Image(systemName: m.read ? "envelope.badge" : "envelope.open")
                    }
                    .help(m.read ? L("Marquer comme non lu") : L("Marquer comme lu"))
                    Button { s.act(m.flagged ? .unflag : .flag, m) } label: {
                        Image(systemName: m.flagged ? "flag.slash" : "flag")
                    }
                    .help(m.flagged ? L("Retirer le drapeau") : L("Signaler (drapeau)"))
                    Button { s.act(.archive, m) } label: { Image(systemName: "archivebox") }.help("Archiver")
                    Button { s.act(.trash, m) } label: { Image(systemName: "trash") }.help("Mettre à la corbeille")
                }
                .buttonStyle(.borderless)
            }
            .disabled(s.busy)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(lvl == .high && !m.read ? Color.red.opacity(0.06) : Color.primary.opacity(0.035)))
        .opacity(lvl == .low ? 0.7 : 1)
        .contextMenu {
            Button("Ouvrir dans Mail") { s.open(m) }
            Divider()
            Menu(String(format: L("Mails de %@"), m.address)) {
                Button("Toujours importants") { s.setRule(.high, for: m, wholeDomain: false) }
                Button("Toujours normaux") { s.setRule(.normal, for: m, wholeDomain: false) }
                Button("Toujours en pubs") { s.setRule(.low, for: m, wholeDomain: false) }
                Button("Classement automatique") { s.setRule(nil, for: m, wholeDomain: false) }
            }
            Menu(String(format: L("Tout le domaine %@"), m.domain)) {
                Button("Toujours importants") { s.setRule(.high, for: m, wholeDomain: true) }
                Button("Toujours normaux") { s.setRule(.normal, for: m, wholeDomain: true) }
                Button("Toujours en pubs") { s.setRule(.low, for: m, wholeDomain: true) }
                Button("Classement automatique") { s.setRule(nil, for: m, wholeDomain: true) }
            }
            Divider()
            Button("Copier l'adresse") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.address, forType: .string)
            }
        }
    }

    static func when(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(d) { return L("hier") }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct MailSettingsView: View {
    @ObservedObject var s = MailStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mails").font(.headline)
            Toggle("Relever toutes les 5 minutes", isOn: $s.enabled)
            Toggle("Garder Mail ouvert en arrière-plan", isOn: $s.keepMailOpen)
                .help("Sinon, rien n'est relevé tant que Mail est fermé")
            Toggle("Me prévenir d'un mail important (île, iPhone si ntfy)", isOn: $s.notifyImportant)
            Picker("Mails lus par compte", selection: $s.perAccount) {
                ForEach([20, 40, 80], id: \.self) { Text("\($0)").tag($0) }
            }
            .fixedSize()
            Divider()
            Text("Comptes de la fac").font(.subheadline.weight(.semibold))
            Text("Tout mail d'une vraie personne (pas un robot) sur ces comptes est important.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if s.accounts.isEmpty {
                Text("Rafraîchis d'abord pour voir tes comptes.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(s.accounts, id: \.self) { acc in
                Toggle(acc, isOn: Binding(get: { s.schoolAccounts.contains(acc) }, set: { _ in s.toggleSchool(acc) }))
            }
            if !s.rules.isEmpty {
                Divider()
                Text("Tes règles").font(.subheadline.weight(.semibold))
                ForEach(s.rules.keys.sorted(), id: \.self) { k in
                    HStack {
                        Text(k).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Text(MailImportance(rawValue: s.rules[k] ?? 1)?.label ?? "").font(.caption).foregroundStyle(.secondary)
                        Button { s.rules[k] = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }
                }
            }
            Text("Clic droit sur un mail pour toujours classer un expéditeur (ou tout son domaine).")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
    }
}
