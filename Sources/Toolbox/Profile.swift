import SwiftUI
import AppKit
import IOBluetooth
import PDFCore

// MARK: - Profil : ce que la personne fait, ce qu'elle a

/// Étudiant ? Travaille ? iPhone ? Casque Nothing ? Les pages et widgets qui ne servent à rien sont masqués.
/// Par défaut tout est affiché (rien ne disparaît pour quelqu'un qui n'a pas refait la configuration).
final class AppProfile: ObservableObject {
    static let shared = AppProfile()
    private let d = UserDefaults.standard

    @Published var student = UserDefaults.standard.object(forKey: "profile.student") as? Bool ?? true {
        didSet { d.set(student, forKey: "profile.student") }
    }
    @Published var worker = UserDefaults.standard.object(forKey: "profile.worker") as? Bool ?? true {
        didSet { d.set(worker, forKey: "profile.worker") }
    }
    @Published var workplace = UserDefaults.standard.string(forKey: "profile.workplace") ?? "" {
        didSet { d.set(workplace, forKey: "profile.workplace") }
    }
    @Published var hasPhone = UserDefaults.standard.object(forKey: "profile.phone") as? Bool ?? true {
        didSet {
            d.set(hasPhone, forKey: "profile.phone")
            PhoneWidget.enabled = hasPhone
            if hasPhone { PhoneStatusStore.shared.start() }
        }
    }
    @Published var hasHeadphone = UserDefaults.standard.object(forKey: "profile.headphone") as? Bool ?? true {
        didSet {
            d.set(hasHeadphone, forKey: "profile.headphone")
            if hasHeadphone { HeadphoneStore.shared.start(); HeadphoneAuto.shared.start() }
        }
    }

    func shows(_ t: Tool) -> Bool {
        switch t {
        case .courses, .revisions, .grades: return student
        case .planning: return worker
        case .headphone: return hasHeadphone
        default: return true
        }
    }

    func allows(_ w: HomeWidget) -> Bool {
        switch w {
        case .courses, .grades, .nextExam: return student
        case .planning, .nextShift: return worker
        default: return true
        }
    }

    /// Nom court pour le calendrier : « McDonald's Sénas » → « Macdo », « Carrefour Cavaillon » → « Carrefour ».
    static func shortName(_ workplace: String) -> String {
        let f = CourseLibrary.fold(workplace)
        if f.contains("mcdo") || f.contains("mcdonald") || f.contains("macdo") { return "Macdo" }
        let first = workplace.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init) ?? ""
        return first.isEmpty ? "Travail" : first
    }

    /// Un casque Nothing / CMF déjà appairé au Mac.
    static var pairedNothing: String? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: HeadphoneStore.isNothing)?.name
    }
}

/// Affiche son contenu seulement si le profil le permet (et se met à jour quand il change).
struct IfProfile<Content: View>: View {
    @ObservedObject var p = AppProfile.shared
    let key: KeyPath<AppProfile, Bool>
    @ViewBuilder let content: () -> Content

    init(_ key: KeyPath<AppProfile, Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = content
    }

    var body: some View {
        if p[keyPath: key] { content() }
    }
}

// MARK: - Outils à installer

/// Ce dont Toolbox a besoin (ou se sert s'il est là) : Homebrew, LaTeX, Ghostscript, Ollama et un modèle.
struct Dependency: Identifiable, Equatable {
    let id: String
    let name: String
    let why: String
    let icon: String
    let size: Int64          // place approximative sur le disque
    let installed: Bool
    let script: String       // commandes (après Homebrew)
}

final class DependencyStore: ObservableObject {
    static let shared = DependencyStore()

    @Published private(set) var items: [Dependency] = []
    @Published var selected: Set<String> = []
    @Published private(set) var freeSpace: Int64 = 0
    @Published var message = ""

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ramGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    /// Modèle conseillé selon la RAM : 3B jusqu'à 8 Go, 7B au-delà.
    static var suggestedModel: (name: String, size: Int64) {
        ramGB <= 12 ? ("qwen2.5-coder:3b", 1_900_000_000) : ("qwen2.5-coder:7b", 4_700_000_000)
    }

