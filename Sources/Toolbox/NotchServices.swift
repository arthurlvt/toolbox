import SwiftUI
import AppKit
import UserNotifications
import PDFCore

// MARK: - Musique en cours (Spotify, Musique)
//
// Depuis macOS 15.4, l'accès général au « À l'écoute » est réservé à Apple : on interroge Spotify et Musique
// par AppleScript (osascript, hors du fil principal), seulement s'ils sont déjà ouverts (jamais lancés par Toolbox).
// La première fois, macOS demande l'autorisation de piloter l'app.

struct NowPlaying: Equatable {
    var app: String            // "Spotify" ou "Music"
    var title: String
    var artist: String
    var album: String
    var playing: Bool
    var position: Double
    var duration: Double
    var artworkURL: String
    var artwork: NSImage?
    var fetched = Date()

    /// Position estimée maintenant (entre deux relevés).
    var livePosition: Double {
        guard playing else { return position }
        return min(duration, position + Date().timeIntervalSince(fetched))
    }

    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.app == b.app && a.title == b.title && a.artist == b.artist && a.playing == b.playing
            && Int(a.position) == Int(b.position) && a.artwork === b.artwork
    }
}

final class MediaStore: ObservableObject {
    static let shared = MediaStore()

    @Published private(set) var now: NowPlaying?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "toolbox.media", qos: .utility)
    private var busy = false
    private var artworkFor = ""            // morceau dont la pochette est chargée
    private var artwork: NSImage?

    static let apps = [("Spotify", "com.spotify.client"), ("Music", "com.apple.Music")]

    private var runningApps: [String] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return Self.apps.filter { ids.contains($0.1) }.map { $0.0 }
    }

    /// Relevés : toutes les 2 s quand l'île est ouverte, toutes les 5 s sinon ; rien si aucun lecteur n'est ouvert.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard NotchSettings.shared.music, NotchController.shared.isRunning else {
            if now != nil { now = nil }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let open = NotchModel.shared.mode == .expanded
            if open || Int(Date().timeIntervalSince1970) % 5 < 2 { self.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard NotchSettings.shared.music, !busy else { return }
        let apps = runningApps
        guard !apps.isEmpty else {
            if now != nil { DispatchQueue.main.async { self.now = nil } }
            return
        }
        busy = true
        queue.async { [weak self] in
            guard let self = self else { return }
            var found: NowPlaying?
            // celui qui joue d'abord, sinon le premier en pause
            for app in apps {
                if let n = Self.query(app) {
                    if n.playing { found = n; break }
                    if found == nil { found = n }
                }
            }
            if var f = found {
                let key = f.app + f.title + f.artist
                if key != self.artworkFor {
                    self.artworkFor = key
                    self.artwork = Self.loadArtwork(f)
                }
                f.artwork = self.artwork
                found = f
            }
            DispatchQueue.main.async {
                self.busy = false
                if self.now != found { self.now = found }
            }
        }
    }

    private static let sep = "‖"

    private static func query(_ app: String) -> NowPlaying? {
        let artwork = app == "Spotify" ? "(artwork url of t)" : "\"\""
        let duration = app == "Spotify" ? "((duration of t) / 1000)" : "(duration of t)"
        let script = """
        tell application "\(app)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & \(artwork) & "\(sep)" & (player position as string) & "\(sep)" & (\(duration) as string)
        end tell
        """
        guard let out = try? Shell.run("/usr/bin/osascript", ["-e", script]), out.status == 0 else { return nil }
        let parts = out.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: sep)
        guard parts.count >= 7 else { return nil }
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0 }
        return NowPlaying(app: app, title: parts[1], artist: parts[2], album: parts[3], playing: parts[0] == "playing",
                          position: num(parts[5]), duration: num(parts[6]), artworkURL: parts[4], artwork: nil)
    }

    private static func loadArtwork(_ n: NowPlaying) -> NSImage? {
        if n.app == "Spotify" {
            guard let u = URL(string: n.artworkURL), let d = try? Data(contentsOf: u) else { return nil }
            return NSImage(data: d)
        }
        // Musique : la pochette est écrite dans un fichier temporaire
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-artwork.dat")
        try? FileManager.default.removeItem(at: file)
        let script = """
        tell application "Music"
            try
                set d to raw data of artwork 1 of current track
            on error
                return "none"
            end try
        end tell
        set f to open for access (POSIX file "\(file.path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """
        guard let out = try? Shell.run("/usr/bin/osascript", ["-e", script]), out.text.contains("ok") else { return nil }
        return NSImage(contentsOf: file)
    }

    enum Command { case playPause, next, previous }

    func send(_ c: Command) {
        guard let app = now?.app else { return }
        let verb: String
        switch c {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        // effet immédiat à l'écran, puis relevé
        if c == .playPause, var n = now {
            n.playing.toggle()
            n.position = n.livePosition
            n.fetched = Date()
            now = n
        }
        queue.async {
            _ = try? Shell.run("/usr/bin/osascript", ["-e", "tell application \"\(app)\" to \(verb)"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
        }
    }

    func openPlayer() {
        guard let app = now?.app, let id = Self.apps.first(where: { $0.0 == app })?.1,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Minuteur (révisions, pause, lessive…)

final class NotchTimer: ObservableObject {
    static let shared = NotchTimer()

    @Published private(set) var end: Date?
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var label = ""
    @Published private(set) var pausedRemaining: TimeInterval?
    private var ticker: Timer?

    static let presets: [(Int, String)] = [(5, "Pause"), (15, "Exercice"), (25, "Pomodoro"), (50, "Révision longue")]

    var running: Bool { end != nil || pausedRemaining != nil }
    var remaining: TimeInterval? {
        if let p = pausedRemaining { return p }
        return end.map { max(0, $0.timeIntervalSinceNow) }
    }
    var progress: Double {
        guard total > 0, let r = remaining else { return 0 }
        return 1 - r / total
    }

    func start(minutes: Int, label: String) {
        total = TimeInterval(minutes * 60)
        end = Date().addingTimeInterval(total)
        pausedRemaining = nil
        self.label = label
        startTicker()
    }

    func togglePause() {
        if let p = pausedRemaining {
            end = Date().addingTimeInterval(p)
            pausedRemaining = nil
            startTicker()
        } else if let r = remaining {
            pausedRemaining = r
            end = nil
            ticker?.invalidate()
            objectWillChange.send()
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        end = nil
        pausedRemaining = nil
        total = 0
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.objectWillChange.send()
            if let e = self.end, e <= Date() { self.finish() }
        }
    }

    private func finish() {
        let what = label
        stop()
        NSSound(named: "Glass")?.play()
        NotchController.shared.alert(NotchAlert(icon: "timer", color: .orange, title: L("Minuteur terminé"),
                                                subtitle: L(what)), seconds: 8)
        let c = UNMutableNotificationContent()
        c.title = L("Minuteur terminé")
        c.body = L(what)
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "toolbox.timer", content: c, trigger: nil))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Étagère (fichiers posés sur l'encoche)

final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [URL] = [] { didSet { save() } }

    init() {
        items = (UserDefaults.standard.stringArray(forKey: "notch.shelf") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() { UserDefaults.standard.set(items.map { $0.path }, forKey: "notch.shelf") }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
        if !urls.isEmpty {
            NotchModel.shared.tab = "shelf"
            if NotchSettings.shared.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }

    func remove(_ u: URL) { items.removeAll { $0 == u } }
    func clear() { items = [] }

    var pdfs: [URL] { items.filter { $0.pathExtension.lowercased() == "pdf" } }

    // actions
    func open(in tool: Tool, _ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NotchController.shared.close()
        AppRouter.shared.openIn = OpenRequest(tool: tool, urls: urls)
        AppRouter.showMainWindow()
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let s = NSSharingService(named: .sendViaAirDrop) else { return }
        NotchController.shared.close()
        s.perform(withItems: urls)
    }

    func copy(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        ToastCenter.shared.show(String(format: L("%lld fichier(s) copié(s)"), urls.count))
    }

    func reveal(_ urls: [URL]) {
        NotchController.shared.close()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func icon(_ u: URL) -> NSImage { NSWorkspace.shared.icon(forFile: u.path) }
}

// MARK: - Ouvrir des fichiers dans un outil de Toolbox

struct OpenRequest: Equatable {
    var tool: Tool
    var urls: [URL]
    var id = UUID()
}

extension AppRouter {
    /// Montre la fenêtre principale (et la rouvre si elle a été fermée).
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.identifier?.rawValue.contains("main") == true }) {
            w.makeKeyAndOrderFront(nil)
            return
        }
        // fenêtre fermée : « rouvrir » l'app la recrée
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
