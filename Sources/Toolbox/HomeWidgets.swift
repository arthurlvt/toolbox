import SwiftUI
import AppKit
import Network
import UniformTypeIdentifiers

// MARK: - Widgets de l'accueil

enum HomeWidget: String, CaseIterable, Identifiable, Codable {
    case quickActions, apps, courses, vscode, today, notes, weather, exams, clipboard, watch, github, recents, tools
    case grades, planning, nextShift, nextExam, mac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickActions: return "Actions rapides"
        case .apps: return "Mes apps"
        case .courses: return "Mes cours"
        case .vscode: return "Projets VS Code"
        case .today: return "Aujourd'hui"
        case .notes: return "Pense-bête"
        case .weather: return "Météo"
        case .exams: return "Comptes à rebours"
        case .clipboard: return "Presse-papiers"
        case .watch: return "Dossier surveillé"
        case .github: return "GitHub"
        case .recents: return "Fichiers récents"
        case .tools: return "Tous les outils"
        case .grades: return "Notes & ECTS"
        case .planning: return "Planning"
        case .nextShift: return "Prochain shift"
        case .nextExam: return "Prochain CC"
        case .mac: return "Mon Mac"
        }
    }

    var icon: String {
        switch self {
        case .quickActions: return "bolt.fill"
        case .apps: return "square.grid.3x3.fill"
        case .courses: return "books.vertical.fill"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .today: return "calendar"
        case .notes: return "note.text"
        case .weather: return "cloud.sun.fill"
        case .exams: return "hourglass"
        case .clipboard: return "doc.on.clipboard"
        case .watch: return "eye.circle"
        case .github: return "chevron.left.slash.chevron.right"
        case .recents: return "clock.arrow.circlepath"
        case .tools: return "square.grid.2x2.fill"
        case .grades: return "chart.bar.doc.horizontal"
        case .planning: return "fork.knife"
        case .nextShift: return "clock.badge.checkmark"
        case .nextExam: return "checklist"
        case .mac: return "laptopcomputer"
        }
    }

    var defaultWide: Bool {
        switch self {
        case .quickActions, .apps, .courses, .github, .recents, .tools: return true
        default: return false
        }
    }
}

struct WidgetSlot: Codable, Equatable, Identifiable {
    var widget: HomeWidget
    var visible: Bool
    var wide: Bool
    var id: String { widget.rawValue }
}

/// Choix, ordre et largeur des widgets (mémorisés).
final class HomeLayoutStore: ObservableObject {
    @Published var slots: [WidgetSlot]
    @Published var editing = false
    @Published var dragging: HomeWidget?

    static let key = "home.layout.v1"

    static let defaults: [WidgetSlot] = [
        WidgetSlot(widget: .quickActions, visible: true, wide: true),
        WidgetSlot(widget: .apps, visible: true, wide: true),
        WidgetSlot(widget: .nextExam, visible: true, wide: false),
        WidgetSlot(widget: .nextShift, visible: true, wide: false),
        WidgetSlot(widget: .courses, visible: true, wide: true),
        WidgetSlot(widget: .vscode, visible: true, wide: false),
        WidgetSlot(widget: .today, visible: true, wide: false),
        WidgetSlot(widget: .weather, visible: true, wide: false),
        WidgetSlot(widget: .mac, visible: true, wide: false),
        WidgetSlot(widget: .notes, visible: true, wide: false),
        WidgetSlot(widget: .exams, visible: true, wide: false),
        WidgetSlot(widget: .grades, visible: true, wide: false),
        WidgetSlot(widget: .planning, visible: true, wide: false),
        WidgetSlot(widget: .clipboard, visible: true, wide: false),
        WidgetSlot(widget: .watch, visible: false, wide: false),
        WidgetSlot(widget: .github, visible: true, wide: true),
        WidgetSlot(widget: .recents, visible: true, wide: true),
        WidgetSlot(widget: .tools, visible: true, wide: true),
    ]

    init() {
        var loaded = Self.defaults
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([WidgetSlot].self, from: data) {
            loaded = saved
            // widgets apparus dans une version plus récente : ajoutés à la fin
            for d in Self.defaults where !loaded.contains(where: { $0.widget == d.widget }) {
                if d.widget == .courses || d.widget == .apps || d.widget == .nextShift || d.widget == .nextExam, let i = loaded.firstIndex(where: { $0.widget == .quickActions }) {
                    loaded.insert(d, at: i + 1)
                } else {
                    loaded.append(d)
                }
            }
        }
        slots = loaded
    }

