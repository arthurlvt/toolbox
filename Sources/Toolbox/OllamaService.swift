import SwiftUI
import AppKit
import PDFCore

// MARK: - Démarrage automatique d'Ollama

/// Vérifie qu'Ollama répond ; sinon ouvre l'app Ollama (si installée) ou lance `ollama serve` en arrière-plan.
/// Lancer le serveur ne charge aucun modèle : la mémoire n'est prise qu'au moment d'une demande.
final class OllamaService: ObservableObject {
    static let shared = OllamaService()

    enum State: Equatable {
        case unknown, checking, starting, running(models: Int), notInstalled, failed(String)

        var label: String {
            switch self {
            case .unknown: return "Pas encore vérifié"
            case .checking: return "Vérification…"
            case .starting: return "Démarrage d'Ollama…"
            case .running(let n): return n == 0 ? "En marche, mais aucun modèle installé" : "En marche · \(n) modèle\(n > 1 ? "s" : "")"
            case .notInstalled: return "Ollama n'est pas installé"
            case .failed(let e): return e
            }
        }
        var ok: Bool { if case .running = self { return true } else { return false } }
    }

    @Published private(set) var state: State = .unknown
    @Published var autoStart = UserDefaults.standard.object(forKey: "ollama.autostart") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoStart, forKey: "ollama.autostart"); if autoStart { ensureRunning() } }
    }
    @Published var stopOnQuit = UserDefaults.standard.object(forKey: "ollama.stoponquit") as? Bool ?? true {
        didSet { UserDefaults.standard.set(stopOnQuit, forKey: "ollama.stoponquit") }
    }
    /// ce que Toolbox a lancé lui-même (on ne coupe jamais un Ollama lancé par quelqu'un d'autre)
    @Published private(set) var startedBy: String?

    private var process: Process?
    private var waiters: [(Bool) -> Void] = []
    private var busy = false

    var host: String {
        let h = UserDefaults.standard.string(forKey: "annales.host") ?? ""
        return h.isEmpty ? OllamaClient.defaultHost : h
    }
    var client: OllamaClient { OllamaClient(host: host) }
    var isLocal: Bool { host.contains("127.0.0.1") || host.contains("localhost") || host.contains("[::1]") }

    // MARK: Où est Ollama ?

    static var appURL: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") { return u }
        let fm = FileManager.default
        return ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
            .map { URL(fileURLWithPath: $0) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    static var cliPath: String? {
        if let p = Shell.which("ollama") { return p }
        let fm = FileManager.default
        return [appURL?.appendingPathComponent("Contents/Resources/ollama").path].compactMap { $0 }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    static var installed: Bool { appURL != nil || cliPath != nil }

    // MARK: Démarrage

    func startIfNeeded() {
        guard autoStart else { return }
        ensureRunning()
    }

    /// Appelle `done(true)` dès qu'Ollama répond (en le démarrant si besoin), `done(false)` sinon.
    func ensureRunning(_ done: ((Bool) -> Void)? = nil) {
        if let d = done { waiters.append(d) }
        guard !busy else { return }
        busy = true
        state = .checking
        ping { [weak self] n in
            guard let self = self else { return }
            if let n = n { self.finish(.running(models: n)); return }
            guard self.isLocal else {
                self.finish(.failed("Ollama ne répond pas à \(self.host) (serveur distant : Toolbox ne peut pas le démarrer)."))
                return
            }
            guard Self.installed else { self.finish(.notInstalled); return }
            self.launch()
        }
    }

    private func finish(_ s: State) {
        state = s
        busy = false
        let list = waiters
        waiters = []
        list.forEach { $0(s.ok) }
    }

    /// nombre de modèles si Ollama répond, nil sinon
    private func ping(_ result: @escaping (Int?) -> Void) {
        let c = client
        Task {
            let n = try? await c.models().count
            await MainActor.run { result(n) }
        }
    }

    private func launch() {
        state = .starting
        if let app = Self.appURL {
            // l'app Ollama démarre le serveur et se range dans la barre des menus
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in }
            startedBy = "app"
        } else if let cli = Self.cliPath {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["serve"]
            p.environment = Shell.environment
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                process = p
                startedBy = "serve"
            } catch {
                finish(.failed("Impossible de lancer « ollama serve » : \(error.localizedDescription)"))
                return
            }
        }
        waitUntilUp(tries: 40)
    }

    private func waitUntilUp(tries: Int) {
        ping { [weak self] n in
            guard let self = self else { return }
            if let n = n { self.finish(.running(models: n)); return }
            if tries <= 0 {
                self.finish(.failed("Ollama a été lancé mais ne répond pas (20 s). Essaie « ollama serve » dans un terminal pour voir l'erreur."))
                return
            }
            if let p = self.process, !p.isRunning {
                // souvent : un autre Ollama occupe déjà le port, ou il a planté au démarrage
                self.process = nil
                self.startedBy = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitUntilUp(tries: tries - 1) }
        }
    }

    /// À la fermeture de Toolbox : on n'arrête que le `ollama serve` qu'on a lancé nous-mêmes.
    func stopIfOwned() {
        guard stopOnQuit, let p = process, p.isRunning else { return }
        p.terminate()
        process = nil
        startedBy = nil
    }

    func restartCheck() {
        busy = false
        ensureRunning()
    }
}

// MARK: - Réglages

struct OllamaSettings: View {
    @ObservedObject var o = OllamaService.shared

    var body: some View {
        Section("IA locale (Ollama)") {
            Toggle("Démarrer Ollama avec Toolbox", isOn: $o.autoStart)
            Text("Le serveur seul prend très peu de mémoire : un modèle n'est chargé qu'au moment où tu demandes quelque chose (explication d'erreur, formule, modèle LaTeX…), puis libéré après quelques minutes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if OllamaService.appURL == nil {
                Toggle("Arrêter « ollama serve » en quittant Toolbox", isOn: $o.stopOnQuit)
            }
            HStack(spacing: 8) {
                Circle().fill(o.state.ok ? Color.green : (o.state == .starting || o.state == .checking ? Color.orange : Color.secondary))
                    .frame(width: 8, height: 8)
                Text(o.state.label).font(.callout)
                if o.state == .starting || o.state == .checking { ProgressView().controlSize(.small) }
                Spacer()
                Button(o.state.ok ? "Vérifier" : "Démarrer") { o.restartCheck() }
            }
            if o.state == .notInstalled {
                HStack {
                    Text("Installe-le avec Homebrew (brew install ollama) ou depuis ollama.com.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("ollama.com") { if let u = URL(string: "https://ollama.com/download/mac") { NSWorkspace.shared.open(u) } }
                }
            } else if case .running(let n) = o.state, n == 0 {
                Text("Installe un modèle dans le Terminal, par exemple : ollama pull qwen2.5-coder:7b")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
