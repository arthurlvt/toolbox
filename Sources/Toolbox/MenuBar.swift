import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFCore

/// Petit panneau dans la barre des menus : pense-bête, capture → texte, PDF à compresser, presse-papiers.
final class MenuBarState: ObservableObject {
    @Published var draft = ""
    @Published var status = ""
    @Published var busy = false
    @Published var lastOutput: URL?
    @Published var targeted = false

    func createNote() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        runInBackground({ try AppleNotes.create(text) }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success: self.draft = ""; self.status = "Note créée dans Notes ✓"
            case .failure(let e): self.status = e.localizedDescription
            }
        }
    }

    func compress(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { status = "Dépose un fichier PDF."; return }
        busy = true
        status = "Compression…"
        runInBackground({ () -> [(URL, String)] in
            try pdfs.map { input -> (URL, String) in
                let out = FileUtils.unique(input.deletingLastPathComponent()
                    .appendingPathComponent(input.deletingPathExtension().lastPathComponent + " (compressé).pdf"))
                let r = try Compressor.compress(input, level: .balanced, to: out)
                return (out, WatchFolderStore.saving(r))
            }
        }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let list):
                self.lastOutput = list.last?.0
                self.status = list.count == 1 ? "Compressé : \(list[0].1)" : "\(list.count) PDF compressés"
            case .failure(let e):
                self.status = e.localizedDescription
            }
        }
    }
}

struct MenuBarPanel: View {
    @StateObject private var m = MenuBarState()
    @ObservedObject var clip = ClipboardStore.shared
    @ObservedObject var discord = DiscordPresence.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                FeuilleMascot().frame(width: 34, height: 30)
                Text("Toolbox").font(.headline)
                Spacer()
                Button("Ouvrir") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
            }

            // Pense-bête
            VStack(alignment: .leading, spacing: 6) {
                Label("Pense-bête", systemImage: "note.text").font(.subheadline.bold()).foregroundStyle(Color.orange)
                TextField("Note rapide… (⌘↩ pour créer)", text: $m.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button("Créer dans Notes") { m.createNote() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .disabled(m.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || m.busy)
            }

            Divider()

            AppStrip()
            MenuHeadphoneStrip()

            HStack(spacing: 8) {
                Button { ScreenText.capture() } label: {
                    Label("Capture → texte", systemImage: "text.viewfinder").frame(maxWidth: .infinity)
                }
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { PaletteState.shared.open() }
                } label: {
                    Label("Palette ⌘K", systemImage: "command").frame(maxWidth: .infinity)
                }
            }

            // PDF à compresser
            VStack(spacing: 4) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3)
                Text("Dépose un PDF ici pour le compresser").font(.caption)
            }
            .foregroundStyle(m.targeted ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(m.targeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            .onDrop(of: [.fileURL], isTargeted: $m.targeted) { providers in
                FileDrop.load(providers) { m.compress($0) }
                return true
            }

            if !m.status.isEmpty || m.busy {
                HStack {
                    if m.busy { ProgressView().controlSize(.small) }
                    Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if let o = m.lastOutput, !m.busy {
                        Button("Afficher") { NSWorkspace.shared.activateFileViewerSelecting([o]) }.controlSize(.mini)
                    }
                }
            }

            // Presse-papiers
            if !clip.items.isEmpty {
                Divider()
                Label("Presse-papiers", systemImage: "doc.on.clipboard").font(.subheadline.bold()).foregroundStyle(Color.mint)
                ForEach(clip.items.prefix(5)) { item in
                    Button { clip.copy(item) } label: {
                        Text(item.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            HStack {
                Toggle("Statut Discord", isOn: $discord.enabled)
                    .toggleStyle(.switch).controlSize(.mini)
                    .help(discord.status)
                Spacer()
                Button("Quitter Toolbox") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