    func save() {
        if let data = try? JSONEncoder().encode(slots) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func slot(_ w: HomeWidget) -> WidgetSlot? { slots.first { $0.widget == w } }

    func setVisible(_ w: HomeWidget, _ on: Bool) {
        guard let i = slots.firstIndex(where: { $0.widget == w }) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { slots[i].visible = on }
        save()
    }

    func toggleWide(_ w: HomeWidget) {
        guard let i = slots.firstIndex(where: { $0.widget == w }) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { slots[i].wide.toggle() }
        save()
    }

    /// Place `w` à l'emplacement de `target` (les autres se décalent).
    func move(_ w: HomeWidget, to target: HomeWidget) {
        guard w != target, let from = slots.firstIndex(where: { $0.widget == w }),
              let to = slots.firstIndex(where: { $0.widget == target }) else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            let item = slots.remove(at: from)
            slots.insert(item, at: to)
        }
    }

    func reset() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { slots = Self.defaults }
        save()
    }

    private var dragWatch: Timer?

    /// Appui sur la poignée : le widget se soulève, les autres se mettent à trembler.
    func beginDrag(_ w: HomeWidget) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { dragging = w }
        dragWatch?.invalidate()
        // macOS ne signale pas un glisser abandonné (lâché ailleurs) : on surveille le bouton de la souris.
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            if NSEvent.pressedMouseButtons & 1 == 0 { self?.endDrag() }
        }
    }

    func endDrag() {
        dragWatch?.invalidate()
        dragWatch = nil
        guard dragging != nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { dragging = nil }
        save()
    }

    func finishEditing() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            editing = false
            dragging = nil
        }
        save()
    }
}

// MARK: - Disposition : deux colonnes, les widgets larges prennent toute la largeur

struct WideWidgetKey: LayoutValueKey {
    static let defaultValue = false
}

/// Les widgets « demi-largeur » vont dans la colonne la moins haute ; un widget large
/// commence sous les deux colonnes. Comme tous les widgets sont les enfants d'un même
/// conteneur, un changement d'ordre s'anime (ils glissent vers leur nouvelle place).
struct WidgetFlowLayout: Layout {
    var spacing: CGFloat = 18

    func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let half = (width - spacing) / 2
        var cols: [CGFloat] = [0, 0]
        var out: [CGRect] = []
        for s in subviews {
            if s[WideWidgetKey.self] {
                let y = max(cols[0], cols[1])
                let h = s.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                out.append(CGRect(x: 0, y: y, width: width, height: h))
                cols = [y + h + spacing, y + h + spacing]
            } else {
                let c = cols[0] <= cols[1] ? 0 : 1
                let h = s.sizeThatFits(ProposedViewSize(width: half, height: nil)).height
                out.append(CGRect(x: CGFloat(c) * (half + spacing), y: cols[c], width: half, height: h))
                cols[c] += h + spacing
            }
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let f = frames(width: width, subviews: subviews)
        let height = f.map { $0.maxY }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = frames(width: bounds.width, subviews: subviews)
        for (i, s) in subviews.enumerated() {
            s.place(at: CGPoint(x: bounds.minX + f[i].minX, y: bounds.minY + f[i].minY),
                    proposal: ProposedViewSize(width: f[i].width, height: f[i].height))
        }
    }
}

/// Glisser un widget au-dessus d'un autre : il prend sa place immédiatement (avec animation).
struct WidgetDropDelegate: DropDelegate {
    let target: HomeWidget
    let layout: HomeLayoutStore

    func dropEntered(info: DropInfo) {
        guard let d = layout.dragging, d != target else { return }
        layout.move(d, to: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        layout.endDrag()
        return true
    }
}

/// Habillage de chaque widget : poignée de déplacement (toujours là), et en mode Personnaliser
/// les boutons « retirer » et « largeur ». Pendant un déplacement, le widget saisi se soulève
/// et les autres tremblent ; ils glissent vers leur nouvelle place quand on passe au-dessus.
struct EditableWidget: ViewModifier {
    let widget: HomeWidget
    @ObservedObject var layout: HomeLayoutStore

