import Foundation
import SwiftUI
import AppKit
import EventKit
import UserNotifications
import PDFCore

/// Ce qui se passe aujourd'hui : cours (calendrier), shift, prochain CC, batteries.
/// Sert au check du matin (notification) et au widget iPhone « Ma journée ».
enum Today {
    struct Lesson: Equatable {
        var name: String
        var title: String
        var start: Date
        var end: Date
        var location: String?
    }

    /// Événements du jour qui correspondent à une matière de « Mes cours ».
    /// (Magasin neuf à chaque appel : un magasin ouvert avant l'autorisation du Calendrier ne voit rien.)
    static func lessons(on day: Date = Date()) -> [Lesson] {
        guard HomeStore.hasAccess else { return [] }
        let store = EKEventStore()
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let cs = CoursesStore.shared
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }
            .compactMap { e -> Lesson? in
                guard let c = cs.course(matchingTitle: e.title ?? "") else { return nil }
                return Lesson(name: cs.name(c), title: e.title ?? "", start: e.startDate, end: e.endDate, location: e.location)
            }
            .sorted { $0.start < $1.start }
    }

    static func shift(on day: Date = Date()) -> WorkShift? {
        PlanningStore.shared.shifts.first { Calendar.current.isDate($0.start, inSameDayAs: day) }
    }

    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Check du matin

final class MorningCheck: ObservableObject {
    static let shared = MorningCheck()

    @Published var enabled = UserDefaults.standard.object(forKey: "morning.on") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "morning.on") }
    }
    @Published var time = Calendar.current.date(bySettingHour: UserDefaults.standard.object(forKey: "morning.hour") as? Int ?? 7,
                                                minute: UserDefaults.standard.object(forKey: "morning.minute") as? Int ?? 30,
                                                second: 0, of: Date()) ?? Date() {
        didSet {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            UserDefaults.standard.set(c.hour, forKey: "morning.hour")
            UserDefaults.standard.set(c.minute, forKey: "morning.minute")
        }
    }
    @Published var alsoPhone = UserDefaults.standard.object(forKey: "morning.phone") as? Bool ?? false {
        didSet { UserDefaults.standard.set(alsoPhone, forKey: "morning.phone") }
    }
    @Published var lastText = ""

    private var lastSent: Date? {
        get { UserDefaults.standard.object(forKey: "morning.last") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "morning.last") }
    }
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.tick() }
    }

    /// Envoie le check une fois par jour, entre l'heure choisie et 4 h plus tard (Mac en veille à 7 h 30 : à son réveil).
    func tick() {
        DayExport.export()
        guard enabled else { return }
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: time)
        guard let at = cal.date(bySettingHour: c.hour ?? 7, minute: c.minute ?? 30, second: 0, of: Date()) else { return }
        let now = Date()
        guard now >= at, now < at.addingTimeInterval(4 * 3600) else { return }
        if let last = lastSent, cal.isDateInToday(last) { return }
        lastSent = now
        send()
    }

    /// Les lignes du résumé.
    func compose() -> (title: String, lines: [String]) {
        var lines: [String] = []
        let lessons = Today.lessons()
        if lessons.isEmpty {
            lines.append("📚 Pas de cours aujourd'hui")
        } else {
            let list = lessons.prefix(4).map { "\(Today.hm.string(from: $0.start)) \($0.name)" }.joined(separator: ", ")
            lines.append("📚 \(lessons.count) cours : \(list)" + (lessons.count > 4 ? "…" : ""))
        }
        if let s = Today.shift() {
            lines.append("🍟 Shift \(Today.hm.string(from: s.start))–\(Today.hm.string(from: s.end)) (\(PlanningStore.hours(s.paidMinutes)))")
        }
        if let p = RevisionsStore.shared.next, let d = p.daysLeft, d <= 10 {
            let when = d == 0 ? "aujourd'hui" : (d == 1 ? "demain" : "dans \(d) j")
            lines.append("\(p.urgent ? "⚠️" : "📝") \(p.title) \(when) · \(Int((p.progress * 100).rounded())) % révisé")
        }
        // batteries
        var charge: [String] = []
        if let b = MacStatusStore.shared.battery, !b.plugged {
            let lastEnd = lessons.last?.end ?? Date()
            let needHours = max(0, lastEnd.timeIntervalSince(Date()) / 3600)
            if b.percent < 40 || (b.percent < 70 && needHours > 4) { charge.append("Mac \(b.percent) % → prends le chargeur") }
        }
        if let h = HeadphoneStore.shared.last, !h.charging, h.percent < 30 { charge.append("casque \(h.percent) %") }
        if let i = PhoneStatusStore.shared.info, !i.charging, i.battery < 40, Date().timeIntervalSince(i.updated) < 3 * 3600 {
            charge.append("iPhone \(i.battery) %")
        }
        if !charge.isEmpty { lines.append("🔋 " + charge.joined(separator: " · ")) }
        let name = UserProfile.firstName
        return ("☀️ Bonjour" + (name.isEmpty ? "" : " \(name)"), lines)
    }

    func send() {
        let c = compose()
        let body = c.lines.joined(separator: "\n")
        lastText = c.title + "\n" + body
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let n = UNMutableNotificationContent()
            n.title = c.title
            n.body = body
            n.sound = .default
            center.add(UNNotificationRequest(identifier: "toolbox-morning", content: n, trigger: nil))
        }
        if alsoPhone { MorningReminder.post(title: c.title, notes: body) }
    }
}

