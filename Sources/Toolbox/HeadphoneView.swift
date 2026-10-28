import SwiftUI
import AppKit
import Combine

// MARK: - Mode automatique du casque

/// Change la réduction de bruit selon le contexte : transparence pendant un cours (d'après le calendrier,
/// comme « Cours en ce moment » de Mes cours), mode habituel le reste du temps, faible latence dans les jeux.
final class HeadphoneAuto: ObservableObject {
    static let shared = HeadphoneAuto()

    /// 0 = ne rien changer
    @Published var enabled = UserDefaults.standard.object(forKey: "hp.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "hp.auto"); if enabled { evaluate(force: true) } }
    }
    @Published var classMode = UserDefaults.standard.object(forKey: "hp.auto.class") as? Int ?? Int(HeadphoneStore.ancTransparency) {
        didSet { UserDefaults.standard.set(classMode, forKey: "hp.auto.class"); evaluate(force: true) }
    }
    @Published var otherMode = UserDefaults.standard.object(forKey: "hp.auto.other") as? Int ?? 0x04 {
        didSet { UserDefaults.standard.set(otherMode, forKey: "hp.auto.other"); evaluate(force: true) }
    }
    @Published var gameLatency = UserDefaults.standard.object(forKey: "hp.auto.games") as? Bool ?? true {
        didSet { UserDefaults.standard.set(gameLatency, forKey: "hp.auto.games") }
    }
    @Published private(set) var lastAction: String?

    private var inClass: Bool?
    private var inGame = false
    private var bag: Set<AnyCancellable> = []
    private var started = false

    static let modes: [(Int, String)] = [(0, "Ne rien changer"), (Int(HeadphoneStore.ancTransparency), "Transparence"),
                                         (0x04, "Réduction adaptative"), (0x01, "Réduction forte"), (0x02, "Réduction moyenne"),
                                         (0x03, "Réduction faible"), (Int(HeadphoneStore.ancOff), "Désactivée")]

    func start() {
        guard !started else { return }
        started = true
        CoursesStore.shared.$now
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &bag)
        // casque qui (re)vient : on applique le mode du moment
        HeadphoneStore.shared.$connected
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.evaluate(force: true) } }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.appActivated(app)
            }
            .store(in: &bag)
    }

    func evaluate(force: Bool = false) {
        let hp = HeadphoneStore.shared
        guard enabled, hp.connected else { return }
        let now = CoursesStore.shared.now != nil
        guard force || now != inClass else { return }
        inClass = now
        let mode = now ? classMode : otherMode
        guard mode != 0, hp.anc.map({ Int($0) }) != mode else { return }
        hp.setANC(UInt8(mode))
        let name = Self.modes.first { $0.0 == mode }?.1.lowercased() ?? ""
        let why = now ? "cours en cours" : "fin du cours"
        lastAction = "\(name) (\(why))"
        if !force { ToastCenter.shared.show("🎧 \(name.prefix(1).uppercased() + String(name.dropFirst())) : \(why)") }
    }

    private func appActivated(_ app: NSRunningApplication?) {
        let hp = HeadphoneStore.shared
        guard enabled, gameLatency, hp.connected else { return }
        let game = Self.isGame(app)
        if game && !inGame {
            inGame = true
            if hp.lowLatency != true { hp.setLowLatency(true); lastAction = "faible latence (\(app?.localizedName ?? "jeu"))" }
        } else if !game && inGame {
            inGame = false
            if hp.lowLatency == true { hp.setLowLatency(false); lastAction = "faible latence coupée" }
        }
    }

    /// Une app de la catégorie « Jeux » (Info.plist) ou un lanceur connu.
    static func isGame(_ app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        let known = ["com.valvesoftware.steam", "com.mojang.minecraftlauncher", "com.riotgames", "com.epicgames", "com.blizzard",
                     "net.battle", "com.heroicgameslauncher", "com.apple.gamecenter"]
        if let id = app.bundleIdentifier?.lowercased(), known.contains(where: { id.hasPrefix($0) }) { return true }
        if let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary,
           let cat = info["LSApplicationCategoryType"] as? String {
            return cat.contains("games")
        }
        return false
    }
}

// MARK: - Page « Casque »

struct HeadphoneToolView: View {
    @ObservedObject var h = HeadphoneStore.shared
    @ObservedObject var auto = HeadphoneAuto.shared
    @ObservedObject var courses = CoursesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .headphone)
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        if h.connected || h.last != nil {
                            card { HeadphonePanel() }
                            if let r = h.last { card { details(r) } }
                        }
                        if !h.connected { notFound }
                    }
                    .frame(minWidth: 360, maxWidth: 460)
                    VStack(alignment: .leading, spacing: 14) {
                        card { autoSettings }
                    }
                    .frame(minWidth: 320, maxWidth: 440)
                }
                .padding(.bottom, 20)
            }
        }
        .padding(20)
        .onAppear { if h.connected || h.last == nil { h.refresh() } }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
    }

    private var notFound: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Aucun casque Nothing connecté au Mac", systemImage: "headphones").font(.headline)
                Text("1. Connecte le casque au Mac (menu Bluetooth ou menu Son).\n2. Ferme l'app Nothing X sur le téléphone (le canal ne sert qu'à une app à la fois).\n3. Vérifie que Toolbox a le droit d'utiliser le Bluetooth : Réglages Système → Confidentialité et sécurité → Bluetooth.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { h.refresh() } label: { Label("Rechercher le casque", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).disabled(h.reading)
                    if h.reading { ProgressView().controlSize(.small) }
                    Button("Réglages Bluetooth") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(u) }
                    }
                }
                if let e = h.error { Text(e).font(.caption).foregroundStyle(Color.orange) }
            }
        }
    }

    private func details(_ r: HeadphoneStore.Reading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batterie").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                if let l = r.left, let rr = r.right {
                    part("Gauche", l); part("Droite", rr)
                    if let b = r.box { part("Boîtier", b) }
                } else {
                    part(r.charging ? "En charge" : "Casque", r.percent)
                }
                Spacer()
            }
            Text("Dernière lecture : \(PlanningToolView.time.string(from: r.date))" + (h.ageText.map { " (\($0))" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func part(_ title: String, _ p: Int) -> some View {
        VStack(spacing: 4) {
            BatteryGauge(percent: p, charging: false).frame(width: 46, height: 22)
            Text("\(p) %").font(.callout.weight(.bold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var autoSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $auto.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mode automatique").font(.headline)
                    Text("Le casque s'adapte à ta journée").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Group {
                Picker("Pendant un cours", selection: $auto.classMode) {
                    ForEach(HeadphoneAuto.modes, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Le reste du temps", selection: $auto.otherMode) {
                    ForEach(HeadphoneAuto.modes, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Faible latence quand un jeu est au premier plan", isOn: $auto.gameLatency)
                Text("Un cours est repéré comme dans « Mes cours » : un événement du calendrier dont le titre contient le nom (ou un alias) d'une matière.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: courses.now == nil ? "moon.zzz" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(courses.now == nil ? Color.secondary : Color.red)
                    Text(courses.now.map { "En ce moment : \(courses.name($0.course))" } ?? "Pas de cours en ce moment")
                        .font(.callout)
                }
                if let a = auto.lastAction {
                    Text("Dernier changement : \(a)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!auto.enabled)
        }
    }
}
