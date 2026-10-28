import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFCore

final class OrganizeModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let page: PDFPage
        var thumbnail: NSImage
    }

    @Published var items: [Item] = []
    @Published var selection: Set<UUID> = []
    @Published var sourceURL: URL?
    @Published var modified = false
    @Published var status: StatusMessage?
    /// Page en cours de glisser-déposer.
    var dragging: UUID?

    /// Garde les documents source en vie tant que leurs pages sont affichées.
    private var documents: [PDFDocument] = []
    private var anchor: UUID?

    static func thumbnail(_ page: PDFPage) -> NSImage {
        page.thumbnail(of: NSSize(width: 200, height: 260), for: .cropBox)
    }

    private func makeItems(_ doc: PDFDocument) -> [Item] {
        PDFOps.pages(of: doc).map { Item(page: $0, thumbnail: Self.thumbnail($0)) }
    }

    // MARK: Fichiers

    func open(_ url: URL) {
        do {
            let doc = try PDFOps.open(url)
            documents = [doc]
            items = makeItems(doc)
            selection = []
            anchor = nil
            sourceURL = url
            modified = false
            status = .info("\(items.count) pages. Glisse les miniatures pour les réordonner ; ⌘-clic et ⇧-clic pour sélectionner plusieurs pages.")
        } catch {
            status = .err(error)
        }
    }

    func append(_ urls: [URL]) {
        guard !items.isEmpty else {
            if let first = urls.first { open(first) }
            if urls.count > 1 { append(Array(urls.dropFirst())) }
            return
        }
        var added = 0
        for url in urls {
            do {
                let doc = try PDFOps.open(url)
                documents.append(doc)
                let new = makeItems(doc)
                items += new
                added += new.count
            } catch {
                status = .err(error)
                return
            }
        }
        modified = true
        status = .ok("\(added) page(s) ajoutée(s) à la fin.")
    }

    func close() {
        items = []
        selection = []
        documents = []
        sourceURL = nil
        modified = false
        status = nil
    }

    // MARK: Sélection

    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    var selectedIndices: [Int] { items.indices.filter { selection.contains(items[$0].id) } }

    func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let a = anchor, let i = index(of: a), let j = index(of: id) {
            selection = Set(items[min(i, j)...max(i, j)].map(\.id))
        } else {
            selection = selection == [id] ? [] : [id]
            anchor = id
        }
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    // MARK: Édition

    func rotate(_ degrees: Int) {
        let targets = selection.isEmpty ? Array(items.indices) : selectedIndices
        for i in targets {
            let page = items[i].page
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
            items[i].thumbnail = Self.thumbnail(page)
        }
        modified = true
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        let n = selection.count
        items.removeAll { selection.contains($0.id) }
        selection = []
        modified = true
        status = .info("\(n) page(s) supprimée(s). Pense à enregistrer.")
    }

    func reverse() {
        items.reverse()
        modified = true
    }

    func move(_ dragged: UUID, onto target: UUID) {
        guard dragged != target, let from = index(of: dragged), let to = index(of: target) else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        modified = true
    }

    // MARK: Enregistrement

    func save(selectionOnly: Bool) {
        let pages = selectionOnly ? selectedIndices.map { items[$0].page } : items.map(\.page)
        guard !pages.isEmpty else { return }
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "document"
        let name = selectionOnly ? "\(base)_extrait.pdf" : "\(base)_modifié.pdf"
        guard let url = Panels.save(suggested: name, type: .pdf,
                                    directory: sourceURL?.deletingLastPathComponent()) else { return }
        do {
            try PDFOps.save(PDFOps.makeDocument(from: pages), to: url)
            if !selectionOnly { modified = false }
            status = .ok("Enregistré : \(url.lastPathComponent) (\(pages.count) pages)", files: [url])
        } catch {
            status = .err(error)
        }
    }
}

struct OrganizeToolView: View {
    @ObservedObject var model: OrganizeModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .organize)
            if model.items.isEmpty {
                DropZone(title: "Dépose un PDF à organiser",
                         subtitle: "Réordonne, fais pivoter, supprime ou extrais des pages. Tu peux ensuite ajouter les pages d'autres PDF.",
                         types: [.pdf], multiple: false) { urls in
                    if let u = urls.first { model.open(u) }
                }
                Spacer()
            } else {
                toolbar
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.items) { item in
                            cell(item)
                        }
                    }
                    .padding(6)
                    .animation(.easeInOut(duration: 0.15), value: model.items.map(\.id))
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
                .fileDrop(types: [.pdf]) { model.append($0) }
            }
            StatusBanner(message: model.status)
        }
        .padding(20)
    }

    private func cell(_ item: OrganizeModel.Item) -> some View {
        let number = (model.index(of: item.id) ?? 0) + 1
        let selected = model.selection.contains(item.id)
        return PageCell(image: item.thumbnail, number: number, selected: selected)
            .onTapGesture { model.click(item.id) }
            .onDrag {
                model.dragging = item.id
                return NSItemProvider(object: item.id.uuidString as NSString)
            }
            .onDrop(of: [UTType.text], delegate: ReorderDelegate(target: item.id, model: model))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sourceURL?.lastPathComponent ?? "Document")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(model.items.count) pages · \(model.selection.count) sélectionnée(s)\(model.modified ? " · non enregistré" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                Button { model.rotate(-90) } label: { Label("Gauche", systemImage: "rotate.left") }
                    .help("Pivoter à gauche (la sélection, ou tout si rien n'est sélectionné)")
                Button { model.rotate(90) } label: { Label("Droite", systemImage: "rotate.right") }
                    .help("Pivoter à droite (la sélection, ou tout si rien n'est sélectionné)")
                Button(role: .destructive) { model.deleteSelected() } label: { Label("Supprimer", systemImage: "trash") }
                    .disabled(model.selection.isEmpty)
                    .keyboardShortcut(.delete, modifiers: [])
                Button { model.selectAll() } label: { Label("Tout", systemImage: "checkmark.circle") }
                    .keyboardShortcut("a")
            }
            Menu {
                Button("Ajouter les pages d'un autre PDF…") {
                    let urls = Panels.open([.pdf], multiple: true)
                    if !urls.isEmpty { model.append(urls) }
                }
                Button("Inverser l'ordre des pages") { model.reverse() }
                Divider()
                Button("Ouvrir un autre PDF…") {
                    if let u = Panels.open([.pdf]).first { model.open(u) }
                }
                Button("Fermer le document") { model.close() }
            } label: {
                Label("Plus", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            Button { model.save(selectionOnly: true) } label: {
                Label("Extraire", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(model.selection.isEmpty)
            .help("Enregistrer uniquement les pages sélectionnées dans un nouveau PDF")
            Button { model.save(selectionOnly: false) } label: {
                Label("Enregistrer…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s")
        }
        .labelStyle(.titleAndIcon)
    }
}

struct PageCell: View {
    let image: NSImage
    let number: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 190)
                .shadow(color: Color.black.opacity(0.2), radius: 3, y: 1)
            Text("\(number)")
                .font(.caption.monospacedDigit().weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

struct ReorderDelegate: DropDelegate {
    let target: UUID
    let model: OrganizeModel

    func dropEntered(info: DropInfo) {
        guard let d = model.dragging else { return }
        model.move(d, onto: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        model.dragging = nil
        return true
    }
}
