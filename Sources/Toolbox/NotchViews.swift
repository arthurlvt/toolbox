import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Forme de l'encoche

/// Rectangle aux coins du bas arrondis, avec les deux petites courbes du haut qui épousent la barre des menus.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = min(top, r.width / 4), b = min(bottom, r.height / 2, (r.width - 2 * t) / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Racine

struct NotchRootView: View {
    @ObservedObject var m = NotchModel.shared
    @ObservedObject var timer = NotchTimer.shared
    @ObservedObject var media = MediaStore.shared
    @ObservedObject var shelf = ShelfStore.shared

    private var size: CGSize { m.bodySize }
    private var bottomRadius: CGFloat {
        switch m.mode {
        case .expanded: return 30
        case .alert: return 22
        case .idle: return m.liveActivity != nil ? 12 : 9
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(top: NotchModel.flare, bottom: bottomRadius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(m.mode == .idle ? 0 : 0.45), radius: 14, y: 6)
                content
                    .padding(.horizontal, NotchModel.flare)
                    .clipShape(NotchShape(top: NotchModel.flare, bottom: bottomRadius))
            }
            .frame(width: size.width + 2 * NotchModel.flare, height: size.height)
            .opacity(!m.geometry.hasNotch && m.mode == .idle && m.liveActivity == nil && !m.hovering ? 0 : 1)
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { m.dropTargeting }, set: { v in if v { m.dropTargeting = true } })) { providers in
                FileDrop.load(providers) { urls in
                    ShelfStore.shared.add(urls)
                    NotchController.shared.open()
                    m.dropTargeting = false
                }
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.windowSize.width, height: NotchController.windowSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: m.mode)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: size)
    }

    @ViewBuilder
    private var content: some View {
        switch m.mode {
        case .expanded:
            ExpandedIsland()
                .padding(.top, m.geometry.notch.height)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .alert:
            if let a = m.alert { AlertIsland(alert: a, notchHeight: m.geometry.notch.height).transition(.opacity) }
        case .idle:
            if let live = m.liveActivity {
                LiveWings(activity: live, notchWidth: m.geometry.notch.width, height: m.geometry.notch.height)
                    .transition(.opacity)
                    .onTapGesture { NotchController.shared.open() }
            }
        }
    }
}

// MARK: - Ailes (activité en direct au repos)

struct LiveWings: View {
    let activity: NotchModel.LiveActivity
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: NotchModel.wing, alignment: .leading).padding(.leading, 10)
            Spacer(minLength: notchWidth - 20)
            right.frame(width: NotchModel.wing, alignment: .trailing).padding(.trailing, 10)
        }
        .frame(height: height)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
    }

    @ViewBuilder private var left: some View {
        switch activity {
        case .timer:
            Image(systemName: "timer").foregroundStyle(.orange)
        case .music(let n):
            Artwork(image: n.artwork, size: height - 12, radius: 5)
        case .course(let title, let color, _):
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var right: some View {
        switch activity {
        case .timer(let t):
            Text(NotchTimer.format(t)).monospacedDigit().foregroundStyle(.orange)
        case .music:
            Equalizer(color: .green, playing: true).frame(width: 18, height: 12)
        case .course(_, _, let end):
            Text("−" + NotchController.duration(max(1, Int(end.timeIntervalSinceNow / 60)))).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Barres animées « en lecture ».
struct Equalizer: View {
    let color: Color
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = playing ? 0.35 + 0.65 * abs(sin(t * (3.1 + Double(i) * 0.9) + Double(i))) : 0.3
                    Capsule().fill(color).frame(width: 2.5).frame(maxHeight: .infinity).scaleEffect(y: h, anchor: .center)
                }
            }
        }
    }
}

struct Artwork: View {
    let image: NSImage?
    var size: CGFloat
    var radius: CGFloat = 8