/// Le check du matin aussi sur l'iPhone, sous forme de rappel (coché tout seul le lendemain).
enum MorningReminder {
    private static var lastID: String? {
        get { UserDefaults.standard.string(forKey: "morning.reminder.id") }
        set { UserDefaults.standard.set(newValue, forKey: "morning.reminder.id") }
    }

    static func post(title: String, notes: String) {
        guard BatteryReminder.hasAccess else { return }
        let store = BatteryReminder.store
        if let id = lastID, let old = store.calendarItem(withIdentifier: id) as? EKReminder, !old.isCompleted {
            old.isCompleted = true
            try? store.save(old, commit: true)
        }
        guard let list = store.defaultCalendarForNewReminders()
                ?? store.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) else { return }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = notes
        r.calendar = list
        let when = Date().addingTimeInterval(120)
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
        r.addAlarm(EKAlarm(absoluteDate: when))
        if (try? store.save(r, commit: true)) != nil { lastID = r.calendarItemIdentifier }
    }
}

// MARK: - Réveil programmé du Mac (pmset), pour que le check arrive à l'heure

enum WakeSchedule {
    /// Réveils répétés actuellement programmés (lu sans mot de passe).
    static func current() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "sched"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // « Repeating power events: wakepoweron at 7:25AM weekdays only »
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = lines.firstIndex(where: { $0.lowercased().hasPrefix("repeating power events") }) else { return nil }
        let events = lines[(i + 1)...].prefix { !$0.isEmpty && !$0.lowercased().hasPrefix("scheduled power events") }
            .filter { $0.lowercased().contains("wake") }
        return events.isEmpty ? nil : events.joined(separator: " · ")
    }

    /// Programme (ou annule) le réveil : macOS demande le mot de passe administrateur.
    static func apply(time: Date?, weekdaysOnly: Bool, completion: @escaping (String?) -> Void) {
        var command = "pmset repeat cancel"
        if let t = time {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            command = "pmset repeat wakeorpoweron \(weekdaysOnly ? "MTWRF" : "MTWRFSU") \(f.string(from: t))"
        }
        let script = "do shell script \"\(command)\" with administrator privileges with prompt \"Toolbox veut programmer le réveil du Mac pour le check du matin.\""
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            var message: String?
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    message = e.contains("-128") ? "Annulé" : e.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { completion(message) }
        }
    }
}

final class WakeState: ObservableObject {
    @Published var weekdaysOnly = UserDefaults.standard.object(forKey: "morning.wake.weekdays") as? Bool ?? true {
        didSet { UserDefaults.standard.set(weekdaysOnly, forKey: "morning.wake.weekdays") }
    }
    @Published var status: String? = WakeSchedule.current()
    @Published var message = ""
    @Published var busy = false

