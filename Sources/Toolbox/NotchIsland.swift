import SwiftUI
import AppKit
import EventKit
import Combine
import PDFCore

// MARK: - Île dynamique (encoche)
//
// Une fenêtre transparente posée sur l'encoche, au-dessus de la barre des menus.
// • Au repos : invisible (elle se confond avec l'encoche), ou des « ailes » d'activité en direct
//   (minuteur, musique, cours en cours).
// • Au survol ou au clic : elle s'ouvre (musique, journée, batteries, actions rapides, étagère).
// • Alertes : elle s'ouvre seule quelques secondes (cours dans 5 min, casque connecté, branché…).
// • Fichiers glissés vers l'encoche : l'étagère s'ouvre pour les recevoir.
// La fenêtre ne prend la souris que quand le pointeur est sur la forme visible : partout ailleurs,
// les clics passent à la barre des menus et aux apps dessous.

// MARK: Réglages

final class NotchSettings: ObservableObject {
    static let shared = NotchSettings()
    private let d = UserDefaults.standard

    /// Activée par défaut sur un Mac à encoche.
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "notch.enabled"); NotchController.shared.apply() } }
    @Published var withoutNotch: Bool { didSet { d.set(withoutNotch, forKey: "notch.noNotch"); NotchController.shared.apply() } }
    @Published var openOnHover: Bool { didSet { d.set(openOnHover, forKey: "notch.hover") } }
    @Published var music: Bool { didSet { d.set(music, forKey: "notch.music"); MediaStore.shared.reschedule() } }
    @Published var live: Bool { didSet { d.set(live, forKey: "notch.live") } }
    @Published var alerts: Bool { didSet { d.set(alerts, forKey: "notch.alerts") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "notch.haptics") } }

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "notch.enabled") as? Bool ?? NotchGeometry.macHasNotch
        withoutNotch = d.bool(forKey: "notch.noNotch")
        openOnHover = d.object(forKey: "notch.hover") as? Bool ?? true
        music = d.object(forKey: "notch.music") as? Bool ?? true
        live = d.object(forKey: "notch.live") as? Bool ?? true
        alerts = d.object(forKey: "notch.alerts") as? Bool ?? true
        haptics = d.object(forKey: "notch.haptics") as? Bool ?? true
    }
}

// MARK: Géométrie

struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notch: CGSize          // taille de l'encoche (ou de la zone qui la remplace)
    var hasNotch: Bool

    static var macHasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }

    /// L'écran à encoche (intégré), sinon l'écran principal si autorisé.
    static func current(allowWithoutNotch: Bool) -> NotchGeometry? {
        if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            var w: CGFloat = 200
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
                w = s.frame.width - l.width - r.width
            }
            return NotchGeometry(screenFrame: s.frame, notch: CGSize(width: w, height: s.safeAreaInsets.top), hasNotch: true)
        }
        guard allowWithoutNotch, let s = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let bar = max(24, s.frame.maxY - s.visibleFrame.maxY)
        return NotchGeometry(screenFrame: s.frame, notch: CGSize(width: 190, height: bar), hasNotch: false)
    }
}

// MARK: Modèle

struct NotchAlert: Equatable {
    var icon: String
    var color: Color
    var title: String
    var subtitle: String = ""
    var progress: Double? = nil        // jauge (batterie…)
    /// Reste affichée jusqu'au clic (nouvelle note…) au lieu de disparaître toute seule.
    var sticky = false
    var id = UUID()
}

