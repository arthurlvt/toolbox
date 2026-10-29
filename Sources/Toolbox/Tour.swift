import SwiftUI
import AppKit

// MARK: - Visite guidée : la Feuille promène sa loupe sur l'app

struct TourStep {
    let target: String?          // repère (.tourTarget) ; nil = bulle au centre
    let tool: Tool?              // page à afficher pendant l'étape
    let title: String
    let text: String
    var keys: [String] = []      // touches à montrer (⌘K…)
    var fallback: String? = nil  // repère de secours si le premier n'est pas à l'écran
}

final class TourStore: ObservableObject {
    static let shared = TourStore()

    @Published private(set) var active = false
    @Published private(set) var index = 0
    @Published private(set) var snapshot: NSImage?
    @Published private(set) var hidden = false         // le temps d'une capture d'écran
    @Published private(set) var tick = 0                // un repère a bougé
    @Published private(set) var startedAt = Date()
    private(set) var steps: [TourStep] = []
    /// mini-visite d'un outil en cours (nil = grande visite)
    @Published private(set) var mini: Tool?
    @Published var miniEnabled = UserDefaults.standard.object(forKey: "tour.mini") as? Bool ?? true {
        didSet { UserDefaults.standard.set(miniEnabled, forKey: "tour.mini") }
    }
    private var seen = Set(UserDefaults.standard.stringArray(forKey: "tour.mini.seen") ?? [])
    private(set) var frames: [String: CGRect] = [:]
    private var captureToken = 0

    var step: TourStep? { active && index < steps.count ? steps[index] : nil }
    var isLast: Bool { index == steps.count - 1 }

    // MARK: Repères

    func setFrame(_ id: String, _ rect: CGRect?) {
        if let r = rect { frames[id] = r } else { frames[id] = nil }
        if active { tick &+= 1 }
    }

    func rect(for s: TourStep) -> CGRect? {
        for id in [s.target, s.fallback].compactMap({ $0 }) {
            if let r = frames[id], r.width > 4, r.height > 4 { return r }
        }
        return nil
    }

    // MARK: Parcours

    static func buildSteps() -> [TourStep] {
        let p = AppProfile.shared
        let name = UserProfile.firstName
        var s: [TourStep] = [
            TourStep(target: nil, tool: .home, title: "Petite visite\(name.isEmpty ? "" : ", \(name)") ? 🔍",
                     text: "J'ai sorti ma loupe : je te montre en une minute où se trouve tout ce qui compte. Entrée pour avancer, Échap pour arrêter."),
            TourStep(target: "sidebar", tool: .home, title: "Tous les outils",
                     text: "Ils sont rangés par thème dans cette barre : études, quotidien, PDF, LaTeX… Ce qui ne te sert pas est masqué (Réglages → Mon profil)."),
            TourStep(target: "home.widgets", tool: .home, title: "L'accueil",
                     text: "Des widgets : tes apps, l'agenda du jour, la météo, tes appareils… Chacun se déplace par sa poignée en haut."),
            TourStep(target: "home.customize", tool: .home, title: "Personnaliser",
                     text: "Ajoute ou retire des widgets, change leur largeur, et installe les widgets sur ton iPhone.", fallback: "home.widgets"),
            TourStep(target: nil, tool: .home, title: "Le raccourci à retenir",
                     text: "⌘K ouvre la palette : tous les outils, tes cours, tes documents LaTeX, les calculatrices… tape quelques lettres et Entrée.",
                     keys: ["⌘", "K"]),
        ]
        if p.student {
            s += [
                TourStep(target: "tool.courses", tool: .courses, title: "Mes cours",
                         text: "Tes cours rangés par matière : TD, TP, chapitres, annales. ⌥Espace cherche dedans depuis n'importe quelle app."),
                TourStep(target: "tool.revisions", tool: .revisions, title: "Révisions",
                         text: "Le prochain CC est repris de ton calendrier, avec une checklist reliée à tes cours et tes TD."),
                TourStep(target: "tool.grades", tool: .grades, title: "Notes & ECTS",
                         text: "Tes UE, leurs matières et tes notes : la moyenne qu'il te faut au prochain CC et les crédits acquis."),
            ]
        }
        if p.worker {
            s.append(TourStep(target: "tool.planning", tool: .planning, title: "Planning",
                              text: "Prends ton planning en photo : je lis tes horaires et tes pauses, je les mets dans ton calendrier et je te préviens si ça tombe sur un CC."))
        }
        s += [
            TourStep(target: "latex.new", tool: .latex, title: "LaTeX",
                     text: "Nouveau document : TD, TP, cours, test hebdo, rapport… ou « Autre » avec l'IA qui prépare un modèle sur mesure.",
                     fallback: "tool.latex"),
            TourStep(target: "latex.symbols", tool: .latex, title: "Symboles & formules",
                     text: "Plus de 230 symboles et formules prêts à coller (ensembles, logique, limites…), ⇧⌘M. « Mes documents » (⇧⌘O) rouvre ou supprime tes fichiers.",
                     fallback: "tool.latex"),
            TourStep(target: "calc.modes", tool: .calc, title: "Calculatrice",
                     text: "Trois en une : graphique (courbes, limites, dérivées, export LaTeX), scientifique et programmeur (bases, bits).",
                     fallback: "tool.calc"),
            TourStep(target: "compress.tabs", tool: .compress, title: "Compresser & archiver",
                     text: "Allège tes PDF, crée un .zip ou un .tar.gz « prêt à rendre » pour un TP, ou ouvre une archive.",
                     fallback: "tool.compress"),
        ]
        if p.hasHeadphone {
            s.append(TourStep(target: "tool.headphone", tool: .headphone, title: "Ton casque",
                              text: "Batterie, réduction de bruit, égaliseur, et le Mode cours qui coupe tout pendant tes cours."))
        }
        s.append(TourStep(target: nil, tool: .home, title: "À toi de jouer ! 🎉",
                          text: "⌘, ouvre les réglages : profil, outils à installer, IA locale… et cette visite se relance depuis ⌘K → « Visite guidée ».",
                          keys: ["⌘", ","]))
        return s
    }