    var body: some View {
        Group {
            if let i = image {
                Image(nsImage: i).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

// MARK: - Alerte

struct AlertIsland: View {
    let alert: NotchAlert
    let notchHeight: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(alert.color.opacity(0.22))
                Image(systemName: alert.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(alert.color)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if !alert.subtitle.isEmpty {
                    Text(alert.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let p = alert.progress {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 3.5)
                    Circle().trim(from: 0, to: p).stroke(p <= 0.2 ? Color.red : alert.color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 28, height: 28)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, notchHeight + 6)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture { NotchController.shared.open() }
    }
}

// MARK: - Île ouverte

struct ExpandedIsland: View {
    @ObservedObject var m = NotchModel.shared
    @ObservedObject var shelf = ShelfStore.shared

    var body: some View {
        VStack(spacing: 10) {
            header
            if m.tab == "shelf" || m.dropTargeting {
                ShelfPane()
            } else {
                HomePane()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 6) {
            tabButton("home", L("Accueil"), "square.grid.2x2.fill")
            tabButton("shelf", shelf.items.isEmpty ? L("Étagère") : L("Étagère") + " · \(shelf.items.count)", "tray.full.fill")
            Spacer()
            Text(Date(), style: .time).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            iconButton(m.pinned ? "pin.fill" : "pin", help: m.pinned ? L("Ne plus garder ouverte") : L("Garder ouverte")) {
                m.pinned.toggle()
            }
            iconButton("gearshape", help: L("Réglages de l'île")) {
                NotchController.shared.close()
                UpdateStore.openSettings()
            }
            iconButton("macwindow", help: L("Ouvrir Toolbox")) {
                NotchController.shared.close()
                AppRouter.showMainWindow()
            }
        }
    }

    private func tabButton(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { m.tab = id } } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(m.tab == id ? Color.white.opacity(0.16) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Carte sombre arrondie.
struct IslandCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.07)))
    }
}

// MARK: Accueil

struct HomePane: View {
    @ObservedObject var media = MediaStore.shared
    @ObservedObject var day = DayInfo.shared
    @ObservedObject var mac = MacStatusStore.shared
    @ObservedObject var phones = PhoneStatusStore.shared
    @ObservedObject var buds = HeadphoneStore.shared
    @ObservedObject var timer = NotchTimer.shared
    @ObservedObject var profile = AppProfile.shared
    @ObservedObject var revisions = RevisionsStore.shared

    var body: some View {
        HStack(spacing: 10) {
            if let n = media.now, NotchSettings.shared.music {
                IslandCard { MusicCard(n: n) }.frame(width: 230)
            } else {
                IslandCard { DateCard() }.frame(width: 150)
            }
            IslandCard { dayCard }
            VStack(spacing: 10) {
                IslandCard { batteries }
                IslandCard { actions }
            }
            .frame(width: 168)
        }
        .frame(height: 170)
    }

    // MARK: Journée

    private var dayCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let c = day.current {
                eventRow(c, now: true)
            }
            if let u = day.upcoming {
                eventRow(u, now: false)
            }
            if day.current == nil && day.upcoming == nil {
                Label(HomeStore.hasAccess ? L("Rien de prévu aujourd'hui.") : L("Autorise l'accès au Calendrier dans Toolbox."),
                      systemImage: "sun.max.fill")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            if profile.worker, let s = PlanningStore.shared.next {
                infoLine(icon: "fork.knife", color: .yellow, text: L("Shift") + " " + Self.when(s.start) + " → " + Self.hour(s.end))
            }
            if profile.student, let r = revisions.next, let d = r.date {
                let days = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                                  to: Calendar.current.startOfDay(for: d)).day ?? 0)
                HStack(spacing: 6) {
                    infoLine(icon: "checklist", color: .pink,
                             text: DayInfo.shortTitle(r.title) + " · " + (days == 0 ? L("aujourd'hui") : "J-\(days)"))
                    Spacer(minLength: 0)
                    ProgressView(value: r.progress).progressViewStyle(.linear).tint(.pink).frame(width: 46)
                }
            }
        }
    }

