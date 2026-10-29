import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers

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
            ProfileSettings()
            MacAlertSettings()
            NightlySettings()
            MorningSettings()
            OllamaSettings()
        }
        .formStyle(.grouped)
    }
}

final class NightlyState: ObservableObject {
    @Published var enabled = NightlyReminder.enabled
    @Published var time = Calendar.current.date(bySettingHour: NightlyReminder.hour, minute: NightlyReminder.minute, second: 0, of: Date()) ?? Date()
    @Published var text = NightlyReminder.text
    @Published var message = ""

    func save() {
        NightlyReminder.enabled = enabled
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        NightlyReminder.hour = c.hour ?? 22
        NightlyReminder.minute = c.minute ?? 0
        NightlyReminder.text = text.trimmingCharacters(in: .whitespaces).isEmpty ? "Recharger le MacBook et le casque" : text
        let run: () -> Void = {
            if let e = NightlyReminder.apply() { self.message = "Échec : \(e)" }
            else { self.message = self.enabled ? "Rappel quotidien enregistré ✓ (chaque soir à \(String(format: "%02d:%02d", NightlyReminder.hour, NightlyReminder.minute)))" : "Rappel quotidien supprimé." }
        }
        if BatteryReminder.hasAccess { run() } else {
            BatteryReminder.requestAccess { ok in if ok { run() } else { self.message = "Autorise Toolbox dans Réglages Système → Confidentialité et sécurité → Rappels." } }
        }
    }
}

struct NightlySettings: View {
    @StateObject private var st = NightlyState()

    var body: some View {
        Section("Rappel du soir") {
            Toggle("Me rappeler chaque soir de tout recharger", isOn: $st.enabled)
            if st.enabled {
                DatePicker("Heure", selection: $st.time, displayedComponents: .hourAndMinute)
                TextField("Texte", text: $st.text)
            }
            HStack {
                Button("Enregistrer") { st.save() }
                if !st.message.isEmpty { Text(st.message).font(.caption) }
            }
            Text("Un rappel récurrent dans l'app Rappels : il sonne sur l'iPhone chaque soir, même si le Mac est éteint.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
                        let send: () -> Void = {
                            if let err = BatteryReminder.post(m.battery?.percent ?? 18, minutesLeft: m.battery?.minutesLeft, retry: false) {
                                st.message = "Échec : \(err)"
                            } else {
                                st.message = "Rappel « 🔋 Recharge ton Mac » créé : il sonne sur l'iPhone dans 2 minutes."
                            }
                        }
                        if BatteryReminder.hasAccess {
                            send()
                        } else {
                            BatteryReminder.requestAccess { ok in
                                if ok { send() } else { st.message = "Autorise Toolbox dans Réglages Système → Confidentialité et sécurité → Rappels." }
                            }
                        }
                    }
                    if !st.message.isEmpty { Text(st.message).font(.caption) }
                }
            }
        }
    }
}
