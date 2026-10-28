import SwiftUI
import AppKit
import EventKit
import PDFCore

// MARK: - Profil

enum UserProfile {
    static let key = "user.firstName"

    /// Prénom choisi à la configuration, sinon celui de la session macOS.
    static var firstName: String {
        get {
            if let n = UserDefaults.standard.string(forKey: key), !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
            return NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: key) }
    }
}

// MARK: - Configuration de bienvenue (premier lancement)

final class OnboardingState: ObservableObject {
    static let shared = OnboardingState()

    enum Step: Int, CaseIterable { case name, courses, apps, permissions, done }

    @Published var shown = !UserDefaults.standard.bool(forKey: "onboarding.done")
    @Published var step: Step = .name
    @Published var forward = true
    @Published var name = UserProfile.firstName
    @Published var coursesRoot: URL? = CoursesStore.shared.root
    @Published var candidates: [AppShortcut] = []
    @Published var chosen: Set<String> = []
    @Published var calendarOK = HomeStore.hasAccess
    @Published var notesStatus = ""
    @Published var partyAt: Date?

    /// Apps courantes proposées si elles sont installées (VS Code Insiders, iTerm2, Discord cochées d'office).
    static let known: [(String, String)] = AppShortcutsStore.suggested + [
        ("com.apple.Safari", "Safari"), ("company.thebrowser.Browser", "Arc"), ("com.google.Chrome", "Chrome"),
        ("org.mozilla.firefox", "Firefox"), ("com.spotify.client", "Spotify"), ("notion.id", "Notion"),
        ("md.obsidian", "Obsidian"), ("com.tinyspeck.slackmacgap", "Slack"), ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.apple.Terminal", "Terminal"), ("com.apple.Notes", "Notes"), ("com.apple.mail", "Mail"),
        ("com.microsoft.VSCode", "VS Code"), ("com.apple.dt.Xcode", "Xcode"),
    ]

    func prepare() {
        name = UserProfile.firstName
        coursesRoot = CoursesStore.shared.root
        calendarOK = HomeStore.hasAccess
        let existing = AppShortcutsStore.shared.apps
        candidates = Self.known.compactMap { id, label in
            guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return AppShortcut(bundleID: id, path: u.path, name: label)
        }
        chosen = Set(existing.map { $0.id })
        if existing.isEmpty { chosen = Set(candidates.prefix(3).filter { c in AppShortcutsStore.suggested.contains { $0.0 == c.bundleID } }.map { $0.id }) }
    }

