import SwiftUI
import CryptoKit
import PDFCore

/// Une version enregistrée d'un projet LaTeX.
struct HistorySnapshot: Identifiable, Hashable {
    let id: URL              // dossier de la version
    let date: Date
    let files: [String]      // chemins relatifs au dossier du fichier principal
}

/// Historique local : à chaque compilation, une copie des .tex ouverts (si quelque chose a changé),
/// dans ~/Library/Application Support/Toolbox/Historique/<projet>/<date>/.
enum LatexHistory {
    static let keep = 150

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/Historique", isDirectory: true)
    }

    static func folder(for main: URL) -> URL {
        let path = main.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = main.deletingLastPathComponent().lastPathComponent
        return root.appendingPathComponent("\(name)-\(digest.prefix(10))", isDirectory: true)
    }

    static func relative(_ file: URL, to main: URL) -> String {
        let base = main.deletingLastPathComponent().standardizedFileURL.path + "/"
        let p = file.standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : file.lastPathComponent
    }

    static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Enregistre une version si au moins un fichier diffère de la dernière.
    @discardableResult
    static func snapshot(main: URL, files: [URL]) -> Bool {
        let fm = FileManager.default
        let dir = folder(for: main)
        var contents: [(String, String)] = []
        for f in files where f.pathExtension.lowercased() == "tex" {
            if let t = try? String(contentsOf: f, encoding: .utf8) { contents.append((relative(f, to: main), t)) }
        }
        guard !contents.isEmpty else { return false }
        if let last = list(main: main).first {
            let unchanged = contents.allSatisfy { rel, text in
                (try? String(contentsOf: last.id.appendingPathComponent(rel), encoding: .utf8)) == text
            }
            if unchanged { return false }
        }
        let snap = dir.appendingPathComponent(stampFormat.string(from: Date()), isDirectory: true)
        for (rel, text) in contents {
            let u = snap.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        try? main.path.write(to: dir.appendingPathComponent("projet.txt"), atomically: true, encoding: .utf8)
        // On ne garde que les plus récentes.
        for old in list(main: main).dropFirst(keep) { try? fm.removeItem(at: old.id) }
        return true
    }

    static func list(main: URL) -> [HistorySnapshot] {
        let fm = FileManager.default
        let dir = folder(for: main)
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return subs.compactMap { u -> HistorySnapshot? in
            guard let date = stampFormat.date(from: u.lastPathComponent) else { return nil }
            var files: [String] = []
            if let e = fm.enumerator(at: u, includingPropertiesForKeys: nil) {
                let base = u.standardizedFileURL.path + "/"
                for case let f as URL in e where f.pathExtension == "tex" {
                    files.append(String(f.standardizedFileURL.path.dropFirst(base.count)))
                }
            }
            return HistorySnapshot(id: u, date: date, files: files.sorted())
        }.sorted { $0.date > $1.date }
    }

    struct DiffLine: Identifiable {
        let id: Int
        let kind: TextDiff.Kind?     // nil = lignes identiques repliées
        let text: String
    }

    /// Différences ligne à ligne (ancienne version → texte actuel), avec 3 lignes de contexte.
    static func diffLines(old: String, new: String) -> [DiffLine] {
        let chunks = TextDiff.diff(old.components(separatedBy: "\n"), new.components(separatedBy: "\n"))
        var out: [DiffLine] = []
        func add(_ k: TextDiff.Kind?, _ t: String) { out.append(DiffLine(id: out.count, kind: k, text: t)) }
        for (i, c) in chunks.enumerated() {
            if c.kind == .same {
                let items = c.items
                let first = i == 0, last = i == chunks.count - 1
                if items.count <= 7 || (first && last) && items.count <= 7 {
                    items.forEach { add(.same, $0) }
                } else {
                    let head = first ? [] : Array(items.prefix(3))
                    let tail = last ? [] : Array(items.suffix(3))
                    head.forEach { add(.same, $0) }
                    add(nil, "… \(items.count - head.count - tail.count) ligne(s) identique(s) …")
                    tail.forEach { add(.same, $0) }
                }
            } else {
                c.items.forEach { add(c.kind, $0) }
            }
            if out.count > 4000 { add(nil, "… (différences tronquées)"); break }
        }
        return out
    }
}

// MARK: - Fenêtre Historique

final class HistoryState: ObservableObject {
    @Published var snapshots: [HistorySnapshot] = []
    @Published var selected: HistorySnapshot?
    @Published var file = ""
    @Published var lines: [LatexHistory.DiffLine] = []
    @Published var oldText = ""
    @Published var added = 0
    @Published var removed = 0
}