    func body(content: Content) -> some View {
        let editing = layout.editing
        let moving = layout.dragging != nil
        let lifted = layout.dragging == widget
        let wide = layout.slot(widget)?.wide ?? false
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(editing || moving))) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let phase = Double(abs(widget.rawValue.hashValue % 100)) / 100 * .pi * 2
            let shaking = (editing || moving) && !lifted
            content
                .allowsHitTesting(!editing)
                .overlay(alignment: .top) {
                    MoveHandle(widget: widget, layout: layout).offset(y: -8)
                }
                .overlay(alignment: .topLeading) {
                    if editing {
                        Button { layout.setVisible(widget, false) } label: {
                            Image(systemName: "minus.circle.fill").font(.title2)
                                .symbolRenderingMode(.palette).foregroundStyle(Color.white, Color.red)
                        }
                        .buttonStyle(.plain).help("Retirer de l'accueil")
                        .offset(x: -8, y: -8)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if editing {
                        Button { layout.toggleWide(widget) } label: {
                            Image(systemName: wide ? "arrow.right.and.line.vertical.and.arrow.left"
                                                   : "arrow.left.and.line.vertical.and.arrow.right")
                                .font(.callout.weight(.semibold))
                                .padding(6)
                                .background(Circle().fill(.regularMaterial))
                        }
                        .buttonStyle(.plain).help(wide ? "Demi-largeur" : "Pleine largeur")
                        .offset(x: 8, y: -8)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(lifted ? 0.9 : (editing || moving ? 0.4 : 0)),
                                style: StrokeStyle(lineWidth: 2, dash: lifted ? [] : [7, 5]))
                )
                .shadow(color: Color.accentColor.opacity(lifted ? 0.35 : 0), radius: lifted ? 18 : 0, y: lifted ? 10 : 0)
                .rotationEffect(.degrees(shaking ? sin(t * 14 + phase) * 0.5 : (lifted ? -1.2 : 0)))
                .scaleEffect(lifted ? 1.03 : 1)
                .opacity(lifted ? 0.7 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 16))   // toute la carte reçoit le dépôt
        }
        .onDrop(of: [.text], delegate: WidgetDropDelegate(target: widget, layout: layout))
        .layoutValue(key: WideWidgetKey.self, value: wide)
    }
}

/// Petite poignée en haut de chaque widget : on l'attrape pour déplacer le widget.
struct MoveHandle: View {
    let widget: HomeWidget
    @ObservedObject var layout: HomeLayoutStore
    @StateObject private var hover = HoverFlag()

    var body: some View {
        let active = hover.on || layout.dragging == widget
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(width: active ? 54 : 36, height: 16)
            .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.10)))
            .background(Capsule().fill(.regularMaterial))
            .contentShape(Capsule())
            .onHover { on in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover.on = on }
                if on { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .onDrag {
                layout.beginDrag(widget)
                return NSItemProvider(object: widget.rawValue as NSString)
            } preview: {
                Label(widget.title, systemImage: widget.icon)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Color.accentColor.opacity(0.9)))
                    .foregroundStyle(Color.white)
            }
            .help("Attrape-moi pour déplacer « \(widget.title) »")
    }
}

// MARK: - Connexion internet

final class Connectivity: ObservableObject {
    @Published var online = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async { if self?.online != ok { self?.online = ok } }
        }
        monitor.start(queue: DispatchQueue(label: "fr.arthur.toolbox.reseau"))
    }

    deinit { monitor.cancel() }
}

// MARK: - Météo (Open-Meteo, sans compte)

struct WeatherPlace: Codable, Hashable, Identifiable {
    var id: String { "\(latitude),\(longitude)" }
    let name: String
    let detail: String
    let latitude: Double
    let longitude: Double
}

struct WeatherNow {
    let temperature: Double
    let feelsLike: Double
    let code: Int
    let isDay: Bool
    let wind: Double
    let min: Double
    let max: Double
    let hours: [(date: Date, temp: Double, code: Int, rain: Int)]
}