    static var hasOllamaModel: Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models/manifests")
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return true }
        return false
    }

    func refresh() {
        let model = Self.suggestedModel
        let latexPackages = "latexmk tcolorbox pgf environ trimspaces needspace comment lastpage titlesec enumitem csquotes babel-french fancyhdr booktabs lm helvetic texcount"
        items = [
            Dependency(id: "brew", name: "Homebrew", why: "Installe tout le reste en une commande", icon: "shippingbox",
                       size: 600_000_000, installed: Self.brewPath != nil,
                       script: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#),
            Dependency(id: "latex", name: "LaTeX (BasicTeX + paquets)", why: "Éditeur LaTeX, modèles TD/TP/cours, Annalyse", icon: "function",
                       size: 450_000_000, installed: Latex.isAvailable(.pdflatex),
                       script: "brew install --cask basictex\neval \"$(/usr/libexec/path_helper)\"\nexport PATH=\"/Library/TeX/texbin:$PATH\"\n"
                           + "echo \"Mot de passe du Mac demandé pour installer les paquets LaTeX :\"\n"
                           + "sudo tlmgr update --self\nsudo tlmgr install \(latexPackages)"),
            Dependency(id: "gs", name: "Ghostscript", why: "Compression des PDF bien plus efficace", icon: "arrow.down.right.and.arrow.up.left",
                       size: 120_000_000, installed: Compressor.ghostscriptPath != nil,
                       script: "brew install ghostscript"),
            Dependency(id: "7z", name: "7-Zip", why: "Archives .7z (chiffrement AES) et .rar", icon: "archivebox",
                       size: 8_000_000, installed: ArchiveTool.sevenZip != nil,
                       script: "brew install sevenzip"),
            Dependency(id: "ollama", name: "Ollama", why: "IA locale : explications d'erreurs, formules, modèles sur mesure", icon: "sparkles",
                       size: 500_000_000, installed: OllamaService.installed,
                       script: "brew install ollama"),
            Dependency(id: "model", name: "Modèle IA \(model.name)", why: String(format: "Adapté à tes %.0f Go de RAM", Self.ramGB), icon: "cpu",
                       size: model.size, installed: Self.hasOllamaModel,
                       script: "(pgrep -x ollama >/dev/null || (ollama serve >/dev/null 2>&1 &))\nsleep 3\nollama pull \(model.name)"),
        ]
        let missing = Set(items.filter { !$0.installed }.map { $0.id })
        selected = selected.intersection(missing).union(selected.isEmpty ? missing : [])
        if let v = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            freeSpace = v
        }
    }

    var neededSpace: Int64 {
        items.filter { !$0.installed && selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    /// Écrit un script .command et l'ouvre dans le Terminal (le mot de passe se tape là, Toolbox ne le voit jamais).
    func install() {
        var chosen = items.filter { !$0.installed && selected.contains($0.id) }
        guard !chosen.isEmpty else { message = "Rien à installer."; return }
        // Homebrew d'abord, s'il manque et qu'on en a besoin
        if Self.brewPath == nil, !chosen.contains(where: { $0.id == "brew" }), chosen.contains(where: { $0.id != "model" }),
           let brew = items.first(where: { $0.id == "brew" }) {
            chosen.insert(brew, at: 0)
        }
        var lines = ["#!/bin/bash", "clear", "echo \"🧰 Toolbox : installation des outils\"", "echo", "set -e"]
        for dep in chosen {
            lines.append("echo")
            lines.append("echo \"━━ \(dep.name) ━━\"")
            if dep.id != "brew" {
                lines.append("eval \"$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)\" || true")
            }
            lines.append(dep.script)
        }
        lines += ["echo", "echo \"✅ Terminé ! Retourne dans Toolbox et clique « Vérifier ».\"", "echo \"(tu peux fermer cette fenêtre)\""]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Installer outils Toolbox.command")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            message = "Installation lancée dans le Terminal (\(chosen.map { $0.name }.joined(separator: ", "))). Clique « Vérifier » quand c'est fini."
        } catch {
            message = "Impossible de préparer l'installation : \(error.localizedDescription)"
        }
    }
}

struct DependenciesView: View {
    @ObservedObject var s = DependencyStore.shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(s.items) { dep in
                HStack(spacing: 10) {
                    Image(systemName: dep.icon).foregroundStyle(dep.installed ? Color.green : Color.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dep.name).font(.callout.weight(.semibold))
                        Text(dep.why).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if dep.installed {
                        Label("Installé", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                            .font(.caption).foregroundStyle(Color.green)
                    } else {
                        Text("≈ " + FileUtils.formatBytes(dep.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(get: { s.selected.contains(dep.id) },
                                                 set: { if $0 { s.selected.insert(dep.id) } else { s.selected.remove(dep.id) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, compact ? 2 : 4)
            }
            HStack(spacing: 10) {
                let need = s.neededSpace
                Text("Libre sur le disque : \(FileUtils.formatBytes(s.freeSpace))" + (need > 0 ? " · à installer : \(FileUtils.formatBytes(need))" : ""))
                    .font(.caption).foregroundStyle(need > s.freeSpace - 1_000_000_000 ? Color.orange : Color.secondary)
                Spacer()
                Button("Vérifier") { s.refresh() }
                Button { s.install() } label: { Label("Installer", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.neededSpace == 0)
            }
            if !s.message.isEmpty {
                Text(s.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { s.refresh() }
    }
}

// MARK: - Réglages

struct ProfileSettings: View {
    @ObservedObject var p = AppProfile.shared

    var body: some View {
        Section("Mon profil") {
            Toggle("Je suis étudiant (Mes cours, Révisions, Notes & ECTS)", isOn: $p.student)
            Toggle("Je travaille (Planning, prochain shift)", isOn: $p.worker)
            if p.worker {
                TextField("Où", text: $p.workplace, prompt: Text("Ex. : McDonald's Sénas"))
            }
            Toggle("J'ai un iPhone (widgets Scriptable, batterie de l'iPhone)", isOn: $p.hasPhone)
            Toggle("J'ai un casque Nothing (page Casque, mode automatique)", isOn: $p.hasHeadphone)
        }
        Section("Outils à installer") {
            DependenciesView(compact: true)
        }
    }
}