final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    enum Mode: Equatable { case idle, expanded, alert }

    @Published var mode: Mode = .idle
    @Published var tab = "home"                 // home | shelf
    @Published var alert: NotchAlert?
    @Published var pinned = false               // reste ouverte
    @Published var dropTargeting = false        // un fichier est tiré vers l'encoche
    @Published var geometry = NotchGeometry(screenFrame: .zero, notch: CGSize(width: 200, height: 32), hasNotch: true)
    @Published var hovering = false

    static let flare: CGFloat = 10                     // courbes du haut, de chaque côté
    static let expandedSize = CGSize(width: 660, height: 230)
    static let wing: CGFloat = 86

    /// Activité affichée de chaque côté de l'encoche au repos (minuteur, musique, cours).
    var liveActivity: LiveActivity? {
        guard NotchSettings.shared.live else { return nil }
        if let t = NotchTimer.shared.remaining, NotchTimer.shared.running { return .timer(t) }
        if let m = MediaStore.shared.now, m.playing { return .music(m) }
        if let c = DayInfo.shared.current { return .course(c.title, c.color, c.end) }
        return nil
    }

    enum LiveActivity: Equatable {
        case timer(TimeInterval)
        case music(NowPlaying)
        case course(String, Color, Date)
    }

    /// Taille de la forme noire (sans les courbes du haut).
    var bodySize: CGSize {
        let n = geometry.notch
        switch mode {
        case .expanded:
            return CGSize(width: max(Self.expandedSize.width, n.width + 40), height: Self.expandedSize.height + n.height)
        case .alert:
            return CGSize(width: max(n.width + 2 * 120, 380), height: n.height + 62)
        case .idle:
            if liveActivity != nil { return CGSize(width: n.width + 2 * Self.wing, height: n.height) }
            return hovering ? CGSize(width: n.width + 16, height: n.height + 4) : n
        }
    }

    /// Rectangle visible, en coordonnées écran (origine en bas à gauche).
    var screenRect: CGRect {
        let s = bodySize
        let w = s.width + 2 * Self.flare
        let f = geometry.screenFrame
        return CGRect(x: f.midX - w / 2, y: f.maxY - s.height, width: w, height: s.height)
    }

    /// Zone de l'encoche elle-même (pour le survol au repos).
    var notchRect: CGRect {
        let f = geometry.screenFrame, n = geometry.notch
        let extra: CGFloat = liveActivity != nil ? Self.wing : 0
        return CGRect(x: f.midX - n.width / 2 - extra - 4, y: f.maxY - n.height - 4, width: n.width + 2 * extra + 8, height: n.height + 4)
    }
}

// MARK: Fenêtre

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// macOS repousse toute fenêtre qui chevauche la barre des menus : pas celle-ci, elle doit coller à l'encoche.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: Contrôleur

final class NotchController: NSObject {
    static let shared = NotchController()

    private var panel: NotchPanel?
    private var monitors: [Any] = []
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var alertWork: DispatchWorkItem?
    private var dragCount = NSPasteboard(name: .drag).changeCount
    private var mouseDown = false
    private var cancellables = Set<AnyCancellable>()
    private var tick: Timer?
    private let events = EKEventStore()
    private var alerted = Set<String>()
    private var lastPlugged: Bool?
    private var lastHeadphone = false
    private var warnedBattery = Set<Int>()

    let model = NotchModel.shared
    static let windowSize = CGSize(width: 760, height: 320)

    // MARK: Marche / arrêt

    func apply() {
        let s = NotchSettings.shared
        guard s.enabled, let g = NotchGeometry.current(allowWithoutNotch: s.withoutNotch) else {
            stop()
            return
        }
        model.geometry = g
        if panel == nil { start() }
        place()
    }