    private func eventRow(_ e: DayInfo.Next, now: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(e.color).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if now {
                        Text(L("En cours") + " · " + L("fin") + " " + Self.hour(e.end)).foregroundStyle(e.color)
                    } else {
                        Text(Self.when(e.start)).foregroundStyle(.white.opacity(0.75))
                    }
                    if !e.place.isEmpty {
                        Text("· " + e.place).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                if now {
                    ProgressView(value: min(1, max(0, Date().timeIntervalSince(e.start) / max(60, e.end.timeIntervalSince(e.start)))))
                        .progressViewStyle(.linear).tint(e.color).frame(maxWidth: 160)
                }
            }
        }
    }

    private func infoLine(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 14)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .medium))
    }

    static func hour(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// « dans 25 min », « 14:30 », « demain 8:30 »
    static func when(_ d: Date) -> String {
        let mins = Int(d.timeIntervalSinceNow / 60)
        if mins < 60 { return String(format: L("dans %lld min"), max(1, mins)) }
        if Calendar.current.isDateInToday(d) { return hour(d) }
        if Calendar.current.isDateInTomorrow(d) { return L("demain") + " " + hour(d) }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEE HH:mm"
        return f.string(from: d)
    }

    // MARK: Batteries

    private var batteries: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let b = mac.battery {
                batteryRow(icon: "laptopcomputer", percent: b.percent, charging: b.charging || b.plugged)
            }
            if profile.hasHeadphone, let r = buds.last, Date().timeIntervalSince(r.date) < 6 * 3600 {
                batteryRow(icon: "headphones", percent: r.percent, charging: r.charging, dim: !buds.connected)
            }
            if profile.hasPhone, let p = phones.info, Date().timeIntervalSince(p.updated) < 6 * 3600 {
                batteryRow(icon: "iphone", percent: p.battery, charging: p.charging)
            }
            if mac.battery == nil {
                Text(L("Mac sur secteur")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func batteryRow(icon: String, percent: Int, charging: Bool, dim: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 18)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(percent <= 20 ? Color.red : (charging ? Color.green : Color.white))
                    .frame(width: 54 * CGFloat(max(4, min(100, percent))) / 100)
            }
            .frame(width: 54, height: 7)
            Text("\(percent)%").font(.system(size: 11, weight: .semibold)).monospacedDigit()
            if charging { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green) }
        }
        .font(.system(size: 11))
        .opacity(dim ? 0.5 : 1)
    }

    // MARK: Actions rapides

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            quick("eyedropper", L("Pipette")) {
                NotchController.shared.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { ColorStore.shared.pick(copy: true) }
            }
            quick("text.viewfinder", L("Lire l'écran")) {
                NotchController.shared.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ScreenText.capture() }
            }
            if timer.running {
                quick(timer.pausedRemaining == nil ? "pause.fill" : "play.fill",
                      NotchTimer.format(timer.remaining ?? 0), tint: .orange) { timer.togglePause() }
                    .contextMenu { Button(L("Arrêter le minuteur")) { timer.stop() } }
            } else {
                quick("timer", L("Minuteur")) { TimerMenu.show() }
            }
            quick("doc.on.clipboard", L("Historique")) {
                NotchController.shared.close()
                AppRouter.shared.show = .clip
                AppRouter.showMainWindow()
            }
        }
    }

    private func quick(_ icon: String, _ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75).monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// Menu du minuteur, ouvert sous le pointeur (un Menu SwiftUI n'a pas le même style que les autres boutons).
enum TimerMenu {
    final class Item: NSMenuItem {
        var run: () -> Void = {}
        @objc func fire() { run() }
    }