    func restart() {
        prepare()
        step = .name
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shown = true }
    }

    func go(_ s: Step) {
        forward = s.rawValue > step.rawValue
        if s == .done { partyAt = Date() }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { step = s }
    }

    func next() {
        apply(step)
        if let s = Step(rawValue: step.rawValue + 1) { go(s) }
    }

    func back() {
        if let s = Step(rawValue: step.rawValue - 1) { go(s) }
    }

    /// Enregistre ce qui a été choisi à chaque étape.
    private func apply(_ s: Step) {
        switch s {
        case .name:
            UserProfile.firstName = name
            GeneralSettings.shared.firstName = UserProfile.firstName
        case .courses:
            if let r = coursesRoot, r != CoursesStore.shared.root { CoursesStore.shared.root = r }
        case .apps:
            let store = AppShortcutsStore.shared
            // garde l'ordre actuel, ajoute les nouvelles cochées, retire les décochées parmi les proposées
            var list = store.apps.filter { a in chosen.contains(a.id) || !candidates.contains { $0.id == a.id } }
            for c in candidates where chosen.contains(c.id) && !list.contains(where: { $0.id == c.id }) { list.append(c) }
            store.apps = list
        default:
            break
        }
    }

    func finish() {
        apply(step)
        UserDefaults.standard.set(true, forKey: "onboarding.done")
        withAnimation(.easeInOut(duration: 0.35)) { shown = false }
        ToastCenter.shared.show("Bienvenue \(UserProfile.firstName) ! Toolbox est prête 🎉", cheer: true, seconds: 4)
    }

    func requestCalendar() {
        let store = EKEventStore()
        let done: (Bool) -> Void = { ok in DispatchQueue.main.async { self.calendarOK = ok } }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in done(ok) }
        } else {
            store.requestAccess(to: .event) { ok, _ in done(ok) }
        }
    }

    func requestNotes() {
        notesStatus = "Demande envoyée…"
        runInBackground({ try AppleNotes.recent(limit: 1) }) { [weak self] r in
            switch r {
            case .success: self?.notesStatus = "Notes autorisé ✓"
            case .failure(let e): self?.notesStatus = e.localizedDescription
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var o = OnboardingState.shared

    var body: some View {
        if o.shown {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                AnimatedBackdrop().opacity(0.9)
                VStack(spacing: 18) {
                    FeuilleMascot(mood: o.step == .done ? .party : .normal, poke: o.step == .done ? o.partyAt : nil)
                        .frame(width: 150, height: 132)
                    ZStack {
                        page
                            .id(o.step)
                            .transition(.asymmetric(
                                insertion: .move(edge: o.forward ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: o.forward ? .leading : .trailing).combined(with: .opacity)))
                    }
                    .frame(width: 520, height: 300)
                    .clipped()
                    dots
                    buttons
                }
                .padding(30)
                .background(RoundedRectangle(cornerRadius: 26).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 30, y: 14)
            }
            .transition(.opacity)
            .onAppear { o.prepare() }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch o.step {
        case .name:
            VStack(spacing: 14) {
                Text("Salut ! Moi c'est la Feuille 👋").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Je vais t'aider à ranger tes PDF, tes cours et ton LaTeX, sans rien envoyer sur internet. On commence : comment tu t'appelles ?")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                TextField("Ton prénom", text: $o.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .frame(width: 260)
                    .multilineTextAlignment(.center)
                    .onSubmit { o.next() }
            }
        case .courses:
            VStack(spacing: 14) {
                Text("Enchantée \(o.name.isEmpty ? "" : o.name) ! Où sont tes cours ?").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Je les affiche par matière dans « Mes cours » (TD, TP, chapitres, annales), sans rien déplacer.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Color.blue)
                    Text(o.coursesRoot?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Aucun dossier choisi")
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choisir…") {
                        if let u = Panels.folder(directory: o.coursesRoot, prompt: "Mes cours sont ici") { o.coursesRoot = u }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                Text("Pas de dossier de cours ? Passe cette étape, tu pourras le choisir plus tard.").font(.caption).foregroundStyle(.secondary)
            }
        case .apps:
            VStack(spacing: 12) {
                Text("Tes apps favorites").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Elles seront sur l'accueil et s'ouvriront avec ⌃⌥1, ⌃⌥2… depuis n'importe où.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(o.candidates) { app in
                            let on = o.chosen.contains(app.id)
                            VStack(spacing: 4) {
                                Image(nsImage: AppShortcutsStore.shared.icon(app)).resizable().frame(width: 40, height: 40)
                                Text(app.name).font(.caption).lineLimit(1)
                            }
                            .frame(width: 92, height: 74)
                            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                                    .padding(5)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    if on { o.chosen.remove(app.id) } else { o.chosen.insert(app.id) }
                                }
                            }
                        }
                    }
                }
                Text("D'autres apps s'ajoutent ensuite avec + dans le widget « Mes apps ».").font(.caption).foregroundStyle(.secondary)
            }
        case .permissions:
            VStack(spacing: 14) {
                Text("Deux petites permissions").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Facultatif : sans elles, tout le reste marche quand même.").foregroundStyle(.secondary)
                permissionRow(icon: "calendar", color: .red, title: "Calendrier",
                              detail: "Événements du jour, comptes à rebours, « cours en ce moment »",
                              ok: o.calendarOK, label: "Autoriser") { o.requestCalendar() }
                permissionRow(icon: "note.text", color: .orange, title: "Notes",
                              detail: o.notesStatus.isEmpty ? "Pense-bête et note épinglée sur l'accueil" : o.notesStatus,
                              ok: o.notesStatus.contains("✓"), label: "Autoriser") { o.requestNotes() }
            }
        case .done:
            VStack(spacing: 14) {
                Text("C'est parti\(o.name.isEmpty ? "" : ", \(o.name)") ! 🎉").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Quelques raccourcis à retenir :").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    tip("⌘K", "tout faire au clavier : outils, cours, apps, notes")
                    tip("⌥Espace", "chercher dans tes cours depuis n'importe quelle app")
                    tip("⌃⌥1…9", "lancer tes apps favorites")
                    tip("⌘,", "réglages (et relancer cette configuration)")
                }
            }
        }
    }

    private func permissionRow(icon: String, color: Color, title: String, detail: String, ok: Bool, label: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.white)
                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10).fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if ok {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Color.green)
            } else {
                Button(label, action: action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(key).font(.callout.monospaced().bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                .frame(width: 96, alignment: .leading)
            Text(text).font(.callout)
        }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingState.Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s == o.step ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: s == o.step ? 22 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: o.step)
    }

    private var buttons: some View {
        HStack {
            if o.step != .name {
                Button("Retour") { o.back() }
            }
            Spacer()
            if o.step == .done {
                Button("Ouvrir Toolbox") { o.finish() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                if o.step != .name {
                    Button("Passer") { o.go(OnboardingState.Step(rawValue: o.step.rawValue + 1) ?? .done) }
                        .buttonStyle(.borderless)
                }
                Button(o.step == .name ? "Commencer" : "Continuer") { o.next() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(o.step == .name && o.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 520)
    }
}
