import SwiftUI
import AppKit
import PDFCore

// MARK: - Mettre à jour Toolbox : git pull + compilation + réinstallation, sans le Terminal

final class UpdateStore: ObservableObject {
    static let shared = UpdateStore()

    enum Phase: Equatable { case idle, checking, pulling, building, installing, failed }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var log = ""
    @Published private(set) var behind = 0                 // commits à récupérer
    @Published private(set) var incoming: [String] = []    // leurs messages
    @Published private(set) var dirty = 0                  // fichiers modifiés sans commit
    @Published private(set) var sourcesNewer = false       // code modifié depuis la compilation
    @Published private(set) var isRepo = false
    @Published private(set) var checkedAt: Date?
    @Published var message = ""
    @Published var sourceDir: URL? = UpdateStore.findSource() {
        didSet { if let d = sourceDir { UserDefaults.standard.set(d.path, forKey: "build.sourceDir") } }
    }

    var available: Bool { behind > 0 || sourcesNewer }
    var busy: Bool { [.checking, .pulling, .building, .installing].contains(phase) }

    /// Le dossier du code : noté par build.sh, sinon l'emplacement habituel.
    static func findSource() -> URL? {
        var candidates: [String] = []
        if let saved = UserDefaults.standard.string(forKey: "build.sourceDir") { candidates.append(saved) }
        candidates += ["Developer/pdf-toolbox", "Developer/toolbox", "Projects/pdf-toolbox", "pdf-toolbox", "toolbox"]
            .map { NSHomeDirectory() + "/" + $0 }
        return candidates.map { URL(fileURLWithPath: $0) }.first { isSource($0) }
    }