    func set(_ on: Bool, morning: Date) {
        busy = true
        let wakeAt = on ? morning.addingTimeInterval(-5 * 60) : nil
        WakeSchedule.apply(time: wakeAt, weekdaysOnly: weekdaysOnly) { [weak self] err in
            guard let self = self else { return }
            self.busy = false
            self.status = WakeSchedule.current()
            if let e = err { self.message = e } else {
                self.message = on ? "Réveil programmé 5 min avant le check ✓" : "Réveil programmé annulé."
            }
        }
    }
}

struct MorningSettings: View {
    @ObservedObject var m = MorningCheck.shared
    @StateObject private var wake = WakeState()

    var body: some View {
        Section("Check du matin") {
            Toggle("Un résumé de ma journée chaque matin", isOn: $m.enabled)
            if m.enabled {
                DatePicker("Heure", selection: $m.time, displayedComponents: .hourAndMinute)
                Toggle("Aussi sur l'iPhone (rappel dans l'app Rappels)", isOn: $m.alsoPhone)
                Text("Cours du jour (calendrier), shift, prochain CC et ce qu'il faut recharger. Si le Mac dort à l'heure dite, le résumé arrive à son réveil (jusqu'à 4 h après).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Réveil du Mac").font(.callout.weight(.semibold))
                    Text(wake.status.map { "Programmé : \($0)" } ?? "Aucun réveil programmé : capot fermé, le résumé attend que tu ouvres le Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Picker("", selection: $wake.weekdaysOnly) {
                            Text("Du lundi au vendredi").tag(true)
                            Text("Tous les jours").tag(false)
                        }
                        .labelsHidden().frame(width: 190)
                        Button(wake.status == nil ? "Réveiller le Mac à cette heure" : "Mettre à jour le réveil") { wake.set(true, morning: m.time) }
                        if wake.status != nil {
                            Button("Annuler le réveil") { wake.set(false, morning: m.time) }
                        }
                        if wake.busy { ProgressView().controlSize(.small) }
                    }
                    .disabled(wake.busy)
                    Text("Le Mac se réveille 5 min avant l'heure du check (réglage d'énergie de macOS, mot de passe demandé). Sur batterie et capot fermé, le réveil peut n'être que partiel. Si l'heure du check change, clique « Mettre à jour le réveil ». « Annuler » supprime tous les réveils répétés de macOS.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !wake.message.isEmpty { Text(wake.message).font(.caption) }
                }
                HStack {
                    Button("Voir le résumé maintenant") { m.send() }
                    Spacer()
                }
                if !m.lastText.isEmpty {
                    Text(m.lastText).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Données du widget iPhone « Ma journée »

enum DayExport {
    static let fileName = "ToolboxDay.json"
    private static var lastPayload: Data?
    private static var lastWrite = Date.distantPast

    /// Écrit ToolboxDay.json si quelque chose a changé (au plus souvent : chaque minute, au moins toutes les 30 min).
    static func export(force: Bool = false) {
        guard PhoneWidget.enabled else { return }
        let iso = ISO8601DateFormatter()
        let cal = Calendar.current
        var root: [String: Any] = ["firstName": UserProfile.firstName]
        // cours d'aujourd'hui et de demain (le widget bascule sur demain le soir)
        func lessons(_ day: Date) -> [[String: Any]] {
            Today.lessons(on: day).map { l in
                var d: [String: Any] = ["name": l.name, "title": l.title, "start": iso.string(from: l.start), "end": iso.string(from: l.end)]
                if let loc = l.location, !loc.isEmpty { d["location"] = loc }
                return d
            }
        }
        root["today"] = lessons(Date())
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) { root["tomorrow"] = lessons(tomorrow) }
        let r = RevisionsStore.shared
        if let p = r.next, let date = p.date {
            root["exam"] = ["title": p.title, "date": iso.string(from: date), "done": p.done, "total": p.tasks.count,
                            "urgent": p.urgent, "nextTask": p.tasks.first { !$0.done }?.title ?? ""] as [String: Any]
        }
        let payload = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard force || payload != lastPayload || Date().timeIntervalSince(lastWrite) > 1800 else { return }
        lastPayload = payload
        lastWrite = Date()
        root["updated"] = iso.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return }
        let dir = PhoneWidget.iCloudDriveDir
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        }
    }
}