    func start() {
        mini = nil
        steps = Self.buildSteps()
        index = 0
        startedAt = Date()
        withAnimation(.easeInOut(duration: 0.3)) { active = true }
        show()
    }

    func next() {
        guard active else { return }
        if isLast { stop(); return }
        go(index + 1)
    }

    func back() {
        guard active, index > 0 else { return }
        go(index - 1)
    }

    private func go(_ i: Int) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { index = i }
        show()
    }

    func stop() {
        if mini == nil {
            UserDefaults.standard.set(true, forKey: "tour.done")
            if isLast { ToastCenter.shared.show("Bonne découverte ! 🍃", cheer: true) }
        }
        withAnimation(.easeInOut(duration: 0.3)) { active = false }
        snapshot = nil
        mini = nil
    }

    // MARK: Mini-visites (la première fois qu'on ouvre un outil)

    func toolOpened(_ tool: Tool) {
        guard miniEnabled, !active, !seen.contains(tool.rawValue), Self.miniSteps(tool) != nil,
              UserDefaults.standard.bool(forKey: "onboarding.done"), !OnboardingState.shared.shown else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self, !self.active, AppRouterSelection.current == tool else { return }
            self.startMini(tool)
        }
    }

    func startMini(_ tool: Tool) {
        guard let list = Self.miniSteps(tool) else { return }
        seen.insert(tool.rawValue)
        UserDefaults.standard.set(Array(seen), forKey: "tour.mini.seen")
        mini = tool
        steps = list
        index = 0
        startedAt = Date()
        withAnimation(.easeInOut(duration: 0.3)) { active = true }
        show()
    }

    func resetMini() {
        seen = []
        UserDefaults.standard.set([String](), forKey: "tour.mini.seen")
    }

    static func miniSteps(_ tool: Tool) -> [TourStep]? {
        func st(_ target: String, _ title: String, _ text: String, fallback: String? = "detail") -> TourStep {
            TourStep(target: target, tool: nil, title: title, text: text, fallback: fallback)
        }
        switch tool {
        case .courses:
            return [st("courses.subjects", "Tes matières", "Une ligne par dossier de cours, rangées par domaine. Clic droit : nom, couleur, autres noms pour le calendrier."),
                    st("courses.search", "Chercher partout", "Dans les noms ET le contenu des PDF. ⌥Espace fait la même chose depuis n'importe quelle app."),
                    st("courses.middle", "Séances", "Chaque TD, TP et chapitre, avec « Nouveau TP » qui crée le dossier suivant et l'ouvre dans VS Code."),
                    st("courses.preview", "Aperçu", "Le fichier choisi s'affiche ici, sans quitter l'app.")]
        case .revisions:
            return [st("revisions.next", "Le prochain CC", "Repris de ton calendrier (catégorie CCs/Soutenance), avec le rythme à tenir pour être prêt."),
                    st("detail", "La checklist", "Coche les cours, TD et annales revus : la barre de progression avance.", fallback: nil)]
        case .grades:
            return [st("grades.toolbar", "Années et maquette", "Menu « Année » : nouvelle année, report des UE validées, maquette L1 Informatique. « Règles » : compensation, rattrapage."),
                    st("grades.summary", "Le bilan", "Moyennes, anneau des crédits ECTS et la note qu'il te faut sur ce qui reste."),
                    st("grades.simulate", "Simulation", "Tape des notes imaginaires (en violet) pour voir ce que ça donnerait, sans toucher aux vraies.")]
        case .planning:
            return [st("planning.import", "Importer le planning", "Photo, capture d'écran ou collage : je lis tes horaires et tes pauses, puis je les mets dans ton calendrier."),
                    st("detail", "Ta semaine", "Heures payées, pauses, et une alerte si un shift tombe sur un cours ou un CC.", fallback: nil)]
        case .latex:
            return [st("latex.new", "Nouveau document", "TD, TP, cours, test hebdo, rapport… ou « Autre » pour que l'IA prépare un modèle sur mesure.", fallback: "latex.compile"),
                    st("latex.docs", "Mes documents", "Tout ce que tu as créé : double-clic pour reprendre, corbeille pour supprimer (⇧⌘O)."),
                    st("latex.symbols", "Symboles & formules", "Ensembles, logique, limites, dérivées… un clic les insère au curseur (⇧⌘M).")]
        case .calc:
            return [st("calc.modes", "Trois calculatrices", "Graphique pour les fonctions, scientifique comme sur le Mac, programmeur pour les bases et les bits."),
                    st("calc.content", "À toi", "En graphique : tape f(x) = …, le bouton TeX convertit en LaTeX. En scientifique : tape directement, Entrée calcule.")]
        case .compress:
            return [st("compress.tabs", "Trois onglets", "Compresser des PDF, créer une archive (« Prêt à rendre » pour un TP), ou ouvrir et extraire une archive."),
                    st("detail", "Glisse tes fichiers", "Les originaux ne sont jamais modifiés : le résultat est créé à côté.", fallback: nil)]
        case .headphone:
            return [st("headphone.panel", "Ton casque", "Batterie, réduction de bruit, égaliseur, basses, faible latence et « Faire sonner »."),
                    st("headphone.classmode", "Mode cours", "Concentration sur le Mac et l'iPhone + casque coupé, tout seul au début de chaque cours si tu veux.")]
        default:
            return nil
        }
    }

    private func show() {
        guard let s = step else { return }
        if let t = s.tool { AppRouter.shared.show = t }
        captureToken += 1
        let token = captureToken
        // la page a le temps de s'afficher, puis on la photographie pour l'effet loupe
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self, self.captureToken == token, self.active else { return }
            self.capture(token)
        }
    }

    private func capture(_ token: Int) {
        hidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self = self else { return }
            defer { self.hidden = false }
            guard self.captureToken == token,
                  let view = (NSApp.mainWindow ?? NSApp.keyWindow)?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let img = NSImage(size: view.bounds.size)
            img.addRepresentation(rep)
            self.snapshot = img
        }
    }
}