struct HistorySheet: View {
    @ObservedObject var model: LatexModel
    @StateObject private var h = HistoryState()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM, HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Historique des versions", systemImage: "clock.arrow.circlepath").font(.title3.bold())
                Spacer()
                Text("Une version est gardée à chaque compilation (les \(LatexHistory.keep) dernières).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                List(h.snapshots, selection: Binding(get: { h.selected }, set: { pick($0) })) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.display.string(from: s.date)).font(.callout)
                        Text(s.files.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(s)
                }
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

                VStack(alignment: .leading, spacing: 8) {
                    if let s = h.selected {
                        HStack {
                            if s.files.count > 1 {
                                Picker("Fichier", selection: Binding(get: { h.file }, set: { h.file = $0; loadDiff() })) {
                                    ForEach(s.files, id: \.self) { Text($0).tag($0) }
                                }
                                .frame(maxWidth: 260)
                            } else {
                                Text(h.file).font(.headline)
                            }
                            Spacer()
                            Text("−\(h.removed)").foregroundStyle(Color.red).font(.callout.monospacedDigit())
                            Text("+\(h.added)").foregroundStyle(Color.green).font(.callout.monospacedDigit())
                        }
                        Text("Rouge : présent dans cette version, disparu depuis. Vert : ajouté depuis.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(h.lines) { line in
                                    Text(prefix(line.kind) + line.text)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(line.kind == nil ? Color.secondary : Color.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 6)
                                        .background(background(line.kind))
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    } else {
                        Spacer()
                        Text(h.snapshots.isEmpty ? "Pas encore de version : elles sont créées à chaque compilation." : "Choisis une version à gauche.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    }
                }
                .padding(.leading, 10)
                .frame(minWidth: 420)
            }
            HStack {
                Button("Ouvrir le dossier de l'historique") {
                    if let main = model.texURL { NSWorkspace.shared.open(LatexHistory.folder(for: main)) }
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Fermer") { model.showHistory = false }.keyboardShortcut(.cancelAction)
                Button("Restaurer cette version de \(h.file.isEmpty ? "ce fichier" : (h.file as NSString).lastPathComponent)") { restore() }
                    .buttonStyle(.borderedProminent)
                    .disabled(h.selected == nil || h.file.isEmpty)
                    .help("Remplace le texte dans l'éditeur (⌘Z pour annuler) ; la version actuelle reste dans l'historique")
            }
        }
        .padding(20)
        .frame(width: 900, height: 620)
        .onAppear(perform: reload)
    }

    private func prefix(_ k: TextDiff.Kind?) -> String {
        switch k {
        case .added?: return "+ "
        case .removed?: return "− "
        case .same?: return "  "
        case nil: return "  "
        }
    }

    private func background(_ k: TextDiff.Kind?) -> Color {
        switch k {
        case .added?: return Color.green.opacity(0.16)
        case .removed?: return Color.red.opacity(0.16)
        default: return Color.clear
        }
    }

    private func reload() {
        guard let main = model.texURL else { return }
        model.saveAll()
        LatexHistory.snapshot(main: main, files: model.tabs)    // la version actuelle d'abord, pour pouvoir revenir
        h.snapshots = LatexHistory.list(main: main)
        if h.snapshots.count > 1 { pick(h.snapshots[1]) } else { pick(h.snapshots.first) }
    }

    private func pick(_ s: HistorySnapshot?) {
        h.selected = s
        guard let s = s, let main = model.texURL else { h.lines = []; return }
        let current = LatexHistory.relative(model.currentFile ?? main, to: main)
        h.file = s.files.contains(current) ? current : (s.files.first ?? "")
        loadDiff()
    }

    private func loadDiff() {
        guard let s = h.selected, let main = model.texURL, !h.file.isEmpty else { return }
        let old = (try? String(contentsOf: s.id.appendingPathComponent(h.file), encoding: .utf8)) ?? ""
        let fileURL = main.deletingLastPathComponent().appendingPathComponent(h.file)
        let now = model.text(of: fileURL)
        h.oldText = old
        h.lines = LatexHistory.diffLines(old: old, new: now)
        h.added = h.lines.filter { $0.kind == .added }.count
        h.removed = h.lines.filter { $0.kind == .removed }.count
    }

    private func restore() {
        guard let main = model.texURL, !h.file.isEmpty else { return }
        model.restore(h.oldText, file: main.deletingLastPathComponent().appendingPathComponent(h.file))
    }
}