    private func start() {
        let p = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.windowSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.acceptsMouseMovedEvents = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        // toutes les bureaux, mais pas les apps en plein écran (pas de .fullScreenAuxiliary)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchRootView())
        host.frame = CGRect(origin: .zero, size: Self.windowSize)
        p.contentView = host
        panel = p
        place()
        p.orderFrontRegardless()

        let handler: (NSEvent) -> Void = { [weak self] e in self?.mouse(e) }
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: types, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: types, handler: { e in handler(e); return e }) { monitors.append(l) }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        observe()
        tick = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.periodic() }
        MediaStore.shared.reschedule()
        periodic()
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        tick?.invalidate()
        tick = nil
        cancellables = []
        NotificationCenter.default.removeObserver(self)
        panel?.orderOut(nil)
        panel = nil
        model.mode = .idle
        MediaStore.shared.reschedule()
    }

    var isRunning: Bool { panel != nil }

    private func place() {
        guard let p = panel else { return }
        let f = model.geometry.screenFrame
        let s = Self.windowSize
        p.setFrame(CGRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height), display: true)
    }

    @objc private func screensChanged() {
        DispatchQueue.main.async { self.apply() }
    }

    // MARK: Souris

    private func mouse(_ e: NSEvent) {
        guard panel != nil else { return }
        let p = NSEvent.mouseLocation
        let visible = model.screenRect.insetBy(dx: -2, dy: -2)
        let overShape = visible.contains(p)
        panel?.ignoresMouseEvents = !(overShape || model.dropTargeting)

        switch e.type {
        case .leftMouseDown:
            mouseDown = true
            dragCount = NSPasteboard(name: .drag).changeCount
            if model.mode != .expanded, model.notchRect.contains(p) || overShape {
                open()
            }
        case .leftMouseUp:
            mouseDown = false
            if model.dropTargeting {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.model.dropTargeting = false
                    self?.scheduleCloseIfOutside()
                }
            }
        case .leftMouseDragged:
            // un fichier tiré vers l'encoche : l'étagère s'ouvre pour le recevoir
            let changed = NSPasteboard(name: .drag).changeCount != dragCount
            let f = model.geometry.screenFrame
            let near = abs(p.x - f.midX) < 260 && p.y > f.maxY - 140
            if changed, near, !model.dropTargeting {
                model.dropTargeting = true
                model.tab = "shelf"
                open(haptic: true)
                panel?.ignoresMouseEvents = false
            }
        default:
            break
        }

        // survol
        if model.mode == .expanded {
            if overShape || model.pinned || model.dropTargeting { closeWork?.cancel() } else { scheduleCloseIfOutside() }
        } else {
            let inNotch = model.notchRect.contains(p)
            if model.hovering != inNotch { model.hovering = inNotch }
            if inNotch, NotchSettings.shared.openOnHover, !mouseDown {
                if openWork == nil {
                    let w = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        self.openWork = nil
                        if self.model.notchRect.contains(NSEvent.mouseLocation) { self.open() }
                    }
                    openWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
                }
            } else {
                openWork?.cancel()
                openWork = nil
            }
        }
    }

    private func scheduleCloseIfOutside() {
        guard model.mode == .expanded, !model.pinned, !model.dropTargeting else { return }
        guard closeWork == nil || closeWork?.isCancelled == true else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.closeWork = nil
            if !self.model.screenRect.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation), !self.model.pinned, !self.model.dropTargeting {
                self.close()
            }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func open(haptic: Bool = true) {
        openWork?.cancel()
        openWork = nil
        alertWork?.cancel()
        guard model.mode != .expanded else { return }
        model.alert = nil
        model.mode = .expanded
        model.hovering = false
        DayInfo.shared.refresh()
        MediaStore.shared.refresh()
        if haptic, NotchSettings.shared.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        panel?.ignoresMouseEvents = false
    }

    func close() {
        closeWork?.cancel()
        closeWork = nil
        model.mode = .idle
        model.pinned = false
        model.dropTargeting = false
        panel?.ignoresMouseEvents = true
    }

    func toggle() { model.mode == .expanded ? close() : open() }

    // MARK: Alertes

    /// Ouvre l'île quelques secondes avec un message (si les alertes sont activées et qu'elle n'est pas déjà ouverte).
    func alert(_ a: NotchAlert, seconds: Double = 4) {
        guard isRunning, NotchSettings.shared.alerts, model.mode != .expanded else { return }
        // une alerte qui attend ton clic n'est pas écrasée par une alerte passagère
        if model.mode == .alert, model.alert?.sticky == true, !a.sticky { return }
        model.alert = a
        model.mode = .alert
        if NotchSettings.shared.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        alertWork?.cancel()
        alertWork = nil
        if a.sticky { return }           // reste jusqu'au clic
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.model.mode == .alert else { return }
            if self.model.screenRect.contains(NSEvent.mouseLocation) {
                self.alert(a, seconds: 2)      // pointeur dessus : on laisse le temps de lire
                return
            }
            self.model.mode = .idle
            self.model.alert = nil
        }
        alertWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// Ferme l'alerte affichée (clic sur une alerte qui reste).
    func dismissAlert() {
        alertWork?.cancel()
        alertWork = nil
        guard model.mode == .alert else { return }
        model.mode = .idle
        model.alert = nil
    }

    private func observe() {
        // branché / débranché, batterie faible
        MacStatusStore.shared.$battery.receive(on: DispatchQueue.main).sink { [weak self] b in
            guard let self = self, let b = b else { return }
            if let was = self.lastPlugged, was != b.plugged {
                if b.plugged {
                    self.alert(NotchAlert(icon: "bolt.fill", color: .green, title: L("En charge"), subtitle: "\(b.percent) %",
                                          progress: Double(b.percent) / 100), seconds: 3)
                } else {
                    self.alert(NotchAlert(icon: "battery.75", color: .white, title: L("Sur batterie"),
                                          subtitle: "\(b.percent) %" + (b.minutesLeft.map { " · " + Self.duration($0) } ?? ""),
                                          progress: Double(b.percent) / 100), seconds: 3)
                }
                self.warnedBattery = []
            }
            self.lastPlugged = b.plugged
            if !b.plugged {
                for level in [20, 10] where b.percent <= level && !self.warnedBattery.contains(level) {
                    self.warnedBattery.insert(level)
                    self.alert(NotchAlert(icon: "battery.25", color: .red, title: L("Batterie faible"),
                                          subtitle: "\(b.percent) % · " + L("pense à brancher le Mac"), progress: Double(b.percent) / 100), seconds: 5)
                }
            }
        }.store(in: &cancellables)

        // casque connecté (façon AirPods)
        HeadphoneStore.shared.$connected.receive(on: DispatchQueue.main).sink { [weak self] on in
            guard let self = self else { return }
            if on, !self.lastHeadphone, AppProfile.shared.hasHeadphone {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    let r = HeadphoneStore.shared.last
                    self.alert(NotchAlert(icon: "headphones", color: .white, title: r?.name ?? L("Casque connecté"),
                                          subtitle: r.map { "\($0.percent) %" + ($0.charging ? " ⚡" : "") } ?? L("Connecté"),
                                          progress: r.map { Double($0.percent) / 100 }), seconds: 4)
                }
            }
            self.lastHeadphone = on
        }.store(in: &cancellables)

        // la forme suit les activités (minuteur, musique)
        NotchTimer.shared.objectWillChange.merge(with: MediaStore.shared.objectWillChange)
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.model.objectWillChange.send() }
            .store(in: &cancellables)
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }

    /// Toutes les 20 s : cours qui commence bientôt, infos de la journée.
    private func periodic() {
        DayInfo.shared.refresh()
        model.objectWillChange.send()
        guard HomeStore.hasAccess, AppProfile.shared.student else { return }
        let now = Date()
        let list = CalendarFilter.shared.events(events, from: now, to: now.addingTimeInterval(6 * 60))
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(-30) }
            .sorted { $0.startDate < $1.startDate }
        guard let e = list.first else { return }
        let key = (e.eventIdentifier ?? e.title ?? "") + "\(e.startDate.timeIntervalSince1970)"
        guard !alerted.contains(key) else { return }
        alerted.insert(key)
        let mins = max(1, Int((e.startDate.timeIntervalSince(now) / 60).rounded()))
        let place = (e.location ?? "").trimmingCharacters(in: .whitespaces)
        alert(NotchAlert(icon: "graduationcap.fill", color: Color(nsColor: e.calendar?.color ?? .systemBlue),
                         title: DayInfo.shortTitle(e.title ?? ""),
                         subtitle: String(format: L("Dans %lld min"), mins) + (place.isEmpty ? "" : " · " + place)), seconds: 6)
    }
}

