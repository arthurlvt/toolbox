import SwiftUI
import AppKit

// MARK: - Palette de commandes (⌘K)

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String = ""
    let icon: String
    var color: Color = .accentColor
    var keywords: String = ""
    let action: () -> Void
}

final class PaletteState: ObservableObject {
    static let shared = PaletteState()

    @Published var shown = false
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0

    /// Fournies par la fenêtre principale (outils, projets, fichiers récents…).
    var provider: () -> [PaletteCommand] = { [] }
    /// Commandes qui dépendent du texte tapé (« Créer la note … »).
    var dynamicProvider: (String) -> [PaletteCommand] = { _ in [] }

    private var monitor: Any?

    func toggle() { shown ? close() : open() }

    func open() {
        query = ""
        selection = 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { shown = true }
        installMonitor()
    }

    func close() {
        withAnimation(.easeOut(duration: 0.15)) { shown = false }
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// Tous les mots tapés doivent apparaître ; ce qui commence par la saisie passe devant.
    var results: [PaletteCommand] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        let all = provider()
        guard !q.isEmpty else { return Array(all.prefix(9)) }
        let words = q.split(separator: " ").map(String.init)
        let scored: [(PaletteCommand, Int)] = all.compactMap { c in
            let hay = Self.fold(c.title + " " + c.subtitle + " " + c.keywords)
            guard words.allSatisfy({ hay.contains($0) }) else { return nil }
            let title = Self.fold(c.title)
            let score = title.hasPrefix(q) ? 0 : (title.contains(q) ? 1 : 2)
            return (c, score)
        }
        let sorted = scored.sorted { $0.1 < $1.1 }.map { $0.0 }
        return Array((sorted + dynamicProvider(query.trimmingCharacters(in: .whitespaces))).prefix(9))
    }

    func run(_ c: PaletteCommand) {
        close()
        DispatchQueue.main.async { c.action() }
    }

    /// Flèches, Entrée et Échap pendant que la palette est ouverte.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.shown else { return e }
            let count = self.results.count
            switch e.keyCode {
            case 125: if count > 0 { self.selection = (self.selection + 1) % count }; return nil      // ↓
            case 126: if count > 0 { self.selection = (self.selection - 1 + count) % count }; return nil // ↑
            case 53: self.close(); return nil                                                          // Échap
            case 36, 76:                                                                               // Entrée
                let r = self.results
                if self.selection < r.count { self.run(r[self.selection]) }
                return nil
            default: return e
            }
        }
    }
}

struct PaletteView: View {
    @ObservedObject var state = PaletteState.shared

    var body: some View {
        if state.shown {
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { state.close() }
                    .transition(.opacity)
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                        FocusTextField(text: $state.query, placeholder: "Outil, action, projet, fichier… ou une note à créer")
                            .frame(height: 30)
                        Text("esc").font(.caption.monospaced()).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                    }
                    .padding(14)
                    Divider()
                    let results = state.results
                    if results.isEmpty {
                        Text("Aucun résultat").foregroundStyle(.secondary).padding(20)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, c in
                                row(c, selected: i == state.selection)
                                    .onTapGesture { state.run(c) }
                                    .onHover { if $0 { state.selection = i } }
                            }
                        }
                        .padding(6)
                    }
                    HStack(spacing: 14) {
                        Label("naviguer", systemImage: "arrow.up.arrow.down")
                        Label("ouvrir", systemImage: "return")
                        Spacer()
                        Text("⌘K pour rouvrir")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.primary.opacity(0.03))
                }
                .frame(width: 600)
                .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                .padding(.top, 90)
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
    }

    private func row(_ c: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: c.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(c.color.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.body.weight(.medium)).lineLimit(1)
                if !c.subtitle.isEmpty {
                    Text(c.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if selected { Image(systemName: "return").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }
}

/// Champ de texte AppKit qui prend le focus dès qu'il apparaît.
struct FocusTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 19)
        f.placeholderString = placeholder
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusTextField
        init(_ parent: FocusTextField) { self.parent = parent }
        func controlTextDidChange(_ note: Notification) {
            if let f = note.object as? NSTextField { parent.text = f.stringValue }
        }
    }
}
