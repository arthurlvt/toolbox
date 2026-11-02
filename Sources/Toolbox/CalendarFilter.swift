import SwiftUI
import AppKit
import EventKit

// MARK: - Calendriers suivis par Toolbox

/// Les calendriers que Toolbox lit : widget « Aujourd'hui », cours en ce moment, check du matin,
/// comptes à rebours, conflits du planning. Pratique quand on a aussi les emplois du temps de ses amis.
/// On retient les calendriers *masqués* : un nouveau calendrier est donc affiché par défaut.
final class CalendarFilter: ObservableObject {
    static let shared = CalendarFilter()
    static let changed = Notification.Name("toolbox.calendarFilter.changed")

    @Published private(set) var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "calendar.hidden") ?? [])

    /// Un magasin ouvert avant l'autorisation du Calendrier ne voit rien : on le recrée si besoin.
    private var cached = EKEventStore()
    var store: EKEventStore {
        if cached.calendars(for: .event).isEmpty, HomeStore.hasAccess { cached = EKEventStore() }
        return cached
    }

    func isShown(_ c: EKCalendar) -> Bool { !hidden.contains(c.calendarIdentifier) }

    func set(_ c: EKCalendar, shown: Bool) {
        if shown { hidden.remove(c.calendarIdentifier) } else { hidden.insert(c.calendarIdentifier) }
        save()
    }

    func showAll() {
        hidden = []
        save()
    }

    func showOnly(_ c: EKCalendar) {
        hidden = Set(store.calendars(for: .event).map { $0.calendarIdentifier }.filter { $0 != c.calendarIdentifier })
        save()
    }

    private func save() {
        UserDefaults.standard.set(Array(hidden).sorted(), forKey: "calendar.hidden")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Nombre de calendriers masqués qui existent encore.
    var hiddenCount: Int { store.calendars(for: .event).filter { !isShown($0) }.count }

    /// Événements des calendriers affichés, à la place de `events(matching: predicateForEvents(…, calendars: nil))`.
    func events(_ store: EKEventStore, from start: Date, to end: Date) -> [EKEvent] {
        var calendars: [EKCalendar]? = nil
        if !hidden.isEmpty {
            let shown = store.calendars(for: .event).filter { isShown($0) }
            if shown.isEmpty { return [] }        // tout masqué : rien (un tableau vide voudrait dire « tous »)
            calendars = shown
        }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
    }

    struct Group {
        let title: String
        let calendars: [EKCalendar]
    }

    /// Calendriers rangés par compte (iCloud, Google, abonnements…).
    var groups: [Group] {
        let all = store.calendars(for: .event)
        let bySource = Dictionary(grouping: all) { $0.source?.title ?? "Autres" }
        return bySource.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { key in
            Group(title: key, calendars: (bySource[key] ?? []).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            })
        }
    }

    /// Pastille de couleur pour les menus (une image non « template » garde sa couleur).
    static func dot(_ color: NSColor?) -> NSImage {
        let c = color ?? .systemBlue
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

// MARK: - Menu (en-tête du widget « Aujourd'hui »)

struct CalendarFilterMenu: View {
    @ObservedObject var filter = CalendarFilter.shared

    var body: some View {
        Menu {
            ForEach(filter.groups, id: \.title) { g in
                Section(g.title) {
                    ForEach(g.calendars, id: \.calendarIdentifier) { c in
                        Toggle(isOn: Binding(get: { filter.isShown(c) }, set: { filter.set(c, shown: $0) })) {
                            Label { Text(c.title) } icon: { Image(nsImage: CalendarFilter.dot(c.color)) }
                        }
                    }
                }
            }
            Divider()
            Button("Tout afficher") { filter.showAll() }
            Button("Réglages des calendriers…") { UpdateStore.openSettings() }
        } label: {
            Image(systemName: filter.hidden.isEmpty ? "line.3.horizontal.decrease.circle"
                                                    : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choisir les calendriers affichés")
    }
}

// MARK: - Onglet des Réglages

struct CalendarSettings: View {
    @ObservedObject var filter = CalendarFilter.shared

    var body: some View {
        Form {
            Text("Toolbox ne lit que les calendriers cochés : widget « Aujourd'hui », cours en ce moment, check du matin, comptes à rebours et chevauchements du planning. Décoche par exemple les emplois du temps de tes amis.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !HomeStore.hasAccess {
                Text("Toolbox n'a pas encore accès au Calendrier.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(filter.groups, id: \.title) { g in
                Section(g.title) {
                    ForEach(g.calendars, id: \.calendarIdentifier) { c in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { filter.isShown(c) }, set: { filter.set(c, shown: $0) })) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(nsColor: c.color ?? .systemBlue)).frame(width: 9, height: 9)
                                    Text(c.title)
                                }
                            }
                            Spacer()
                            Button("Seulement lui") { filter.showOnly(c) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Tout afficher") { filter.showAll() }.disabled(filter.hidden.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }
}