// MARK: - Infos de la journée (prochain cours, shift, CC)

final class DayInfo: ObservableObject {
    static let shared = DayInfo()
    private let store = EKEventStore()

    struct Next: Equatable {
        var title: String
        var start: Date
        var end: Date
        var place: String
        var color: Color
    }

    @Published var nextEvents: [Next] = []

    /// Événement en cours (commencé, pas fini).
    var current: Next? { nextEvents.first { $0.start <= Date() && $0.end > Date() } }
    /// Prochain événement pas encore commencé.
    var upcoming: Next? { nextEvents.first { $0.start > Date() } }

    /// « ANALYSE 1 - GUILLAUME Sophie - L1 INFO… » → « Analyse 1 »
    static func shortTitle(_ raw: String) -> String {
        let first = raw.components(separatedBy: " - ").first ?? raw
        let t = first.trimmingCharacters(in: .whitespaces)
        if t == t.uppercased(), t.count > 3 { return t.lowercased().prefix(1).uppercased() + t.lowercased().dropFirst() }
        return t
    }

    func refresh() {
        guard HomeStore.hasAccess else { nextEvents = []; return }
        let now = Date()
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86400 * 2)
        let found = CalendarFilter.shared.events(store, from: now, to: end)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        var seen = Set<String>()
        var out: [Next] = []
        for e in found {
            let title = Self.shortTitle(e.title ?? "")
            let key = CourseLibrary.fold(title) + "\(Int(e.startDate.timeIntervalSince1970))"
            guard seen.insert(key).inserted else { continue }       // même cours dans plusieurs calendriers
            out.append(Next(title: title, start: e.startDate, end: e.endDate, place: e.location ?? "",
                            color: Color(nsColor: e.calendar?.color ?? .systemBlue)))
            if out.count == 3 { break }
        }
        if out != nextEvents { nextEvents = out }
    }
}