final class WeatherStore: ObservableObject {
    @Published var place: WeatherPlace? {
        didSet {
            if let p = place, let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: "home.weather.place") }
        }
    }
    @Published var now: WeatherNow?
    @Published var loading = false
    @Published var error = ""
    @Published var query = ""
    @Published var results: [WeatherPlace] = []
    @Published var choosing = false
    private var lastFetch: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: "home.weather.place"),
           let p = try? JSONDecoder().decode(WeatherPlace.self, from: data) { place = p }
    }

    static func get(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else { return }
        c.queryItems = [URLQueryItem(name: "name", value: q), URLQueryItem(name: "count", value: "6"),
                        URLQueryItem(name: "language", value: "fr")]
        guard let url = c.url else { return }
        Task {
            do {
                let json = try await Self.get(url)
                let list = (json["results"] as? [[String: Any]] ?? []).compactMap { r -> WeatherPlace? in
                    guard let name = r["name"] as? String, let lat = r["latitude"] as? Double,
                          let lon = r["longitude"] as? Double else { return nil }
                    let detail = [r["admin2"] as? String, r["admin1"] as? String, r["country"] as? String]
                        .compactMap { $0 }.joined(separator: ", ")
                    return WeatherPlace(name: name, detail: detail, latitude: lat, longitude: lon)
                }
                await MainActor.run {
                    self.results = list
                    self.error = list.isEmpty ? "Aucune ville trouvée." : ""
                }
            } catch {
                await MainActor.run { self.error = "Recherche impossible (connexion ?)." }
            }
        }
    }

    func choose(_ p: WeatherPlace) {
        place = p
        choosing = false
        results = []
        query = ""
        refresh(force: true)
    }

    /// Pas plus d'une requête toutes les 15 minutes, sauf demande explicite.
    func refresh(force: Bool = false) {
        guard let p = place else { return }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 900, now != nil { return }
        guard var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return }
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(p.latitude)),
            URLQueryItem(name: "longitude", value: String(p.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
        ]
        guard let url = c.url else { return }
        loading = true
        Task {
            do {
                let json = try await Self.get(url)
                let cur = json["current"] as? [String: Any] ?? [:]
                let daily = json["daily"] as? [String: Any] ?? [:]
                let hourly = json["hourly"] as? [String: Any] ?? [:]
                let offset = json["utc_offset_seconds"] as? Int ?? 0
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd'T'HH:mm"
                f.timeZone = TimeZone(secondsFromGMT: offset)
                let times = (hourly["time"] as? [String] ?? []).map { f.date(from: $0) }
                let temps = hourly["temperature_2m"] as? [Double] ?? []
                let codes = hourly["weather_code"] as? [Int] ?? []
                let rains = hourly["precipitation_probability"] as? [Int] ?? []
                var hours: [(date: Date, temp: Double, code: Int, rain: Int)] = []
                let startHour = Date().addingTimeInterval(-3600)
                for i in 0..<min(times.count, temps.count, codes.count) {
                    guard let d = times[i], d >= startHour else { continue }
                    hours.append((d, temps[i], codes[i], i < rains.count ? rains[i] : 0))
                    if hours.count == 8 { break }
                }
                let w = WeatherNow(temperature: cur["temperature_2m"] as? Double ?? 0,
                                   feelsLike: cur["apparent_temperature"] as? Double ?? 0,
                                   code: cur["weather_code"] as? Int ?? 0,
                                   isDay: (cur["is_day"] as? Int ?? 1) == 1,
                                   wind: cur["wind_speed_10m"] as? Double ?? 0,
                                   min: (daily["temperature_2m_min"] as? [Double])?.first ?? 0,
                                   max: (daily["temperature_2m_max"] as? [Double])?.first ?? 0,
                                   hours: hours)
                await MainActor.run {
                    self.now = w
                    self.loading = false
                    self.error = ""
                    self.lastFetch = Date()
                }
            } catch {
                await MainActor.run {
                    self.loading = false
                    self.error = "Météo indisponible pour le moment."
                }
            }
        }
    }

    /// Codes météo WMO → symbole et libellé.
    static func describe(_ code: Int, day: Bool = true) -> (symbol: String, label: String) {
        switch code {
        case 0: return (day ? "sun.max.fill" : "moon.stars.fill", "Ciel dégagé")
        case 1, 2: return (day ? "cloud.sun.fill" : "cloud.moon.fill", code == 1 ? "Plutôt dégagé" : "Partiellement nuageux")
        case 3: return ("cloud.fill", "Couvert")
        case 45, 48: return ("cloud.fog.fill", "Brouillard")
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "Bruine")
        case 61, 63, 66, 80, 81: return ("cloud.rain.fill", "Pluie")
        case 65, 67, 82: return ("cloud.heavyrain.fill", "Forte pluie")
        case 71, 73, 75, 77, 85, 86: return ("cloud.snow.fill", "Neige")
        case 95, 96, 99: return ("cloud.bolt.rain.fill", "Orage")
        default: return ("cloud.fill", "—")
        }
    }
}

struct WeatherWidget: View {
    @ObservedObject var weather: WeatherStore