// MARK: - Repères

extension View {
    /// Marque une zone que la visite guidée peut montrer.
    func tourTarget(_ id: String) -> some View {
        background(
            GeometryReader { g in
                Color.clear
                    .onAppear { TourStore.shared.setFrame(id, g.frame(in: .global)) }
                    .onChange(of: g.frame(in: .global)) { TourStore.shared.setFrame(id, $0) }
                    .onDisappear { TourStore.shared.setFrame(id, nil) }
            }
        )
    }
}

// MARK: - Calque de la visite

struct TourOverlay: View {
    @ObservedObject var t = TourStore.shared

    var body: some View {
        if t.active, let step = t.step {
            GeometryReader { g in
                let origin = g.frame(in: .global).origin
                let size = g.size
                let target = t.rect(for: step).map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                let _ = t.tick
                ZStack(alignment: .topLeading) {
                    dim(size: size, hole: target)
                    if let r = target {
                        let lens = Self.lens(for: r)
                        let group = Self.place(lens: lens, size: size)
                        loupe(lens: lens, size: size, origin: origin, mascot: group.mascot)
                        bubbleGroup(step, group: group)
                    } else {
                        bubbleGroup(step, group: Self.centered(size: size))
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .opacity(t.hidden ? 0 : 1)
            .transition(.opacity)
        }
    }

    // MARK: Géométrie

    struct Lens { var center: CGPoint; var radius: CGFloat; var zoom: CGFloat; var target: CGRect }
    struct Group { var origin: CGPoint; var mascotFirst: Bool; var mascot: CGPoint }

    static let groupSize = CGSize(width: 440, height: 190)

    static func lens(for r: CGRect) -> Lens {
        let big = r.width > 360 || r.height > 300
        if big {
            // grande zone : la loupe se pose sur son coin haut-gauche (le titre)
            let c = CGPoint(x: r.minX + min(130, r.width / 3), y: r.minY + min(70, r.height / 3))
            return Lens(center: c, radius: 78, zoom: 1.45, target: r)
        }
        let radius = min(110, max(46, max(r.width, r.height) / 2 + 22))
        return Lens(center: CGPoint(x: r.midX, y: r.midY), radius: radius, zoom: 1.6, target: r)
    }

    static func place(lens l: Lens, size: CGSize) -> Group {
        let w = groupSize.width, h = groupSize.height, m: CGFloat = 16
        let c = l.center, r = l.radius
        let candidates: [(CGPoint, Bool)] = [
            (CGPoint(x: c.x + r + 24, y: c.y - 50), true),             // à droite, la Feuille côté loupe
            (CGPoint(x: c.x - r - 24 - w, y: c.y - 50), false),        // à gauche
            (CGPoint(x: c.x - w / 2, y: c.y + r + 24), true),          // dessous
            (CGPoint(x: c.x - w / 2, y: c.y - r - 24 - h), true),      // dessus
        ]
        func fits(_ o: CGPoint) -> Bool {
            o.x >= m && o.y >= m && o.x + w <= size.width - m && o.y + h <= size.height - m
        }
        let chosen = candidates.first { fits($0.0) } ?? candidates[0]
        let o = CGPoint(x: min(max(m, chosen.0.x), max(m, size.width - w - m)),
                        y: min(max(m, chosen.0.y), max(m, size.height - h - m)))
        let mascot = chosen.1 ? CGPoint(x: o.x + 60, y: o.y + 80) : CGPoint(x: o.x + w - 60, y: o.y + 80)
        return Group(origin: o, mascotFirst: chosen.1, mascot: mascot)
    }

    static func centered(size: CGSize) -> Group {
        let o = CGPoint(x: (size.width - groupSize.width) / 2, y: (size.height - groupSize.height) / 2 - 20)
        return Group(origin: o, mascotFirst: true, mascot: CGPoint(x: o.x + 60, y: o.y + 80))
    }

    // MARK: Dessin

    private func dim(size: CGSize, hole: CGRect?) -> some View {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            if let h = hole { p.addRoundedRect(in: h.insetBy(dx: -8, dy: -8), cornerSize: CGSize(width: 12, height: 12)) }
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .overlay {
            if let h = hole {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: h.width + 16, height: h.height + 16)
                    .position(x: h.midX, y: h.midY)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { t.next() }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: hole)
    }

    private func loupe(lens l: Lens, size: CGSize, origin: CGPoint, mascot: CGPoint) -> some View {
        let dx = mascot.x - l.center.x, dy = mascot.y - l.center.y
        let dist = max(1, (dx * dx + dy * dy).squareRoot())
        let ux = dx / dist, uy = dy / dist
        let start = CGPoint(x: l.center.x + ux * (l.radius + 2), y: l.center.y + uy * (l.radius + 2))
        let len = min(70, max(24, dist - l.radius - 55))
        let end = CGPoint(x: start.x + ux * len, y: start.y + uy * len)
        return ZStack(alignment: .topLeading) {
            // manche
            Path { p in p.move(to: start); p.addLine(to: end) }
                .stroke(LinearGradient(colors: [Color(red: 0.55, green: 0.33, blue: 0.18), Color(red: 0.38, green: 0.22, blue: 0.12)],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 13, lineCap: .round))
            // verre : la vraie page, grossie
            if let img = t.snapshot {
                // la capture couvre toute la fenêtre : on la recale sur ce calque, puis on grossit autour du centre
                let w = max(1, img.size.width), h = max(1, img.size.height)
                Image(nsImage: img)
                    .resizable()
                    .frame(width: w, height: h)
                    .scaleEffect(l.zoom, anchor: UnitPoint(x: (l.center.x + origin.x) / w, y: (l.center.y + origin.y) / h))
                    .offset(x: -origin.x, y: -origin.y)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipped()
                    .mask(Circle().frame(width: l.radius * 2, height: l.radius * 2).position(l.center))
                    .transition(.opacity)
            } else {
                Circle().fill(Color.white.opacity(0.08))
                    .frame(width: l.radius * 2, height: l.radius * 2).position(l.center)
            }
            // reflet et monture
            Circle()
                .fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .center))
                .frame(width: l.radius * 2, height: l.radius * 2).position(l.center)
                .allowsHitTesting(false)
            Circle()
                .stroke(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 7)
                .frame(width: l.radius * 2 + 7, height: l.radius * 2 + 7).position(l.center)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: l.center)
    }

    private func bubbleGroup(_ s: TourStep, group: Group) -> some View {
        let party = t.isLast && t.mini == nil
        let mascotView = FeuilleMascot(mood: party ? .party : .normal, poke: party ? t.startedAt : nil)
            .frame(width: 120, height: 106)
        return HStack(alignment: .center, spacing: 6) {
            if group.mascotFirst { mascotView }
            bubble(s)
            if !group.mascotFirst { mascotView }
        }
        .frame(width: Self.groupSize.width, height: Self.groupSize.height)
        .offset(x: group.origin.x, y: group.origin.y)
        .animation(.spring(response: 0.6, dampingFraction: 0.82), value: group.origin)
    }

    private func bubble(_ s: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.title).font(.system(size: 17, weight: .bold, design: .rounded))
            Text(s.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !s.keys.isEmpty {
                HStack(spacing: 5) {
                    ForEach(s.keys, id: \.self) { k in
                        Text(k).font(.system(size: 16, weight: .semibold, design: .rounded))
                            .frame(minWidth: 30, minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.2)))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<t.steps.count, id: \.self) { i in
                        Capsule().fill(i == t.index ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: i == t.index ? 14 : 5, height: 5)
                    }
                }
                Spacer()
                if !t.isLast {
                    Button("Passer") { t.stop() }
                        .buttonStyle(.borderless).font(.caption)
                        .keyboardShortcut(.cancelAction)
                }
                if t.index > 0 {
                    Button { t.back() } label: { Image(systemName: "chevron.left") }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Button(t.isLast ? (t.mini == nil ? "Terminer" : "Compris") : (t.index == 0 && t.mini == nil ? "C'est parti" : "Suivant")) { t.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300, height: 176, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }
}

/// Outil affiché en ce moment (pour ne pas lancer une mini-visite si on a déjà changé de page).
enum AppRouterSelection {
    static var current: Tool?
}

struct TourMiniSettings: View {
    @ObservedObject var t = TourStore.shared

    var body: some View {
        Toggle("Petite visite la première fois que j'ouvre un outil", isOn: $t.miniEnabled)
        Button("Revoir les petites visites des outils") {
            t.resetMini()
            ToastCenter.shared.show("Les petites visites se relanceront à l'ouverture de chaque outil ✓")
        }
    }
}
