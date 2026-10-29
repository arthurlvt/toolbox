import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers

/// Une app à lancer d'un clic : retrouvée par son identifiant (même si elle change de dossier).
struct AppShortcut: Codable, Identifiable, Hashable {
    var id: String { bundleID ?? path }
    var bundleID: String?
    var path: String
    var name: String

    var url: URL? {
        if let b = bundleID, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return u }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

final class AppShortcutsStore: ObservableObject {
    static let shared = AppShortcutsStore()

    @Published var apps: [AppShortcut] = [] { didSet { save(); registerHotKeys() } }
    @Published var running: Set<String> = []
    @Published var hotKeysOn = UserDefaults.standard.object(forKey: "apps.hotkeys") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hotKeysOn, forKey: "apps.hotkeys"); registerHotKeys() }
    }
    private var observers: [NSObjectProtocol] = []
    private var started = false

    /// Proposées au premier lancement, si elles sont installées.
    static let suggested: [(String, String)] = [
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("com.hnc.Discord", "Discord"),
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: "apps.list"),
           let list = try? JSONDecoder().decode([AppShortcut].self, from: data) {
            apps = list
        } else {
            apps = Self.suggested.compactMap { id, name in
                guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
                return AppShortcut(bundleID: id, path: u.path, name: name)
            }
        }
    }

    /// Point vert des apps ouvertes, raccourcis ⌃⌥1…9 : démarré au lancement de Toolbox.
    func start() {
        guard !started else { return }
        started = true
        refreshRunning()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshRunning() })
        }
        registerHotKeys()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: "apps.list") }
    }

    func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    func isRunning(_ a: AppShortcut) -> Bool {
        if let b = a.bundleID { return running.contains(b) }
        return false
    }

    func icon(_ a: AppShortcut) -> NSImage {
        if let u = a.url { return NSWorkspace.shared.icon(forFile: u.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    /// Lance l'app, ou la ramène au premier plan si elle tourne déjà.
    func launch(_ a: AppShortcut) {
        guard let u = a.url else {
            ToastCenter.shared.show("\(a.name) est introuvable (désinstallée ?).")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: u, configuration: config, completionHandler: nil)
    }

    func add(_ url: URL) {
        guard url.pathExtension == "app" else { return }
        let bundle = Bundle(url: url)
        let id = bundle?.bundleIdentifier
        guard !apps.contains(where: { ($0.bundleID != nil && $0.bundleID == id) || $0.path == url.path }) else {
            ToastCenter.shared.show("Déjà dans tes raccourcis.")
            return
        }
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            apps.append(AppShortcut(bundleID: id, path: url.path, name: name))
        }
    }

    func pickAndAdd() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = "Ajouter"
        if p.runModal() == .OK { p.urls.forEach(add) }
    }

    func remove(_ a: AppShortcut) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { apps.removeAll { $0.id == a.id } }
    }

    func move(_ a: AppShortcut, by delta: Int) {
        guard let i = apps.firstIndex(of: a) else { return }
        let j = max(0, min(apps.count - 1, i + delta))
        guard i != j else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { apps.swapAt(i, j) }
    }

    func rename(_ a: AppShortcut, to name: String) {
        guard let i = apps.firstIndex(of: a), !name.isEmpty else { return }
        apps[i].name = name
    }

    // MARK: Raccourcis globaux ⌃⌥1 … ⌃⌥9

    static let digitKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                   kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    func registerHotKeys() {
        guard started else { return }
        for i in 0..<9 { GlobalHotKey.shared.unregister(id: UInt32(100 + i)) }
        guard hotKeysOn else { return }
        for (i, a) in apps.prefix(9).enumerated() {
            GlobalHotKey.shared.register(id: UInt32(100 + i), keyCode: UInt32(Self.digitKeys[i]),
                                         modifiers: UInt32(controlKey | optionKey)) { [weak self] in self?.launch(a) }
        }
    }

    static func shortcutLabel(_ index: Int) -> String? { index < 9 ? "⌃⌥\(index + 1)" : nil }
}

// MARK: - Widget « Mes apps »

struct AppsWidget: View {
    @ObservedObject var store = AppShortcutsStore.shared
    @StateObject private var drop = HoverFlag()

    var body: some View {
        Card(title: "Mes apps", icon: "square.grid.3x3.fill", tint: .purple,
             accessory: AnyView(HStack(spacing: 8) {
                 Toggle("⌃⌥1…9", isOn: $store.hotKeysOn)
                     .toggleStyle(.switch).controlSize(.mini)
                     .help("Raccourcis clavier globaux : ⌃⌥1 lance la 1re app, ⌃⌥2 la 2e…")
                 Button { store.pickAndAdd() } label: { Image(systemName: "plus.circle") }
                     .buttonStyle(.borderless).help("Ajouter une app")
             })) {
            if store.apps.isEmpty {
                Text("Ajoute tes apps avec + (ou glisse-les ici depuis le Finder) pour les lancer d'un clic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 10)], spacing: 10) {
                ForEach(Array(store.apps.enumerated()), id: \.element.id) { i, app in
                    AppTile(app: app, index: i, store: store)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.purple.opacity(drop.on ? 0.8 : 0), lineWidth: 2))
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { drop.on }, set: { drop.on = $0 })) { providers in
            FileDrop.load(providers) { urls in urls.filter { $0.pathExtension == "app" }.forEach(store.add) }
            return true
        }
    }
}

struct AppTile: View {
    let app: AppShortcut
    let index: Int
    @ObservedObject var store: AppShortcutsStore
    @StateObject private var hover = HoverFlag()
    @StateObject private var pressed = HoverFlag()

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pressed.on = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { pressed.on = false }
            }
            store.launch(app)
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: store.icon(app))
                        .resizable()
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(hover.on ? 0.25 : 0.12), radius: hover.on ? 8 : 3, y: hover.on ? 5 : 2)
                    if store.isRunning(app) {
                        // petit témoin discret « déjà ouverte », dans le coin haut gauche
                        Circle().fill(Color.green)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                            .help("Déjà ouverte")
                    }
                }
                Text(app.name).font(.caption).lineLimit(1)
                if let k = AppShortcutsStore.shortcutLabel(index), store.hotKeysOn {
                    Text(k).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 82)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hover.on ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed.on ? 0.86 : (hover.on ? 1.08 : 1))
        .offset(y: hover.on ? -3 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover.on)
        .onHover { hover.on = $0 }
        .help("Ouvrir \(app.name)" + (AppShortcutsStore.shortcutLabel(index).map { " (\($0))" } ?? ""))
        .contextMenu {
            Button("Ouvrir") { store.launch(app) }
            Button("Déplacer à gauche") { store.move(app, by: -1) }.disabled(index == 0)
            Button("Déplacer à droite") { store.move(app, by: 1) }.disabled(index == store.apps.count - 1)
            if let u = app.url {
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
            Divider()
            Button("Retirer des raccourcis") { store.remove(app) }
        }
    }
}

/// Rangée compacte d'icônes (barre des menus).
struct AppStrip: View {
    @ObservedObject var store = AppShortcutsStore.shared

    var body: some View {
        if !store.apps.isEmpty {
            HStack(spacing: 6) {
                ForEach(store.apps.prefix(8)) { app in
                    Button { store.launch(app) } label: {
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: store.icon(app)).resizable().frame(width: 30, height: 30)
                            if store.isRunning(app) {
                                Circle().fill(Color.green).frame(width: 5, height: 5)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                    .offset(x: 1, y: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(app.name)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
