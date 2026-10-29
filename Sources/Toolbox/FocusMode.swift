import Foundation
import SwiftUI
import AppKit
import Combine
import IOBluetooth

/// « Mode cours » : un mode de concentration (partagé avec l'iPhone par iCloud) + une action sur le casque.
/// La concentration se pilote via l'app Raccourcis (`shortcuts run`) : macOS ne l'expose pas autrement.
final class ClassMode: ObservableObject {
    static let shared = ClassMode()

    enum HeadphoneAction: String, CaseIterable, Identifiable {
        case none, disconnect, transparency, ancOff
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Ne rien faire"
            case .disconnect: return "Le déconnecter du Mac"
            case .transparency: return "Passer en transparence"
            case .ancOff: return "Couper la réduction de bruit"
            }
        }
    }

    @Published private(set) var active = UserDefaults.standard.bool(forKey: "classmode.active")
    @Published var onShortcut = UserDefaults.standard.string(forKey: "classmode.on") ?? "Toolbox Concentration On" {
        didSet { UserDefaults.standard.set(onShortcut, forKey: "classmode.on") }
    }
    @Published var offShortcut = UserDefaults.standard.string(forKey: "classmode.off") ?? "Toolbox Concentration Off" {
        didSet { UserDefaults.standard.set(offShortcut, forKey: "classmode.off") }
    }
    @Published var headphoneAction = HeadphoneAction(rawValue: UserDefaults.standard.string(forKey: "classmode.hp") ?? "") ?? .disconnect {
        didSet { UserDefaults.standard.set(headphoneAction.rawValue, forKey: "classmode.hp") }
    }
    @Published var reconnect = UserDefaults.standard.object(forKey: "classmode.reconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reconnect, forKey: "classmode.reconnect") }
    }
    @Published var auto = UserDefaults.standard.object(forKey: "classmode.auto") as? Bool ?? false {
        didSet { UserDefaults.standard.set(auto, forKey: "classmode.auto") }
    }
    @Published var shortcuts: [String] = []
    @Published var message = ""

    private var started = false
    private var bag: Set<AnyCancellable> = []
    private var autoStarted = false          // activé par le calendrier (et pas à la main)
    private var disconnectedAddress: String?

    func start() {
        guard !started else { return }
        started = true
        loadShortcuts()
        CoursesStore.shared.$now
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inClass in self?.classChanged(inClass) }
            .store(in: &bag)
    }

    var missingShortcuts: [String] {
        [onShortcut, offShortcut].filter { name in !shortcuts.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    func loadShortcuts() {
        DispatchQueue.global(qos: .utility).async {
            let list = Self.runShortcuts(["list"]).output.components(separatedBy: .newlines).filter { !$0.isEmpty }
            DispatchQueue.main.async { self.shortcuts = list }
        }
    }

    private func classChanged(_ inClass: Bool) {
        guard auto else { return }
        if inClass, !active {
            autoStarted = true
            set(true, reason: "début du cours")
        } else if !inClass, active, autoStarted {
            autoStarted = false
            set(false, reason: "fin du cours")
        }
    }

    func toggle() { autoStarted = false; set(!active, reason: nil) }

    func set(_ on: Bool, reason: String?) {
        active = on
        UserDefaults.standard.set(on, forKey: "classmode.active")
        // 1. concentration (Mac + iPhone)
        let name = on ? onShortcut : offShortcut
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.runShortcuts(["run", name])
            DispatchQueue.main.async {
                if r.status != 0 {
                    self.message = "Raccourci « \(name) » introuvable ou en erreur : crée-le dans l'app Raccourcis (voir la page Casque)."
                    ToastCenter.shared.show(self.message, seconds: 6)
                } else {
                    self.message = ""
                }
            }
        }
        // 2. casque
        let hp = HeadphoneStore.shared
        if on {
            switch headphoneAction {
            case .none: break
            case .transparency: hp.setANC(HeadphoneStore.ancTransparency)
            case .ancOff: hp.setANC(HeadphoneStore.ancOff)
            case .disconnect:
                if let dev = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
                    .first(where: { HeadphoneStore.isNothing($0) && $0.isConnected() }) {
                    disconnectedAddress = dev.addressString
                    _ = dev.closeConnection()
                }
            }
        } else if headphoneAction == .disconnect, reconnect, let addr = disconnectedAddress,
                  let dev = IOBluetoothDevice(addressString: addr) {
            disconnectedAddress = nil
            _ = dev.openConnection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { HeadphoneStore.shared.refresh() }
        }
        let what = on ? "📵 Mode cours activé" : "🔔 Mode cours désactivé"
        ToastCenter.shared.show(what + (reason.map { " (\($0))" } ?? ""))
    }

    static func runShortcuts(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Réglages (dans la page « Casque »)

struct ClassModeSettings: View {
    @ObservedObject var c = ClassMode.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mode cours").font(.headline)
                    Text("iPhone en silence + casque").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { c.toggle() } label: {
                    Label(c.active ? "Désactiver" : "Activer", systemImage: c.active ? "bell.fill" : "bell.slash.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(c.active ? .red : .accentColor)
            }
            Picker("Casque", selection: $c.headphoneAction) {
                ForEach(ClassMode.HeadphoneAction.allCases) { Text($0.title).tag($0) }
            }
            if c.headphoneAction == .disconnect {
                Toggle("Le reconnecter à la fin", isOn: $c.reconnect)
            }
            Toggle("Automatique au début et à la fin de chaque cours (calendrier)", isOn: $c.auto)

            DisclosureGroup("Concentration (une seule fois, dans l'app Raccourcis)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Crée deux raccourcis dans l'app Raccourcis du Mac :\n1. « \(c.onShortcut) » : action « Définir la concentration » → Activer « Ne pas déranger » (ou un mode « Cours »), jusqu'à désactivation.\n2. « \(c.offShortcut) » : action « Définir la concentration » → Désactiver.\nPour que l'iPhone suive : Réglages Système → Concentration → « Partager entre les appareils ».")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Raccourci pour activer", text: $c.onShortcut).textFieldStyle(.roundedBorder)
                        TextField("Raccourci pour désactiver", text: $c.offShortcut).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Button("Ouvrir Raccourcis") {
                            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                                NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                            }
                        }
                        Button("Vérifier") { c.loadShortcuts() }
                        let missing = c.missingShortcuts
                        Text(missing.isEmpty ? "Raccourcis trouvés ✓" : "Manquant : " + missing.joined(separator: ", "))
                            .font(.caption).foregroundStyle(missing.isEmpty ? Color.green : Color.orange)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
            if !c.message.isEmpty { Text(c.message).font(.caption).foregroundStyle(Color.orange) }
        }
    }
}