    /// Ouvre la fenêtre des réglages (onglet Général : la mise à jour y est).
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    static func isSource(_ u: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: u.appendingPathComponent("build.sh").path)
            && fm.fileExists(atPath: u.appendingPathComponent("Package.swift").path)
    }

    /// Date de la compilation en cours d'exécution.
    static var builtAt: Date {
        let exe = Bundle.main.executableURL ?? Bundle.main.bundleURL
        return (try? exe.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func newestSource(in dir: URL) -> Date {
        var newest = Date.distantPast
        for sub in ["Sources", "Resources", "Package.swift", "build.sh"] {
            let u = dir.appendingPathComponent(sub)
            if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
                for case let f as URL in e {
                    if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > newest { newest = d }
                }
            } else if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > newest {
                newest = d
            }
        }
        return newest
    }

    private static let gitEnv = ["GIT_TERMINAL_PROMPT": "0"]

    private static func git(_ args: [String], in dir: URL) -> Shell.Output? {
        guard let g = Shell.which("git") else { return nil }
        return try? Shell.run(g, args, in: dir, extraEnvironment: gitEnv)
    }

    // MARK: Vérifier

    func check(silent: Bool = false) {
        guard !busy, let dir = sourceDir else {
            if sourceDir == nil { message = "Je ne trouve pas le dossier du code : choisis-le." }
            return
        }
        phase = .checking
        if !silent { message = "Vérification…" }
        let built = Self.builtAt
        runInBackground({ () -> (Bool, Int, [String], Int, Bool) in
            let repo = Self.git(["rev-parse", "--is-inside-work-tree"], in: dir)?.status == 0
            var behind = 0, incoming: [String] = [], dirty = 0
            if repo {
                _ = Self.git(["fetch", "--quiet"], in: dir)
                if let r = Self.git(["rev-list", "--count", "HEAD..@{u}"], in: dir), r.status == 0 {
                    behind = Int(r.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                }
                if behind > 0, let r = Self.git(["log", "--format=%s", "HEAD..@{u}"], in: dir) {
                    incoming = r.text.components(separatedBy: "\n").filter { !$0.isEmpty }
                }
                if let r = Self.git(["status", "--porcelain"], in: dir) {
                    dirty = r.text.components(separatedBy: "\n").filter { !$0.isEmpty }.count
                }
            }
            let newer = Self.newestSource(in: dir) > built.addingTimeInterval(5)
            return (repo, behind, incoming, dirty, newer)
        }) { [weak self] r in
            guard let self = self else { return }
            self.phase = .idle
            self.checkedAt = Date()
            guard case .success(let (repo, behind, incoming, dirty, newer)) = r else { return }
            self.isRepo = repo
            self.behind = behind
            self.incoming = incoming
            self.dirty = dirty
            self.sourcesNewer = newer
            if self.available {
                var parts: [String] = []
                if behind > 0 { parts.append("\(behind) nouveauté\(behind > 1 ? "s" : "") sur GitHub") }
                if newer { parts.append("code modifié depuis la dernière compilation") }
                self.message = "Mise à jour disponible : " + parts.joined(separator: " · ")
                if silent { ToastCenter.shared.show("🆕 Mise à jour de Toolbox prête : ⌘K → « Mettre à jour Toolbox »", seconds: 6) }
            } else if !silent {
                self.message = "Toolbox est à jour ✓"
            }
        }
    }

    // MARK: Mettre à jour

    func update() {
        guard !busy, let dir = sourceDir else { return }
        log = ""
        message = "Mise à jour en cours… (2 à 4 minutes)"
        phase = .pulling
        let append: (String) -> Void = { chunk in
            DispatchQueue.main.async {
                self.log += chunk
                if self.log.count > 40_000 { self.log = String(self.log.suffix(30_000)) }
            }
        }
        runInBackground({ () -> Bool in
            // nouveautés de GitHub : seulement si le dépôt n'a pas de modifications en cours
            if Self.git(["rev-parse", "--is-inside-work-tree"], in: dir)?.status == 0 {
                let dirty = Self.git(["status", "--porcelain", "--untracked-files=no"], in: dir)?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if dirty.isEmpty {
                    append("$ git pull --ff-only\n")
                    let r = try Shell.run(Shell.which("git") ?? "/usr/bin/git", ["pull", "--ff-only"], in: dir,
                                          extraEnvironment: Self.gitEnv, onOutput: append)
                    if r.status != 0 { append("⚠︎ git pull impossible : je compile le code tel qu'il est.\n") }
                } else {
                    append("ℹ︎ Modifications sans commit dans le dossier : pas de git pull, je compile le code tel qu'il est.\n")
                }
            }
            DispatchQueue.main.async { self.phase = .building }
            append("\n$ ./build.sh --no-install\n")
            let r = try Shell.run("/bin/bash", ["build.sh", "--no-install"], in: dir, onOutput: append)
            return r.status == 0 && FileManager.default.fileExists(atPath: dir.appendingPathComponent("build/Toolbox.app").path)
        }) { [weak self] r in
            guard let self = self else { return }
            if case .success(true) = r {
                self.install(from: dir)
            } else {
                self.phase = .failed
                if case .failure(let e) = r { self.log += "\n✗ " + e.localizedDescription }
                self.message = "La compilation a échoué : le journal ci-dessous dit pourquoi (tu peux me l'envoyer)."
            }
        }
    }

    /// Le remplacement se fait par un petit script détaché : il attend que Toolbox se ferme, installe, relance.
    private func install(from dir: URL) {
        phase = .installing
        message = "Installation… Toolbox va redémarrer."
        let app = dir.appendingPathComponent("build/Toolbox.app").path
        let tool = dir.appendingPathComponent("build/pdftool").path
        let script = """
        #!/bin/bash
        for i in $(seq 1 50); do pgrep -x Toolbox >/dev/null || break; sleep 0.2; done
        mkdir -p "$HOME/Applications" "$HOME/.local/bin"
        rm -rf "$HOME/Applications/Toolbox.app"
        cp -R "\(app)" "$HOME/Applications/"
        touch "$HOME/Applications/Toolbox.app"
        [ -f "\(tool)" ] && cp "\(tool)" "$HOME/.local/bin/pdftool"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Toolbox.app" >/dev/null 2>&1
        /System/Library/CoreServices/pbs -update >/dev/null 2>&1
        open "$HOME/Applications/Toolbox.app"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-install.sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            let logFile = NSHomeDirectory() + "/Library/Logs/Toolbox-update.log"
            p.arguments = ["-c", "nohup /bin/bash '\(url.path)' > '\(logFile)' 2>&1 &"]
            try p.run()
            p.waitUntilExit()
            UserDefaults.standard.set(true, forKey: "update.justInstalled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        } catch {
            phase = .failed
            message = "Installation impossible : \(error.localizedDescription)"
        }
    }

    /// Au lancement : petit mot après une mise à jour, puis vérification discrète.
    func launchCheck() {
        if UserDefaults.standard.bool(forKey: "update.justInstalled") {
            UserDefaults.standard.set(false, forKey: "update.justInstalled")
            ToastCenter.shared.show("Toolbox est à jour ✓", cheer: true)
        }
        guard UserDefaults.standard.object(forKey: "update.autocheck") as? Bool ?? true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.check(silent: true) }
    }
}

// MARK: - Réglages

struct UpdateSettings: View {
    @ObservedObject var u = UpdateStore.shared

    var body: some View {
        Section("Mise à jour de Toolbox") {
            HStack {
                Text(u.sourceDir?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Dossier du code introuvable")
                    .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                Spacer()
                Button("Choisir…") {
                    if let d = Panels.folder(directory: u.sourceDir, prompt: "C'est le code de Toolbox") {
                        if UpdateStore.isSource(d) { u.sourceDir = d; u.check() } else { u.message = "Ce dossier ne contient pas build.sh et Package.swift." }
                    }
                }
            }
            if !u.incoming.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(u.incoming.prefix(8), id: \.self) { Text("• " + $0).font(.caption) }
                }
            }
            HStack(spacing: 10) {
                if u.busy { ProgressView().controlSize(.small) }
                Text(u.message.isEmpty ? "Compilée le \(UpdateStore.builtAt.formatted(date: .abbreviated, time: .shortened))" : u.message)
                    .font(.caption).foregroundStyle(u.phase == .failed ? Color.red : (u.available ? Color.accentColor : Color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Vérifier") { u.check() }.disabled(u.busy || u.sourceDir == nil)
                Button { u.update() } label: { Label(u.available ? "Mettre à jour" : "Recompiler", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(u.busy || u.sourceDir == nil)
            }
            if !u.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(u.log).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 160)
                    .onChange(of: u.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            Text("Récupère les nouveautés de GitHub (git pull), compile avec build.sh, lance les tests, puis remplace l'appli et la relance. Compte 2 à 4 minutes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if u.checkedAt == nil { u.check() } }
    }
}
