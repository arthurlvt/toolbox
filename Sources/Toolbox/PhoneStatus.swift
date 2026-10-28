import Foundation
import SwiftUI
import UserNotifications

/// Batterie de l'iPhone, envoyée par les widgets Scriptable (iCloud Drive/Toolbox/ToolboxPhone.json).
final class PhoneStatusStore: ObservableObject {
    static let shared = PhoneStatusStore()

    struct Info: Equatable {
        var name: String
        var model: String
        var battery: Int
        var charging: Bool
        var full: Bool
        var updated: Date
    }

    @Published var info: Info?

    static var alertEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "phone.alert") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "phone.alert") }
    }

    private var started = false
    private var timer: Timer?
    private var warned = false
    private var lastModified: Date?

    var file: URL { PhoneWidget.iCloudDriveDir.appendingPathComponent("ToolboxPhone.json") }

    func start() {
        guard !started else { return }
        started = true
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.read() }
    }

    func read() {
        let url = file
        DispatchQueue.global(qos: .utility).async {
            // fichier pas encore descendu d'iCloud : on demande le téléchargement
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let data = try? Data(contentsOf: url),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let updated = (d["updated"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? mod ?? Date()
            let i = Info(name: d["name"] as? String ?? "iPhone", model: d["model"] as? String ?? "iPhone",
                         battery: d["battery"] as? Int ?? Int((d["battery"] as? Double ?? 0).rounded()),
                         charging: d["charging"] as? Bool ?? false, full: d["full"] as? Bool ?? false, updated: updated)
            DispatchQueue.main.async {
                if i != self.info { self.info = i }
                self.lastModified = mod
                self.check(i)
            }
        }
    }

    private func check(_ i: Info) {
        if i.charging || i.battery > 30 { warned = false; return }
        let threshold = BatteryReminder.threshold
        // une info trop vieille (téléphone éteint, widget pas rafraîchi) ne déclenche pas d'alerte
        guard Self.alertEnabled, !warned, i.battery <= threshold, Date().timeIntervalSince(i.updated) < 45 * 60 else { return }
        warned = true
        ToastCenter.shared.show("📱 \(i.name) à \(i.battery) % : pense à le recharger", seconds: 6)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "📱 Recharge ton iPhone"
            c.body = "\(i.name) est à \(i.battery) %."
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "toolbox-iphone-battery", content: c, trigger: nil))
        }
    }

    var ageText: String {
        guard let i = info else { return "" }
        let m = Int(Date().timeIntervalSince(i.updated) / 60)
        if m < 2 { return "à l'instant" }
        if m < 60 { return "il y a \(m) min" }
        if m < 48 * 60 { return "il y a \(m / 60) h" }
        return "il y a \(m / 1440) j"
    }
}

/// Ligne « iPhone » dans le widget « Mes appareils ».
struct PhoneRow: View {
    @ObservedObject var s = PhoneStatusStore.shared

    var body: some View {
        if let i = s.info {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.title3).foregroundStyle(Color.cyan).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(i.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text((i.full ? "chargé · " : (i.charging ? "en charge · " : "")) + s.ageText)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                BatteryGauge(percent: i.battery, charging: i.charging).frame(width: 34, height: 16)
                Text("\(i.battery) %").font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(BatteryGauge.color(i.battery, plugged: i.charging))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .help("Envoyé par les widgets Scriptable de l'iPhone (mis à jour quand iOS les rafraîchit)")
        } else {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.title3).foregroundStyle(Color.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("iPhone").font(.callout.weight(.medium))
                    Text("En attente : recopie les scripts Scriptable mis à jour, puis lance « Mon Mac » une fois dans Scriptable")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { s.read() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Relire")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }
}

// MARK: - Réglages des widgets iPhone (dans « Personnaliser l'accueil »)

final class PhoneWidgetState: ObservableObject {
    @Published var enabled = PhoneWidget.enabled { didSet { PhoneWidget.enabled = enabled } }
    @Published var phoneAlert = PhoneStatusStore.alertEnabled { didSet { PhoneStatusStore.alertEnabled = phoneAlert } }
    @Published var message = ""
}

struct PhoneWidgetSettings: View {
    @StateObject private var st = PhoneWidgetState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Envoyer les infos vers l'iPhone (iCloud Drive/Toolbox)", isOn: $st.enabled)
                .onChange(of: st.enabled) { on in
                    if on { PhoneWidget.export(PlanningStore.shared, force: true); PhoneWidget.exportMac(MacStatusStore.shared, force: true) }
                }
            if st.enabled {
                Text("Sur l'iPhone, une seule fois :\n1. Installe Scriptable (gratuite), iCloud activé.\n2. Scriptable → Settings → File Bookmarks → + → Pick Folder → iCloud Drive → Toolbox, nommé « Toolbox ».\n3. Ajoute les scripts (une seule fois : ce sont des lanceurs, les mises à jour arrivent ensuite toutes seules) : Fichiers → iCloud Drive → Toolbox → « Script Ma journée.txt », « Script Mon Mac.txt », « Script Prochain shift.txt », tout sélectionner, copier, puis + dans Scriptable et coller.\n4. Écran d'accueil : appui long → + → Scriptable → choisis le script.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if PhoneWidget.hasScriptable {
                        Button("Installer dans Scriptable") {
                            do {
                                try PhoneWidget.installScript()
                                st.message = "Scripts déposés dans Scriptable (si ce dossier synchronise mal, passe par Fichiers)."
                            } catch {
                                st.message = error.localizedDescription
                            }
                        }
                    }
                    Button("Copier « Prochain shift »") {
                        PhoneWidget.copyScript()
                        PhoneWidget.export(PlanningStore.shared, force: true)
                        st.message = "Copié : dans Scriptable, + → Coller → nomme-le « Prochain shift »."
                    }
                    Button("Copier « Mon Mac »") {
                        PhoneWidget.copyScript(mac: true)
                        PhoneWidget.exportMac(MacStatusStore.shared, force: true)
                        st.message = "Copié : dans Scriptable, + → Coller → nomme-le « Mon Mac »."
                    }
                    Button("Copier « Ma journée »") {
                        PhoneWidget.copyScript(day: true)
                        DayExport.export(force: true)
                        st.message = "Copié : dans Scriptable, + → Coller → nomme-le « Ma journée » (widget grand ou moyen)."
                    }
                }
                Toggle("Notification sur le Mac quand l'iPhone passe sous \(BatteryReminder.threshold) %", isOn: $st.phoneAlert)
                Text("La batterie de l'iPhone arrive à chaque rafraîchissement d'un widget Scriptable (souvent toutes les 5 à 15 min). Pour une alerte immédiate : app Raccourcis → Automatisation → Niveau de batterie → descend sous 20 % → Exécuter le script « Mon Mac » (sans « Exécuter dans l'app »).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let d = PhoneWidget.lastExport {
                    Text("Dernier envoi : \(PlanningToolView.time.string(from: d))").font(.caption).foregroundStyle(.secondary)
                }
                if !st.message.isEmpty {
                    Text(st.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