    static func show() {
        let menu = NSMenu()
        for p in NotchTimer.presets {
            let it = Item(title: "\(p.0) min · " + L(p.1), action: #selector(Item.fire), keyEquivalent: "")
            it.target = it
            it.run = { NotchTimer.shared.start(minutes: p.0, label: p.1) }
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

struct DateCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date(), format: .dateTime.weekday(.wide)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red).textCase(.uppercase)
            Text(Date(), format: .dateTime.day()).font(.system(size: 44, weight: .bold, design: .rounded))
            Text(Date(), format: .dateTime.month(.wide)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
        }
    }
}

struct MusicCard: View {
    let n: NowPlaying
    @ObservedObject var media = MediaStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Artwork(image: n.artwork, size: 58, radius: 10)
                    .onTapGesture { media.openPlayer() }
                    .help(L("Ouvrir") + " " + (n.app == "Music" ? "Musique" : n.app))
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(n.artist).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Text(n.album).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Equalizer(color: .green, playing: n.playing).frame(width: 16, height: 14)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let pos = n.livePosition
                VStack(spacing: 2) {
                    ProgressView(value: n.duration > 0 ? min(1, pos / n.duration) : 0)
                        .progressViewStyle(.linear).tint(.white)
                    HStack {
                        Text(NotchTimer.format(pos))
                        Spacer()
                        Text("−" + NotchTimer.format(max(0, n.duration - pos)))
                    }
                    .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                }
            }
            HStack(spacing: 26) {
                Spacer()
                control("backward.fill", .previous, size: 15)
                control(n.playing ? "pause.fill" : "play.fill", .playPause, size: 21)
                control("forward.fill", .next, size: 15)
                Spacer()
            }
        }
    }

    private func control(_ icon: String, _ c: MediaStore.Command, size: CGFloat) -> some View {
        Button { media.send(c) } label: {
            Image(systemName: icon).font(.system(size: size, weight: .semibold)).frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Étagère

struct ShelfPane: View {
    @ObservedObject var shelf = ShelfStore.shared
    @ObservedObject var m = NotchModel.shared

    var body: some View {
        HStack(spacing: 10) {
            IslandCard {
                if shelf.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: m.dropTargeting ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(m.dropTargeting ? Color.accentColor : .white.opacity(0.6))
                        Text(m.dropTargeting ? L("Lâche pour poser ici") : L("Glisse des fichiers sur l'encoche pour les garder sous la main"))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items, id: \.self) { u in tile(u) }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .opacity(m.dropTargeting ? 1 : 0))
            if !shelf.items.isEmpty {
                IslandCard { shelfActions }.frame(width: 190)
            }
        }
        .frame(height: 170)
    }

    private func tile(_ u: URL) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: shelf.icon(u)).resizable().frame(width: 52, height: 52)
            Text(u.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).frame(width: 82)
        }
        .frame(width: 86)
        .onDrag { NSItemProvider(object: u as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(u) }
        .contextMenu {
            Button(L("Ouvrir")) { NSWorkspace.shared.open(u) }
            Button(L("Afficher dans le Finder")) { shelf.reveal([u]) }
            if u.pathExtension.lowercased() == "pdf" {
                Divider()
                Button(L("Éditer")) { shelf.open(in: .edit, [u]) }
                Button(L("Signer")) { shelf.open(in: .sign, [u]) }
                Button(L("Organiser")) { shelf.open(in: .organize, [u]) }
            }
            Divider()
            Button(L("AirDrop")) { shelf.airDrop([u]) }
            Button(L("Retirer de l'étagère")) { shelf.remove(u) }
        }
        .help(u.path)
    }

    private var shelfActions: some View {
        let pdfs = shelf.pdfs
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            action("arrow.down.right.and.arrow.up.left", L("Compresser"), enabled: !pdfs.isEmpty) { shelf.open(in: .compress, pdfs) }
            action("text.viewfinder", L("OCR"), enabled: !pdfs.isEmpty) { shelf.open(in: .ocr, pdfs) }
            action("rectangle.stack.badge.plus", L("Fusionner"), enabled: pdfs.count > 1) { shelf.open(in: .merge, pdfs) }
            action("pencil.and.outline", L("Éditer"), enabled: !pdfs.isEmpty) { shelf.open(in: .edit, Array(pdfs.prefix(1))) }
            action("dot.radiowaves.left.and.right", L("AirDrop"), enabled: true) { shelf.airDrop(shelf.items) }
            action("doc.on.doc", L("Copier"), enabled: true) { shelf.copy(shelf.items) }
            action("folder", L("Finder"), enabled: true) { shelf.reveal(shelf.items) }
            action("trash", L("Vider"), enabled: true) { shelf.clear() }
        }
    }

    private func action(_ icon: String, _ title: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 14)
                Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Réglages → Général

struct NotchSettingsSection: View {
    @ObservedObject var s = NotchSettings.shared

    var body: some View {
        Section("Île dynamique (encoche)") {
            Toggle("Activer l'île dynamique", isOn: $s.enabled)
            if !NotchGeometry.macHasNotch {
                Toggle("Afficher en haut de l'écran (ce Mac n'a pas d'encoche)", isOn: $s.withoutNotch)
                    .disabled(!s.enabled)
            }
            Group {
                Toggle("S'ouvrir au survol (sinon au clic)", isOn: $s.openOnHover)
                Toggle("Activités en direct au repos (minuteur, musique, cours)", isOn: $s.live)
                Toggle("Alertes (cours dans 5 min, branché, casque, batterie)", isOn: $s.alerts)
                Toggle("Musique (Spotify, Musique)", isOn: $s.music)
                Toggle("Retour haptique sur le trackpad", isOn: $s.haptics)
            }
            .disabled(!s.enabled)
            Text("Glisse un fichier vers l'encoche pour le poser sur l'étagère, puis compresse, signe, fusionne ou envoie-le en AirDrop. La musique passe par Spotify ou Musique (macOS demande une fois l'autorisation de les piloter).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if s.enabled {
                Button("Tester une alerte") {
                    NotchController.shared.alert(NotchAlert(icon: "sparkles", color: .pink, title: L("Toolbox"),
                                                            subtitle: L("L'île dynamique est prête")))
                }
            }
        }
    }
}
