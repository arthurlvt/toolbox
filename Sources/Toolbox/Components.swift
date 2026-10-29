import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFCore

extension UTType {
    static let tex = UTType(filenameExtension: "tex") ?? .plainText
}

// MARK: - Travail en arrière-plan

func runInBackground<T>(_ work: @escaping () throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let result = Result<T, Error>(catching: { try work() })
        DispatchQueue.main.async { completion(result) }
    }
}

// MARK: - Messages d'état

struct StatusMessage: Equatable {
    enum Kind { case info, success, error }
    var text: String
    var kind: Kind
    var files: [URL] = []

    static func info(_ text: String) -> StatusMessage { StatusMessage(text: text, kind: .info) }
    static func ok(_ text: String, files: [URL] = []) -> StatusMessage { StatusMessage(text: text, kind: .success, files: files) }
    static func err(_ text: String) -> StatusMessage { StatusMessage(text: text, kind: .error) }
    static func err(_ error: Error) -> StatusMessage { StatusMessage(text: error.localizedDescription, kind: .error) }
}

struct StatusBanner: View {
    let message: StatusMessage?

    var body: some View {
        if let m = message {
            HStack(spacing: 10) {
                Image(systemName: icon(m.kind)).foregroundStyle(color(m.kind))
                Text(m.text).textSelection(.enabled).lineLimit(3)
                Spacer()
                if !m.files.isEmpty {
                    if m.files.count == 1 {
                        Button("Ouvrir") { NSWorkspace.shared.open(m.files[0]) }
                    }
                    Button("Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(m.files)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(color(m.kind).opacity(0.12)))
        }
    }

    private func icon(_ k: StatusMessage.Kind) -> String {
        switch k {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ k: StatusMessage.Kind) -> Color {
        switch k {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        }
    }
}

// MARK: - En-tête d'outil

struct ToolHeader: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(tool.color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.title2.bold())
                Text(tool.subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .tourTarget("header")
    }
}

// MARK: - Sélecteurs de fichiers

enum Panels {
    static func open(_ types: [UTType], multiple: Bool = false) -> [URL] {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.allowsMultipleSelection = multiple
        p.canChooseFiles = true
        p.canChooseDirectories = false
        return p.runModal() == .OK ? p.urls : []
    }

    static func save(suggested name: String, type: UTType, directory: URL? = nil) -> URL? {
        let p = NSSavePanel()
        p.allowedContentTypes = [type]
        p.nameFieldStringValue = name
        p.canCreateDirectories = true
        if let directory = directory { p.directoryURL = directory }
        return p.runModal() == .OK ? p.url : nil
    }

    static func folder(directory: URL? = nil, prompt: String = "Choisir ce dossier") -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = prompt
        if let directory = directory { p.directoryURL = directory }
        return p.runModal() == .OK ? p.url : nil
    }
}

// MARK: - Glisser-déposer de fichiers

enum FileDrop {
    static func accepts(_ url: URL, _ types: [UTType]) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return types.contains { t.conforms(to: $0) }
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var results = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()
        let group = DispatchGroup()
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                results[i] = url
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(results.compactMap { $0 }) }
    }
}

extension View {
    func fileDrop(types: [UTType], isTargeted: Binding<Bool>? = nil,
                  onFiles: @escaping ([URL]) -> Void) -> some View {
        onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            FileDrop.load(providers) { urls in
                let accepted = urls.filter { FileDrop.accepts($0, types) }
                if !accepted.isEmpty { onFiles(accepted) }
            }
            return true
        }
    }
}

final class HoverState: ObservableObject {
    @Published var targeted = false
}

struct DropZone: View {
    let title: String
    var subtitle: String = ""
    let types: [UTType]
    var multiple = true
    let onFiles: ([URL]) -> Void

    @StateObject private var hover = HoverState()
    private var targeted: Bool { hover.targeted }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            Text(title).font(.title3.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button(multiple ? "Choisir des fichiers…" : "Choisir un fichier…") {
                let urls = Panels.open(types, multiple: multiple)
                if !urls.isEmpty { onFiles(urls) }
            }
            .controlSize(.large)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(targeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
        .fileDrop(types: types, isTargeted: $hover.targeted) { urls in
            onFiles(multiple ? urls : Array(urls.prefix(1)))
        }
    }
}

// MARK: - Liste de fichiers

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let size: Int64
    let pageCount: Int?

    init(_ url: URL) {
        self.url = url
        self.size = FileUtils.size(url)
        self.pageCount = url.pathExtension.lowercased() == "pdf" ? PDFDocument(url: url)?.pageCount : nil
    }

    var name: String { url.lastPathComponent }

    var details: String {
        var parts: [String] = []
        if let n = pageCount { parts.append("\(n) page\(n > 1 ? "s" : "")") }
        parts.append(FileUtils.formatBytes(size))
        return parts.joined(separator: " · ")
    }
}

struct FileRow: View {
    let item: FileItem
    var trailing: String? = nil
    var trailingColor: Color = .secondary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.pageCount != nil ? "doc.richtext.fill" : "photo.fill")
                .font(.title2)
                .foregroundStyle(item.pageCount != nil ? Color.red : Color.teal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let t = trailing {
                Text(t).font(.callout.monospacedDigit()).foregroundStyle(trailingColor)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Carte « fichier choisi » avec bouton pour en changer.
struct ChosenFileCard: View {
    let item: FileItem
    let types: [UTType]
    let onChange: (URL) -> Void

    var body: some View {
        HStack {
            FileRow(item: item)
            Button("Changer…") {
                if let u = Panels.open(types).first { onChange(u) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .fileDrop(types: types) { if let u = $0.first { onChange(u) } }
    }
}

// MARK: - Aperçu PDF

struct PDFPreview: NSViewRepresentable {
    let url: URL?
    let reloadToken: Int

    final class Coordinator {
        var token = Int.min
        var url: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let c = context.coordinator
        guard c.token != reloadToken || c.url != url else { return }
        c.token = reloadToken
        c.url = url

        // On garde la page affichée après une recompilation.
        var pageIndex = 0
        if let doc = view.document, let current = view.currentPage {
            pageIndex = doc.index(for: current)
        }
        guard let url = url, let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            view.document = nil
            return
        }
        view.document = doc
        if let page = doc.page(at: min(pageIndex, doc.pageCount - 1)) {
            view.go(to: page)
        }
    }
}
