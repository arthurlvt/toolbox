import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import UserNotifications
import PDFCore

// Note : aucune vue n'utilise @State. Sur les SDK récents, @State est une macro
// fournie uniquement avec Xcode complet ; on passe par ObservableObject.

// MARK: - Routage des fichiers ouverts depuis le Finder

final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var incoming: [URL] = []
    /// Outil à afficher (demandé depuis une notification, la mini-recherche…).
    @Published var show: Tool?
    /// « S'entraîner » depuis Mes cours : (nom affiché, nom du dossier) de la matière.
    @Published var trainFor: (String, String)?
    /// Texte à insérer dans le document LaTeX ouvert (calculatrice…).
    @Published var latexInsert: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        NSApp.activate(ignoringOtherApps: true)
        ClipboardStore.shared.start()
        WatchFolderStore.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { LatexDocsStore.shared.refresh() }
        UpdateStore.shared.launchCheck()
        AppShortcutsStore.shared.start()
        DiscordPresence.shared.start()
        MacStatusStore.shared.start()
        if AppProfile.shared.hasHeadphone {
            HeadphoneStore.shared.start()
            HeadphoneAuto.shared.start()
        }
        MorningCheck.shared.start()
        ClassMode.shared.start()
        if AppProfile.shared.hasPhone { PhoneStatusStore.shared.start() }
        // IA locale : Ollama démarré en arrière-plan s'il ne tourne pas (réglable)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { OllamaService.shared.startIfNeeded() }
        // Notifications de début de cours (boutons « Ouvrir le dernier TD/TP », « Nouveau TP »…)
        UNUserNotificationCenter.current().delegate = self
        CourseAlerts.setup()
        _ = CoursesStore.shared
        // ⌥Espace : chercher dans ses cours depuis n'importe quelle app
        if UserDefaults.standard.object(forKey: "courses.hotkey") as? Bool ?? true {
            GlobalHotKey.shared.register { QuickSearchPanel.shared.toggle() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["course"] as? String ?? ""
        let action = response.actionIdentifier
        DispatchQueue.main.async { CourseAlerts.handle(action: action, courseID: id) }
        completionHandler()
    }

    /// Glisser sur l'icône du Dock, « Ouvrir avec → Toolbox ».
    func application(_ application: NSApplication, open urls: [URL]) {
        AppRouter.shared.incoming += urls
    }

    /// Fenêtre fermée : Toolbox reste disponible dans la barre des menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        OllamaService.shared.stopIfOwned()
    }
}

// MARK: - Services du Finder (clic droit → Services)

final class ServiceProvider: NSObject {

