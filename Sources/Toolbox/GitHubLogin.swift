import SwiftUI
import AppKit
import PDFCore

// MARK: - Connexion à GitHub (gh) sans le Terminal

/// Lance « gh auth login --web » dans un pseudo-terminal (script), récupère le code à usage unique,
/// l'affiche dans l'app, ouvre github.com/login/device, puis attend que la connexion soit validée.
final class GitHubLogin: ObservableObject {
    static let shared = GitHubLogin()

    enum State: Equatable {
        case unknown, notInstalled, loggedOut, waiting(code: String?), loggedIn(user: String), failed(String)
    }

    @Published private(set) var state = State.unknown
    private var process: Process?
    private var input: Pipe?
    private var answered = Set<String>()
    private var buffer = ""

    var gh: String? { GitHub.ghPath }

    func check() {
        guard let gh = gh else { state = .notInstalled; return }
        runInBackground({ () -> String? in
            let r = try Shell.run(gh, ["auth", "status", "--hostname", "github.com"])
            guard r.status == 0 else { return nil }
            let u = try? Shell.run(gh, ["api", "user", "--jq", ".login"])
            let login = u?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return login.isEmpty ? "connecté" : login
        }) { [weak self] r in
            guard let self = self else { return }
            if case .waiting = self.state, self.process?.isRunning == true { return }
            switch r {
            case .success(let u?): self.state = .loggedIn(user: u)
            default: self.state = .loggedOut
            }
        }
    }

    func login() {
        guard let gh = gh else { state = .notInstalled; return }
        cancel()
        state = .waiting(code: nil)
        answered = []
        buffer = ""
        let p = Process()
        // « script » donne un vrai terminal à gh (sinon il refuse le mode interactif)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", gh, "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"]
        var env = Shell.environment
        env["BROWSER"] = "true"          // c'est l'app qui ouvre la page, pas gh
        env["GH_PROMPT_DISABLED"] = nil
        p.environment = env
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        input = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let text = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.handle(text) }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.process = nil
                self?.check()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Répond aux questions de gh et repère le code « XXXX-XXXX ».
    private func handle(_ text: String) {
        buffer += text
        if buffer.count > 8000 { buffer = String(buffer.suffix(4000)) }
        let low = buffer.lowercased()
        if low.contains("authenticate git with your github credentials"), !answered.contains("git") {
            answered.insert("git"); send("Y\n")
        }
        if low.contains("how would you like to authenticate"), !answered.contains("how") {
            answered.insert("how"); send("\n")          // « Login with a web browser » est le premier choix
        }
        if let r = buffer.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) {
            let code = String(buffer[r])
            if case .waiting(let c) = state, c != code {
                state = .waiting(code: code)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
        }
        if low.contains("press enter"), !answered.contains("enter") {
            answered.insert("enter")
            send("\n")
            openDevicePage()
        }
        if low.contains("logged in as") {
            check()
        }
    }

    private func send(_ s: String) {
        input?.fileHandleForWriting.write(Data(s.utf8))
    }

    func openDevicePage() {
        if let u = URL(string: "https://github.com/login/device") { NSWorkspace.shared.open(u) }
    }

    func cancel() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        if case .waiting = state { state = .loggedOut }
    }

    func logout() {
        guard let gh = gh else { return }
        runInBackground({ try Shell.run(gh, ["auth", "logout", "--hostname", "github.com"]) }) { [weak self] _ in self?.check() }
    }
}

struct GitHubLoginRow: View {
    @ObservedObject var g = GitHubLogin.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.badge.key").foregroundStyle(isIn ? Color.green : Color.accentColor).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compte GitHub").font(.callout.weight(.semibold))
                switch g.state {
                case .unknown: Text("Vérification…").font(.caption).foregroundStyle(.secondary)
                case .notInstalled: Text("Installe d'abord GitHub CLI (gh) ci-dessus").font(.caption).foregroundStyle(.secondary)
                case .loggedOut: Text("Pour voir tes dépôts privés et cloner sans mot de passe").font(.caption).foregroundStyle(.secondary)
                case .loggedIn(let u): Text("Connecté : \(u)").font(.caption).foregroundStyle(Color.green)
                case .failed(let e): Text(e).font(.caption).foregroundStyle(Color.red)
                case .waiting(let code):
                    if let c = code {
                        HStack(spacing: 6) {
                            Text("Code :").font(.caption)
                            Text(c).font(.system(size: 15, weight: .bold, design: .monospaced)).textSelection(.enabled)
                            Text("(copié) → colle-le sur la page GitHub qui s'est ouverte").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Préparation de la connexion…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            switch g.state {
            case .loggedOut, .failed:
                Button("Se connecter") { g.login() }.buttonStyle(.borderedProminent)
            case .waiting:
                ProgressView().controlSize(.small)
                Button("Rouvrir la page") { g.openDevicePage() }
                Button("Annuler") { g.cancel() }.buttonStyle(.borderless)
            case .loggedIn:
                Button("Se déconnecter") { g.logout() }.buttonStyle(.borderless).font(.caption)
            default:
                EmptyView()
            }
        }
        .onAppear { if g.state == .unknown || g.state == .notInstalled { g.check() } }
    }

    private var isIn: Bool { if case .loggedIn = g.state { return true } else { return false } }
}
