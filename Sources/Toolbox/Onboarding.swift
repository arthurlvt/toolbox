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

    enum Step: Int, CaseIterable { case name, profile, courses, work, devices, tools, apps, permissions, done }

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
    // profil
    @Published var student = true
    @Published var worker = false
    @Published var workplace = ""
    @Published var calendarName = ""
    @Published var planningName = ""
    @Published var createCalendar = true
    @Published var loadMaquette = true
    @Published var hasPhone = true
    @Published var hasHeadphone = false
    @Published var detectedHeadphone: String?

    /// Les étapes utiles pour ce profil (pas de « cours » si on n'est pas étudiant, pas de « travail » sinon).
    var steps: [Step] {
        Step.allCases.filter { s in
            switch s {
            case .courses: return student
            case .work: return worker
            default: return true
            }
        }
    }

    var gradesEmpty: Bool { GradesStore.shared.current?.semesters.allSatisfy { $0.units.isEmpty } ?? true }

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
        let p = AppProfile.shared, plan = PlanningStore.shared
        let firstTime = !UserDefaults.standard.bool(forKey: "onboarding.done")
        student = p.student
        worker = firstTime ? (!plan.shifts.isEmpty || !p.workplace.isEmpty) : p.worker
        workplace = p.workplace
        calendarName = plan.calendarName
        planningName = plan.nameOnPlanning
        hasPhone = p.hasPhone
        detectedHeadphone = AppProfile.pairedNothing
        hasHeadphone = firstTime ? detectedHeadphone != nil : p.hasHeadphone
        loadMaquette = gradesEmpty
        DependencyStore.shared.refresh()
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
        go(following(step))
    }

    func following(_ s: Step) -> Step {
        let list = steps
        guard let i = list.firstIndex(of: s), i + 1 < list.count else { return .done }
        return list[i + 1]
    }

    func back() {
        let list = steps
        if let i = list.firstIndex(of: step), i > 0 { go(list[i - 1]) }
    }

    /// Enregistre ce qui a été choisi à chaque étape.
    private func apply(_ s: Step) {
        switch s {
        case .name:
            UserProfile.firstName = name
            GeneralSettings.shared.firstName = UserProfile.firstName
        case .profile:
            AppProfile.shared.student = student
            AppProfile.shared.worker = worker
            if worker, calendarName.isEmpty || calendarName == "McDo" {
                calendarName = AppProfile.shortName(workplace)
            }
        case .courses:
            if let r = coursesRoot, r != CoursesStore.shared.root { CoursesStore.shared.root = r }
            let g = GradesStore.shared
            if loadMaquette, gradesEmpty, let i = g.index {
                g.years[i].semesters = GradesStore.l1InfoAvignon()
                g.years[i].rules.resit = false
                g.years[i].rules.semesterCompensation = true
                g.years[i].rules.yearCompensation = true
            }
        case .work:
            let p = AppProfile.shared, plan = PlanningStore.shared
            p.workplace = workplace.trimmingCharacters(in: .whitespaces)
            let cal = calendarName.trimmingCharacters(in: .whitespaces).isEmpty ? AppProfile.shortName(workplace) : calendarName
            plan.calendarName = cal
            plan.eventTitle = "Travail " + cal
            if !planningName.trimmingCharacters(in: .whitespaces).isEmpty { plan.nameOnPlanning = planningName }
            plan.addToCalendar = createCalendar
            if createCalendar, HomeStore.hasAccess { plan.createWorkCalendar() }
        case .devices:
            AppProfile.shared.hasPhone = hasPhone
            AppProfile.shared.hasHeadphone = hasHeadphone
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

    /// Passe par le magasin du Planning (qui se réinitialise une fois l'accès donné), pour pouvoir créer le calendrier tout de suite.
    func requestCalendarForWork() {
        PlanningStore.shared.requestAccess()
        for delay in [1.0, 3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.calendarOK = HomeStore.hasAccess }
        }
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
                    .frame(width: 540, height: 340)
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
        case .profile:
            VStack(spacing: 14) {
                Text("Enchantée \(o.name.isEmpty ? "" : o.name) ! Parle-moi de toi").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Je n'affiche que ce qui te sert : tu pourras tout changer dans les réglages.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                choiceRow(icon: "graduationcap.fill", color: .blue, title: "Je suis étudiant",
                          detail: "Mes cours, Révisions, Notes & ECTS, comptes à rebours des CC", isOn: $o.student)
                choiceRow(icon: "briefcase.fill", color: .orange, title: "Je travaille à côté",
                          detail: "Planning importé depuis une photo, calendrier dédié, prochain shift", isOn: $o.worker)
                if o.worker {
                    TextField("Où ? (ex. : McDonald's Sénas)", text: $o.workplace)
                        .textFieldStyle(.roundedBorder).frame(width: 320)
                }
            }
        case .work:
            VStack(spacing: 12) {
                Text("Ton travail\(o.workplace.isEmpty ? "" : " chez \(o.workplace)")").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Prends ton planning en photo dans « Planning » : je lis tes horaires et je les mets dans ton calendrier.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Ton nom sur le planning").foregroundStyle(.secondary)
                        TextField("Ex. : Arthur L.", text: $o.planningName).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    GridRow {
                        Text("Nom du calendrier").foregroundStyle(.secondary)
                        TextField("Macdo", text: $o.calendarName).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                }
                Toggle("Créer ce calendrier (jaune) et y mettre mes shifts", isOn: $o.createCalendar)
                if o.createCalendar && !o.calendarOK {
                    permissionRow(icon: "calendar", color: .red, title: "Accès au Calendrier",
                                  detail: "Nécessaire pour créer le calendrier « \(o.calendarName.isEmpty ? "Travail" : o.calendarName) »",
                                  ok: o.calendarOK, label: "Autoriser") { o.requestCalendarForWork() }
                }
            }
        case .devices:
            VStack(spacing: 14) {
                Text("Tes appareils").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Pour afficher leur batterie et te prévenir quand il faut les recharger.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                choiceRow(icon: "iphone", color: .indigo, title: "J'ai un iPhone",
                          detail: "Widgets Prochain shift, Mon Mac, Ma journée (app Scriptable), batterie de l'iPhone sur le Mac",
                          isOn: $o.hasPhone)
                choiceRow(icon: "headphones", color: .gray, title: "J'ai un casque Nothing",
                          detail: o.detectedHeadphone.map { "Trouvé : \($0) · batterie, réduction de bruit, mode cours" }
                            ?? "Batterie, réduction de bruit, égaliseur, mode automatique en cours",
                          isOn: $o.hasHeadphone)
                if o.hasPhone {
                    Text("Les widgets iPhone s'installent ensuite depuis Accueil → Personnaliser → Widgets sur l'iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .tools:
            VStack(spacing: 10) {
                Text("Les outils à installer").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Facultatif : coche ce qui te manque, j'ouvre le Terminal et j'installe tout (ton mot de passe se tape là-bas).")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
                DependenciesView(compact: true)
            }
        case .courses:
            VStack(spacing: 14) {
                Text("Où sont tes cours ?").font(.system(size: 24, weight: .bold, design: .rounded))
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
                if o.gradesEmpty {
                    Toggle("Préparer Notes & ECTS avec la maquette L1 Informatique (CERI, Avignon)", isOn: $o.loadMaquette)
                }
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

    private func choiceRow(icon: String, color: Color, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.white)
                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10).fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(isOn.wrappedValue ? color.opacity(0.1) : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isOn.wrappedValue.toggle() } }
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
            ForEach(o.steps, id: \.rawValue) { s in
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
                    Button("Passer") { o.go(o.following(o.step)) }
                        .buttonStyle(.borderless)
                }
                Button(o.step == .name ? "Commencer" : "Continuer") { o.next() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(o.step == .name && o.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 540)
    }
}