    private func files(_ pboard: NSPasteboard, pdfOnly: Bool = true) -> [URL] {
        let objects = pboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) ?? []
        let urls = objects.compactMap { $0 as? URL }
        return pdfOnly ? urls.filter { $0.pathExtension.lowercased() == "pdf" } : urls
    }

    private func perform(_ name: String, _ urls: [URL], _ work: @escaping ([URL]) throws -> [URL]) {
        guard !urls.isEmpty else { return }
        runInBackground({ try work(urls) }) { result in
            switch result {
            case .success(let outputs):
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Toolbox — \(name) : échec"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc func compressPDF(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform("Compresser", files(pboard)) { (urls: [URL]) -> [URL] in
            try urls.map { (url: URL) -> URL in
                let out = FileUtils.sibling(of: url, suffix: "_compressé")
                _ = try Compressor.compress(url, level: .balanced, to: out)
                return out
            }
        }
    }

    @objc func mergePDF(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = files(pboard).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        perform("Fusionner", urls) { (urls: [URL]) -> [URL] in
            let out = FileUtils.unique(urls[0].deletingLastPathComponent().appendingPathComponent("fusion.pdf"))
            try PDFOps.merge(urls, into: out)
            return [out]
        }
    }

    @objc func ocrPDF(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform("Rendre cherchable (OCR)", files(pboard)) { (urls: [URL]) -> [URL] in
            try urls.map { (url: URL) -> URL in
                let out = FileUtils.sibling(of: url, suffix: "_ocr")
                _ = try OCR.makeSearchable(url, to: out)
                return out
            }
        }
    }

    @objc func openInToolbox(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = files(pboard, pdfOnly: false)
        DispatchQueue.main.async {
            AppRouter.shared.incoming += urls
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Application

@main
struct ToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // « Toolbox --selftest » : vérifie les calculs puis quitte (lancé par build.sh)
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
    }

    var body: some Scene {
        Window("Toolbox", id: "main") {
            ContentView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Palette de commandes…") { PaletteState.shared.toggle() }
                    .keyboardShortcut("k")
                Button("Capture d'écran → texte") { ScreenText.capture() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarPanel()
        } label: {
            Image(systemName: "wrench.and.screwdriver.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

enum ToolSection: String, CaseIterable, Identifiable {
    case home = "Toolbox"          // sans titre : l'Accueil tout en haut
    case life = "Quotidien"
    case study = "Études"
    case pages = "Pages"
    case optimize = "Optimiser"

    var id: String { rawValue }
    var tools: [Tool] { Tool.allCases.filter { $0.section == self } }
}

enum Tool: String, CaseIterable, Identifiable {
    case home
    case planning, headphone
    case courses, revisions, grades, calc, annales
    case latex, organize, merge, split, layout, convert, stamp, security, compare, sign
    case compress, ocr, batch, cleanup

    var id: String { rawValue }

    var section: ToolSection {
        switch self {
        case .home: return .home
        case .courses, .revisions, .grades, .calc, .annales: return .study
        case .planning, .headphone: return .life
        case .latex, .organize, .merge, .split, .layout, .convert, .stamp, .security, .compare, .sign: return .pages
        case .compress, .ocr, .cleanup: return .optimize
        case .batch: return .optimize
        }
    }

    var title: String {
        switch self {
        case .home: return "Accueil"
        case .courses: return "Mes cours"
        case .revisions: return "Révisions"
        case .grades: return "Notes & ECTS"
        case .calc: return "Calculatrice"
        case .planning: return "Planning"
        case .headphone: return "Casque"
        case .compare: return "Comparer"
        case .sign: return "Signer"
        case .organize: return "Organiser"
        case .merge: return "Fusionner"
        case .split: return "Diviser"
        case .layout: return "Mise en page"
        case .compress: return "Compresser & archiver"
        case .ocr: return "OCR"
        case .cleanup: return "Nettoyer le Mac"
        case .stamp: return "Numéroter & filigrane"
        case .security: return "Sécurité & infos"
        case .convert: return "Convertir"
        case .batch: return "Traitement par lots"
        case .annales: return "Annalyse"
        case .latex: return "LaTeX"
        }
    }

    var subtitle: String {
        switch self {
        case .home: return "Raccourcis, projets, agenda du jour"
        case .courses: return "Cours, TD, TP et annales rangés par matière"
        case .revisions: return "Tes CC du calendrier, avec une checklist reliée aux cours, TD et annales"
        case .grades: return "Moyennes, crédits ECTS, compensation et note qu'il te faut au prochain CC"
        case .calc: return "Graphique (courbes, limites, dérivées, LaTeX), scientifique et programmeur (bases, bits)"
        case .headphone: return "Batterie, réduction de bruit, égaliseur et mode automatique de ton casque Nothing"
        case .planning: return "Photo du planning → Calendrier, heures du mois, alertes si ça tombe sur un CC"
        case .compare: return "Voir ce qui a changé entre deux versions d'un PDF"
        case .sign: return "Dessiner ou importer ta signature et la poser sur un PDF"
        case .organize: return "Réordonner, pivoter, supprimer et extraire des pages"
        case .merge: return "Assembler plusieurs PDF en un seul"
        case .split: return "Découper un PDF en plusieurs fichiers"
        case .layout: return "Rogner les marges, 2 ou 4 pages par feuille, livret"
        case .compress: return "Réduire le poids de tes PDF, créer ou ouvrir des archives zip, tar.gz, 7z…"
        case .ocr: return "Rendre les scans cherchables et copiables (hors ligne)"
        case .cleanup: return "Caches, dossiers de compilation, corbeille, gros fichiers, doublons : de la place en un clic"
        case .stamp: return "Numéros de page, en-tête, pied de page, filigrane"
        case .security: return "Mot de passe, titre, auteur, mots-clés"
        case .convert: return "Images ↔ PDF, PDF → texte, export pour RAG"
        case .batch: return "Appliquer plusieurs opérations à tout un lot de PDF"
        case .annales: return "N'importe quel dépôt → sujet LaTeX propre, vérifié, tagué et rangé (IA locale)"
        case .latex: return "Compiler, prévisualiser, naviguer et démarrer des projets .tex"
        }
    }

    /// Mots qu'on peut taper dans ⌘K pour trouver l'outil (en plus du titre et de la section).
    var synonyms: String {
        switch self {
        case .cleanup: return "optimiser nettoyer menage espace disque place stockage liberer cache plein vider corbeille"
        case .compress: return "zip tar archive alleger reduire poids taille extraire decompresser"
        case .calc: return "calcul scientifique programmeur hexadecimal binaire graphe courbe fonction"
        case .grades: return "moyenne note ects credits ue semestre"
        case .planning: return "travail shift horaires macdo boulot"
        case .headphone: return "nothing ecouteurs bluetooth batterie anc"
        case .latex: return "tex document td tp cours rapport"
        case .courses: return "cours matieres td tp annales"
        case .revisions: return "cc examen partiel checklist"
        default: return ""
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .courses: return "books.vertical.fill"
        case .revisions: return "checklist"
        case .grades: return "chart.bar.doc.horizontal"
        case .calc: return "x.squareroot"
        case .planning: return "fork.knife"
        case .headphone: return "headphones"
        case .compare: return "plus.forwardslash.minus"
        case .sign: return "signature"
        case .organize: return "square.grid.2x2"
        case .merge: return "doc.on.doc"
        case .split: return "scissors"
        case .layout: return "rectangle.split.2x1"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .ocr: return "text.viewfinder"
        case .cleanup: return "sparkles"
        case .stamp: return "number"
        case .security: return "lock.doc"
        case .convert: return "arrow.triangle.2.circlepath"
        case .batch: return "square.stack.3d.down.right"
        case .annales: return "graduationcap"
        case .latex: return "function"
        }
    }

    var color: Color {
        switch self {
        case .home: return .accentColor
        case .courses: return .orange
        case .revisions: return .mint
        case .grades: return .green
        case .calc: return .blue
        case .planning: return .yellow
        case .headphone: return .cyan
        case .compare: return .orange
        case .sign: return .blue
        case .organize: return .blue
        case .merge: return .purple
        case .split: return .orange
        case .layout: return .brown
        case .compress: return .green
        case .ocr: return .mint
        case .cleanup: return .purple
        case .stamp: return .pink
        case .security: return .gray
        case .convert: return .teal
        case .batch: return .cyan
        case .annales: return .red
        case .latex: return .indigo
        }
    }
}

final class NavigationState: ObservableObject {
    @Published var selection: Tool? = .home
}

struct ContentView: View {
    @StateObject private var nav = NavigationState()
    @ObservedObject private var profile = AppProfile.shared
    // Modèles qui survivent au changement d'outil (et reçoivent les fichiers du Finder).
    @StateObject private var organize = OrganizeModel()
    @StateObject private var latex = LatexModel()
    @StateObject private var merge = MergeStore()
    @StateObject private var convert = ConvertStore()
    @StateObject private var annales = AnnalesStore()
    @StateObject private var home = HomeStore()
    @StateObject private var compare = CompareStore()
    @StateObject private var sign = SignStore()

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selection) {
                // l'Accueil seul, tout en haut, sans titre de section
                sidebarRow(.home)
                ForEach(ToolSection.allCases.filter { $0 != .home }) { section in
                    let tools = section.tools.filter { profile.shows($0) }
                    if !tools.isEmpty {
                        Section(section.rawValue) {
                            ForEach(tools) { tool in sidebarRow(tool) }
                        }
                    }
                }
            }
            .tourTarget("sidebar")
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
            .safeAreaInset(edge: .bottom) {
                Text("100 % local · rien ne quitte ton Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        } detail: {
            detail(nav.selection ?? .home)
                .tourTarget("detail")
        }
        .overlay(alignment: .bottomTrailing) { ToastView() }
        .overlay { PaletteView() }
        .overlay { OnboardingView() }
        .overlay { TourOverlay() }
        .onAppear(perform: installPalette)
        .onChange(of: nav.selection) { t in
            DiscordPresence.shared.refresh()
            AppRouterSelection.current = t
            if let t = t { TourStore.shared.toolOpened(t) }
        }
        .onChange(of: profile.student) { _ in leaveHiddenTool() }
        .onChange(of: profile.worker) { _ in leaveHiddenTool() }
        .onChange(of: profile.hasHeadphone) { _ in leaveHiddenTool() }
        .onReceive(AppRouter.shared.$show) { tool in
            guard let tool = tool else { return }
            DispatchQueue.main.async {
                AppRouter.shared.show = nil
                nav.selection = tool
            }
        }
        .onReceive(AppRouter.shared.$latexInsert) { text in
            guard let text = text else { return }
            DispatchQueue.main.async {
                AppRouter.shared.latexInsert = nil
                if latex.texURL == nil { latex.newBlankDocument() }
                nav.selection = .latex
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { latex.send(.insert(text)) }
                ToastCenter.shared.show("Inséré dans le document LaTeX ✓")
            }
        }
        .onReceive(AppRouter.shared.$trainFor) { target in
            guard let target = target else { return }
            DispatchQueue.main.async {
                AppRouter.shared.trainFor = nil
                train(name: target.0, folder: target.1)
            }
        }
        .onReceive(AppRouter.shared.$incoming) { urls in
            guard !urls.isEmpty else { return }
            DispatchQueue.main.async {
                AppRouter.shared.incoming = []
                route(urls)
            }
        }
    }

    private func sidebarRow(_ tool: Tool) -> some View {
        NavigationLink(value: tool) {
            Label {
                Text(tool.title)
            } icon: {
                Image(systemName: tool.icon).foregroundStyle(tool.color)
            }
            .tourTarget("tool." + tool.rawValue)
        }
    }

    /// Une page qui vient d'être masquée (profil) : retour à l'accueil.
    private func leaveHiddenTool() {
        if let t = nav.selection, !profile.shows(t) { nav.selection = .home }
    }

    @ViewBuilder
    private func detail(_ tool: Tool) -> some View {
        switch tool {
        case .home:
            HomeView(home: home,
                     openTool: { nav.selection = $0 },
                     openFile: { route([$0]) },
                     newLatex: { latex.newDocument(); nav.selection = .latex })
        case .compare: CompareToolView(s: compare)
        case .courses: CoursesToolView(s: CoursesStore.shared)
        case .revisions: RevisionsToolView(r: RevisionsStore.shared)
        case .grades: GradesToolView(g: GradesStore.shared)
        case .calc: CalcToolView(s: CalcStore.shared)
        case .planning: PlanningToolView(p: PlanningStore.shared)
        case .headphone: HeadphoneToolView()
        case .sign: SignToolView(s: sign)
        case .organize: OrganizeToolView(model: organize)
        case .merge: MergeToolView(s: merge)
        case .split: SplitToolView()
        case .layout: LayoutToolView()
        case .compress: CompressToolView()
        case .ocr: OCRToolView()
        case .stamp: StampToolView()
        case .security: SecurityToolView()
        case .convert: ConvertToolView(s: convert)
        case .batch: BatchToolView()
        case .cleanup: CleanupToolView()
        case .annales: AnnalesToolView(s: annales)
        case .latex: LatexToolView(model: latex)
        }
    }

    /// « S'entraîner » : la matière correspondante dans Annalyse (même nom ou même dossier), sinon une recherche.
    private func train(name: String, folder: String) {
        let squash: (String) -> String = { CourseLibrary.fold($0).filter { $0.isLetter || $0.isNumber } }
        let targets = [squash(name), squash(folder)]
        nav.selection = .annales
        annales.tab = .banque
        if let m = annales.config?.matieres.first(where: { targets.contains(squash($0.key)) || targets.contains(squash($0.nom)) }) {
            annales.composeMatiere = m.key
            annales.composeNiveau = m.niveau
            annales.openCompose()
        } else {
            annales.searchText = name
            annales.search()
            ToastCenter.shared.show("Pas de matière « \(name) » dans Annalyse : je cherche par nom dans la banque.")
        }
    }

    /// Ce que propose la palette ⌘K (et ce qu'affiche le statut Discord).
    private func installPalette() {
        let nav = self.nav, latex = self.latex, home = self.home
        DiscordPresence.shared.provider = {
            DiscordPresence.text(for: nav.selection ?? .home, latex: latex, home: home,
                                 showFiles: DiscordPresence.shared.showFileNames)
        }
        DiscordPresence.shared.refresh(force: true)
        PaletteState.shared.provider = {
            var list: [PaletteCommand] = []
            list.append(PaletteCommand(title: "Nouveau document LaTeX", subtitle: "Éditeur intégré", icon: "square.and.pencil",
                                       color: .indigo, keywords: "tex creer nouveau") {
                latex.newDocument(); nav.selection = .latex
            })
            for m in [CalcMode.scientific, .programmer] {
                list.append(PaletteCommand(title: "Calculatrice \(m.title.lowercased())", subtitle: "Calculatrice", icon: m.icon, color: .teal,
                                           keywords: "calcul calculatrice " + (m == .programmer ? "hex binaire bits xor" : "sin cos racine")) {
                    CalcStore.shared.mode = m; nav.selection = .calc
                })
            }
            list.append(PaletteCommand(title: "Créer une archive (zip, tar.gz…)", subtitle: "Compresser & archiver", icon: "archivebox",
                                       color: .orange, keywords: "zip tar gz 7z archive compresser rendre tp") {
                ArchiveStore.shared.tab = .create; nav.selection = .compress
            })
            list.append(PaletteCommand(title: "Extraire une archive", subtitle: "Compresser & archiver", icon: "arrow.up.bin",
                                       color: .orange, keywords: "unzip decompresser extraire tar 7z rar") {
                ArchiveStore.shared.tab = .extract; nav.selection = .compress
            })
            if let current = nav.selection, TourStore.miniSteps(current) != nil {
                list.append(PaletteCommand(title: "Visite de cet outil", subtitle: current.title, icon: "magnifyingglass.circle",
                                           color: .green, keywords: "visite aide outil tutoriel") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { TourStore.shared.startMini(current) }
                })
            }
            list.append(PaletteCommand(title: "Mettre à jour Toolbox", subtitle: "git pull, compilation, réinstallation", icon: "arrow.down.circle",
                                       color: .blue, keywords: "update mise a jour recompiler build git pull") {
                UpdateStore.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { UpdateStore.shared.update() }
            })
            list.append(PaletteCommand(title: "Visite guidée", subtitle: "La Feuille te montre l'app avec sa loupe", icon: "magnifyingglass",
                                       color: .green, keywords: "visite guide aide tutoriel decouvrir") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { TourStore.shared.start() }
            })
            list.append(PaletteCommand(title: "Mes documents LaTeX", subtitle: "Rouvrir, modifier ou supprimer un TD, TP, cours, test…",
                                       icon: "doc.on.doc", color: .indigo, keywords: "tex documents ouvrir modifier supprimer corbeille td tp cours test") {
                nav.selection = .latex
                if latex.texURL != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LatexDocsStore.shared.showPopover = true }
                }
            })
            for d in LatexDocsStore.shared.docs.prefix(15) {
                list.append(PaletteCommand(title: d.title, subtitle: [d.kindTitle, d.matiere].filter { !$0.isEmpty }.joined(separator: " · "),
                                           icon: d.icon, color: .indigo, keywords: "tex latex " + d.url.lastPathComponent) {
                    nav.selection = .latex
                    if latex.texURL?.path != d.url.path { latex.open(d.url); latex.compile() }
                })
            }
            list.append(PaletteCommand(title: "Symboles & formules LaTeX", subtitle: "Ensembles, logique, limites, dérivées… prêts à coller",
                                       icon: "x.squareroot", color: .indigo,
                                       keywords: "symbole formule latex ensemble union inter appartient logique xor implique limite derivee integrale grec") {
                nav.selection = .latex
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LatexLibraryState.shared.show = true }
            })
            if latex.texURL != nil {
                list.append(PaletteCommand(title: "Compiler le LaTeX", subtitle: latex.texURL?.lastPathComponent ?? "",
                                           icon: "play.fill", color: .indigo, keywords: "compile pdf") {
                    nav.selection = .latex; latex.compile()
                })
            }
            list.append(PaletteCommand(title: "Capture d'écran → texte", subtitle: "Sélectionne une zone, le texte est copié",
                                       icon: "text.viewfinder", color: .teal, keywords: "ocr copier screenshot") {
                ScreenText.capture()
            })
            list.append(PaletteCommand(title: "Importer mon planning", subtitle: "Photo, capture ou PDF → Calendrier",
                                       icon: "fork.knife", color: .yellow, keywords: "mcdo travail shift horaires") {
                nav.selection = .planning; PlanningStore.shared.captureScreen()
            })
            for p in RevisionsStore.shared.upcoming {
                list.append(PaletteCommand(title: "Réviser : \(p.title)", subtitle: "\(RevisionsToolView.countdown(p.daysLeft)) · \(p.done)/\(p.tasks.count) fait",
                                           icon: "checklist", color: .mint, keywords: "revision cc examen partiel") {
                    RevisionsStore.shared.selectedID = p.id; nav.selection = .revisions
                })
            }
            let cm = ClassMode.shared
            list.append(PaletteCommand(title: cm.active ? "Désactiver le mode cours" : "Mode cours (iPhone en silence + casque)",
                                       subtitle: "Concentration sur le Mac et l'iPhone", icon: cm.active ? "bell.fill" : "bell.slash.fill",
                                       color: .red, keywords: "cours silence vibreur concentration focus ne pas deranger") { cm.toggle() })
            let hp = HeadphoneStore.shared
            if hp.connected {
                for (code, name) in [(UInt8(0x04), "réduction de bruit"), (HeadphoneStore.ancTransparency, "transparence"), (HeadphoneStore.ancOff, "désactiver la réduction de bruit")] {
                    list.append(PaletteCommand(title: "Casque : \(name)", subtitle: hp.last?.name ?? "Casque", icon: "headphones",
                                               color: .cyan, keywords: "casque anc bruit nothing transparence") { hp.setANC(code) })
                }
                for (code, name) in HeadphoneStore.eqPresets {
                    list.append(PaletteCommand(title: "Casque : égaliseur \(name.lowercased())", subtitle: hp.last?.name ?? "Casque", icon: "slider.vertical.3",
                                               color: .cyan, keywords: "casque eq egaliseur nothing") { hp.setEQ(code) })
                }
                list.append(PaletteCommand(title: hp.ringing ? "Casque : arrêter la sonnerie" : "Casque : faire sonner", subtitle: "Pour le retrouver",
                                           icon: "speaker.wave.3.fill", color: .cyan, keywords: "casque sonner retrouver ring") { hp.ring(!hp.ringing) })
            }
            list.append(PaletteCommand(title: "Ajouter une note", subtitle: "Notes & ECTS", icon: "chart.bar.doc.horizontal",
                                       color: .green, keywords: "moyenne ects cc partiel credits") { nav.selection = .grades })
            list.append(PaletteCommand(title: "Chercher dans mes cours", subtitle: "⌥Espace depuis n'importe quelle app",
                                       icon: "books.vertical.fill", color: .orange, keywords: "recherche contenu cours") {
                QuickSearchPanel.shared.open()
            })
            list.append(PaletteCommand(title: "Personnaliser l'accueil", icon: "slider.horizontal.3", color: .pink,
                                       keywords: "widgets accueil") {
                nav.selection = .home
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { home.layout.editing = true }
            })
            for tool in Tool.allCases where AppProfile.shared.shows(tool) {
                list.append(PaletteCommand(title: tool.title, subtitle: tool.subtitle, icon: tool.icon, color: tool.color,
                                           keywords: "outil " + tool.rawValue + " " + tool.section.rawValue + " " + tool.synonyms) {
                    nav.selection = tool
                })
            }
            let cs = CoursesStore.shared
            for c in cs.courses {
                list.append(PaletteCommand(title: cs.name(c), subtitle: "Mes cours · " + c.domain, icon: "books.vertical.fill",
                                           color: cs.color(c), keywords: "cours matiere " + c.folderName) {
                    cs.select(c); nav.selection = .courses
                })
                for session in c.sessions where session.number != nil && session.kind != .autre {
                    let target = session.items[0]
                    list.append(PaletteCommand(title: "\(session.title) · \(cs.name(c))", subtitle: session.subtitle.isEmpty ? target.url.lastPathComponent : session.subtitle,
                                               icon: FileBadge.style(target).0, color: cs.color(c),
                                               keywords: c.folderName + " " + target.url.lastPathComponent) {
                        cs.open(target)
                    })
                }
            }
            for app in AppShortcutsStore.shared.apps {
                list.append(PaletteCommand(title: "Ouvrir \(app.name)", subtitle: "Application", icon: "app.badge",
                                           color: .purple, keywords: "app lancer " + app.name) {
                    AppShortcutsStore.shared.launch(app)
                })
            }
            for f in home.codeFolders {
                list.append(PaletteCommand(title: f.url.lastPathComponent, subtitle: "Ouvrir dans VS Code Insiders",
                                           icon: "chevron.left.forwardslash.chevron.right", color: .blue,
                                           keywords: "code projet vscode " + f.url.path) { VSCode.open(f.url) })
            }
            for u in RecentFiles.list {
                list.append(PaletteCommand(title: u.lastPathComponent, subtitle: u.deletingLastPathComponent().path,
                                           icon: u.pathExtension == "tex" ? "function" : "doc.richtext", color: .gray,
                                           keywords: "recent fichier") { AppRouter.shared.incoming = [u] })
            }
            return list
        }
        PaletteState.shared.dynamicProvider = { query in
            var extra: [PaletteCommand] = []
            // petit calcul direct dans la palette : « 2^10 », « ln(2)*3 »…
            if query.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil,
               let node = try? MathEngine.parse(query), !node.containsX, !node.isNum,
               let v = try? MathEngine.evaluate(node, env: CalcStore.shared.env), v.isFinite {
                let shown = MathFormat.fr(v)
                extra.append(PaletteCommand(title: "= \(shown)", subtitle: "Calculatrice · Entrée pour copier le résultat",
                                            icon: "x.squareroot", color: .blue) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown, forType: .string)
                    ToastCenter.shared.show("\(shown) copié ✓")
                })
            }
            guard query.count >= 3 else { return extra }
            return extra + [PaletteCommand(title: "Créer la note « \(query) »", subtitle: "Dans l'app Notes", icon: "note.text",
                                   color: .orange) {
                runInBackground({ try AppleNotes.create(query) }) { r in
                    switch r {
                    case .success: ToastCenter.shared.show("Note créée dans Notes ✓")
                    case .failure(let e): ToastCenter.shared.show(e.localizedDescription)
                    }
                }
            }]
        }
    }

    /// Envoie les fichiers reçus vers l'outil le plus logique.
    private func route(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let texs = urls.filter { $0.pathExtension.lowercased() == "tex" }
        let images = urls.filter { FileDrop.accepts($0, [.image]) }
        pdfs.forEach(RecentFiles.add)
        if let tex = texs.first {
            latex.open(tex)
            nav.selection = .latex
        } else if pdfs.count == 1 {
            organize.open(pdfs[0])
            nav.selection = .organize
        } else if pdfs.count > 1 {
            merge.add(pdfs)
            nav.selection = .merge
        } else if !images.isEmpty {
            convert.mode = .imagesToPDF
            convert.addImages(images)
            nav.selection = .convert
        }
    }
}