    private static let hour: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH'h'"
        return f
    }()

    var body: some View {
        Card(title: weather.place?.name ?? "Météo", icon: "cloud.sun.fill", tint: .blue,
             accessory: AnyView(HStack(spacing: 8) {
                 if weather.loading { ProgressView().controlSize(.small) }
                 Button { weather.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                     .buttonStyle(.borderless).help("Actualiser").disabled(weather.place == nil)
                 Button { weather.choosing.toggle() } label: { Image(systemName: "mappin.and.ellipse") }
                     .buttonStyle(.borderless).help("Changer de ville")
             })) {
            if weather.place == nil || weather.choosing {
                chooser
            } else if let w = weather.now {
                current(w)
            } else if !weather.error.isEmpty {
                Text(weather.error).font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .onAppear { weather.refresh() }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choisis ta ville :").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Ex. : Avignon", text: $weather.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { weather.search() }
                Button("Chercher") { weather.search() }
            }
            ForEach(weather.results) { p in
                Button { weather.choose(p) } label: {
                    HStack {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(Color.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.callout.weight(.medium))
                            Text(p.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !weather.error.isEmpty { Text(weather.error).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func current(_ w: WeatherNow) -> some View {
        let d = WeatherStore.describe(w.code, day: w.isDay)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    Image(systemName: d.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 44))
                        .offset(y: sin(t * 1.6) * 3)
                        .rotationEffect(.degrees(sin(t * 0.8) * 3))
                }
                .frame(width: 60, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(w.temperature.rounded()))°")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                    Text(d.label).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("↑ \(Int(w.max.rounded()))°  ↓ \(Int(w.min.rounded()))°").font(.callout.monospacedDigit())
                    Text("Ressenti \(Int(w.feelsLike.rounded()))°").font(.caption).foregroundStyle(.secondary)
                    Label("\(Int(w.wind.rounded())) km/h", systemImage: "wind").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !w.hours.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(w.hours.enumerated()), id: \.offset) { _, h in
                        VStack(spacing: 4) {
                            Text(Self.hour.string(from: h.date)).font(.caption2).foregroundStyle(.secondary)
                            Image(systemName: WeatherStore.describe(h.code).symbol)
                                .symbolRenderingMode(.multicolor).font(.callout)
                            Text("\(Int(h.temp.rounded()))°").font(.caption.monospacedDigit())
                            Text(h.rain >= 20 ? "\(h.rain)%" : " ").font(.system(size: 9)).foregroundStyle(Color.blue)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
            }
        }
    }
}

// MARK: - Barre de personnalisation

struct WidgetTray: View {
    @ObservedObject var layout: HomeLayoutStore
    let online: Bool

    var body: some View {
        let hidden = layout.slots.filter { !$0.visible }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Personnaliser l'accueil", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Button("Réinitialiser") { layout.reset() }.buttonStyle(.borderless)
                Button("Terminé") { layout.finishEditing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            Text("− pour retirer un widget · ⇆ pour changer sa largeur · la poignée en haut de chaque widget sert à le déplacer.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Choisir les widgets affichés") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(layout.slots) { slot in
                        let offline = slot.widget == .weather && !online
                        Toggle(isOn: Binding(get: { slot.visible }, set: { layout.setVisible(slot.widget, $0) })) {
                            Label(slot.widget.title, systemImage: slot.widget.icon)
                        }
                        .toggleStyle(.checkbox)
                        .help(offline ? "Affiché seulement avec une connexion internet" : "")
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
            if hidden.isEmpty {
                Text("Tous les widgets sont affichés.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(hidden) { s in
                        let offline = s.widget == .weather && !online
                        Button { layout.setVisible(s.widget, true) } label: {
                            Label(s.widget.title, systemImage: "plus.circle.fill")
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color.accentColor.opacity(offline ? 0.06 : 0.14)))
                        }
                        .buttonStyle(.plain)
                        .disabled(offline)
                        .help(offline ? "La météo n'est disponible qu'avec une connexion internet" : "Ajouter à l'accueil")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.4)))
    }
}

// MARK: - Widget : comptes à rebours

struct ExamsWidget: View {
    @ObservedObject var exams: ExamsStore

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM"
        return f
    }()

    var body: some View {
        Card(title: "Comptes à rebours", icon: "hourglass", tint: .red,
             accessory: AnyView(Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { exams.adding.toggle() } } label: {
                 Image(systemName: exams.adding ? "xmark.circle" : "plus.circle")
             }.buttonStyle(.borderless).help("Ajouter une échéance"))) {
            if exams.adding {
                HStack {
                    TextField("Ex. : CC Analyse 1", text: $exams.newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { exams.add() }
                    DatePicker("", selection: $exams.newDate, in: Date()..., displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                    Button("Ajouter") { exams.add() }
                        .disabled(exams.newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            let list = exams.all
            if list.isEmpty {
                Text("Aucune échéance. Ajoute-en une avec +, ou nomme un événement de ton calendrier « CC », « partiel », « examen »… : il apparaîtra ici tout seul.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list.prefix(6)) { c in
                let d = ExamsStore.daysLeft(c.date)
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        Text(d == 0 ? "Auj." : (d == 1 ? "Dem." : "\(d)"))
                            .font(.system(size: d > 1 ? 20 : 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        if d > 1 { Text("jours").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    .frame(width: 46, height: 40)
                    .foregroundStyle(Self.color(d))
                    .background(RoundedRectangle(cornerRadius: 9).fill(Self.color(d).opacity(0.13)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.callout.weight(.medium)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(Self.dateFormat.string(from: c.date))
                            if c.fromCalendar { Image(systemName: "calendar").font(.system(size: 9)) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contextMenu {
                    if !c.fromCalendar { Button("Supprimer") { exams.remove(c) } }
                }
            }
        }
        .onAppear { exams.loadCalendar() }
    }

    static func color(_ days: Int) -> Color {
        days <= 3 ? .red : (days <= 7 ? .orange : .blue)
    }
}

// MARK: - Widget : presse-papiers

struct ClipboardWidget: View {
    @ObservedObject var clip = ClipboardStore.shared

    var body: some View {
        Card(title: "Presse-papiers", icon: "doc.on.clipboard", tint: .mint,
             accessory: AnyView(HStack(spacing: 8) {
                 Button { clip.paused.toggle() } label: {
                     Image(systemName: clip.paused ? "play.circle" : "pause.circle")
                 }
                 .buttonStyle(.borderless)
                 .help(clip.paused ? "Reprendre l'historique" : "Mettre l'historique en pause")
                 Button { clip.clear() } label: { Image(systemName: "trash") }
                     .buttonStyle(.borderless).help("Tout effacer").disabled(clip.items.isEmpty)
             })) {
            if clip.items.isEmpty {
                Text(clip.paused ? "Historique en pause." : "Les textes que tu copies (⌘C) apparaîtront ici. Rien n'est enregistré sur le disque, et les mots de passe sont ignorés.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(clip.items.prefix(6)) { item in
                Button { clip.copy(item) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "text.quote").foregroundStyle(.secondary).font(.caption)
                        Text(item.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                            .font(.callout)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cliquer pour recopier")
                .contextMenu { Button("Retirer de l'historique") { clip.remove(item) } }
            }
        }
    }
}

// MARK: - Widget : dossier surveillé

struct WatchWidget: View {
    @ObservedObject var watch = WatchFolderStore.shared

    var body: some View {
        Card(title: "Dossier surveillé", icon: "eye.circle", tint: .green,
             accessory: AnyView(Toggle("", isOn: $watch.enabled).toggleStyle(.switch).labelsHidden()
                .disabled(watch.folder == nil).help("Activer la surveillance"))) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(Color.blue)
                Text(watch.folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Aucun dossier choisi")
                    .font(.callout).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choisir…") {
                    if let u = Panels.folder(directory: watch.folder, prompt: "Surveiller ce dossier") { watch.folder = u }
                }
                .controlSize(.small)
            }
            Picker("Pour chaque nouveau PDF", selection: $watch.action) {
                ForEach(WatchFolderStore.Action.allCases) { Text($0.title).tag($0) }
            }
            .controlSize(.small)
            Text(watch.enabled
                 ? "Tout PDF déposé dans ce dossier est traité ; le résultat va dans « \(WatchFolderStore.outputName) » (l'original n'est pas modifié)."
                 : "Choisis un dossier (ex. Téléchargements) puis active l'interrupteur. Fonctionne tant que Toolbox est ouvert.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let b = watch.busy {
                HStack { ProgressView().controlSize(.small); Text(b).font(.caption).lineLimit(1) }
            }
            ForEach(watch.log.prefix(4)) { e in
                HStack(spacing: 6) {
                    Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(e.ok ? Color.green : Color.red)
                    Text(e.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(e.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let o = e.output { NSWorkspace.shared.activateFileViewerSelecting([o]) } }
            }
        }
    }
}
