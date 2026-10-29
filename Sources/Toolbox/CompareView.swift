import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFCore

final class CompareStore: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case overlay = "Superposition", sideBySide = "Côte à côte", text = "Texte"
        var id: String { rawValue }
    }

    @Published var oldURL: URL?
    @Published var newURL: URL?
    @Published var pairs: [PagePair] = []
    @Published var selected: Int?
    @Published var mode: Mode = .overlay
    @Published var running = false
    @Published var progress = 0.0
    @Published var status: StatusMessage?
    @Published var onlyChanges = true

    @Published var overlayImage: NSImage?
    @Published var oldImage: NSImage?
    @Published var newImage: NSImage?
    @Published var rendering = false

    var visiblePairs: [PagePair] { onlyChanges ? pairs.filter { $0.kind != .identical } : pairs }
    var current: PagePair? { pairs.first { $0.id == selected } }
    var changedCount: Int { pairs.filter { $0.kind != .identical }.count }

    func set(old: URL) { oldURL = old; reset() }
    func set(new: URL) { newURL = new; reset() }

    func swap() {
        (oldURL, newURL) = (newURL, oldURL)
        reset()
    }

    private func reset() {
        pairs = []
        selected = nil
        overlayImage = nil
        oldImage = nil
        newImage = nil
        status = nil
    }

    func compare() {
        guard let a = oldURL, let b = newURL else { return }
        running = true
        progress = 0
        status = .info("Comparaison en cours…")
        runInBackground({ [weak self] in
            try PDFCompare.compare(old: a, new: b) { p in DispatchQueue.main.async { self?.progress = p } }
        }) { [weak self] r in
            guard let self = self else { return }
            self.running = false
            switch r {
            case .success(let pairs):
                self.pairs = pairs
                let n = self.changedCount
                self.status = n == 0
                    ? .ok("Les deux PDF sont identiques (\(pairs.count) page(s)).")
                    : .ok("\(n) page(s) différente(s) sur \(pairs.count).")
                self.select((self.visiblePairs.first ?? pairs.first)?.id)
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    func select(_ id: Int?) {
        selected = id
        overlayImage = nil
        oldImage = nil
        newImage = nil
        guard let p = current, let a = oldURL, let b = newURL else { return }
        rendering = true
        runInBackground({ () -> (CGImage?, CGImage?, CGImage?) in
            let da = PDFDocument(url: a), db = PDFDocument(url: b)
            let pa = p.old.flatMap { da?.page(at: $0) }
            let pb = p.new.flatMap { db?.page(at: $0) }
            return (PDFCompare.overlay(old: pa, new: pb),
                    PDFCompare.render(pa, partner: pb),
                    PDFCompare.render(pb, partner: pa))
        }) { [weak self] r in
            guard let self = self, self.selected == id else { return }
            self.rendering = false
            if case .success(let (o, oa, ob)) = r {
                self.overlayImage = o.map { NSImage(cgImage: $0, size: .zero) }
                self.oldImage = p.old == nil ? nil : oa.map { NSImage(cgImage: $0, size: .zero) }
                self.newImage = p.new == nil ? nil : ob.map { NSImage(cgImage: $0, size: .zero) }
            }
        }
    }

    func exportReport() {
        guard let a = oldURL, let b = newURL, !pairs.isEmpty,
              let out = Panels.save(suggested: "comparaison-\(b.deletingPathExtension().lastPathComponent).pdf",
                                    type: .pdf, directory: b.deletingLastPathComponent()) else { return }
        let pairs = self.pairs
        status = .info("Rapport en cours…")
        runInBackground({ try PDFCompare.report(old: a, new: b, pairs: pairs, to: out) }) { [weak self] r in
            switch r {
            case .success: self?.status = .ok("Rapport enregistré : \(out.lastPathComponent)", files: [out])
            case .failure(let e): self?.status = .err(e)
            }
        }
    }
}

struct CompareToolView: View {
    @ObservedObject var s: CompareStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .compare)
            HStack(spacing: 12) {
                filePicker("Ancienne version", url: s.oldURL, color: .red) { s.set(old: $0) }
                Button { s.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Inverser")
                    .disabled(s.oldURL == nil && s.newURL == nil)
                filePicker("Nouvelle version", url: s.newURL, color: .green) { s.set(new: $0) }
                Button { s.compare() } label: { Label("Comparer", systemImage: "plus.forwardslash.minus") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(s.oldURL == nil || s.newURL == nil || s.running)
            }
            if s.running {
                ProgressView(value: s.progress).progressViewStyle(.linear)
            }
            if s.pairs.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.doc").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                    Text("Choisis (ou dépose) deux versions d'un même PDF : poly mis à jour, rapport corrigé, sujet modifié…")
                        .foregroundStyle(.secondary)
                    Text("Les pages sont appariées même si des pages ont été ajoutées ou retirées.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HSplitView {
                    pageList.frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
                    detail.frame(minWidth: 480)
                }
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
    }

    private func filePicker(_ title: String, url: URL?, color: Color, onPick: @escaping (URL) -> Void) -> some View {
        Button {
            if let u = Panels.open([.pdf]).first { onPick(u) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext.fill").foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(url?.lastPathComponent ?? "Choisir un PDF…").font(.callout.weight(.medium)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .fileDrop(types: [.pdf]) { if let u = $0.first { onPick(u) } }
    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Seulement les pages qui changent", isOn: $s.onlyChanges).toggleStyle(.checkbox)
            List(s.visiblePairs, selection: Binding(get: { s.selected }, set: { s.select($0) })) { p in
                HStack(spacing: 8) {
                    badge(p.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.label).font(.callout.weight(.medium))
                        Text(summary(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tag(p.id)
            }
            Button { s.exportReport() } label: { Label("Exporter le rapport PDF…", systemImage: "square.and.arrow.up") }
                .disabled(s.changedCount == 0)
        }
    }

    private func badge(_ k: PagePair.Kind) -> some View {
        let (icon, color): (String, Color) = {
            switch k {
            case .identical: return ("equal.circle.fill", .secondary)
            case .modified: return ("pencil.circle.fill", .orange)
            case .added: return ("plus.circle.fill", .green)
            case .removed: return ("minus.circle.fill", .red)
            }
        }()
        return Image(systemName: icon).foregroundStyle(color)
    }

    private func summary(_ p: PagePair) -> String {
        switch p.kind {
        case .identical: return "identique"
        case .added: return "page ajoutée"
        case .removed: return "page supprimée"
        case .modified:
            let parts = [p.removedText.isEmpty ? nil : "−\(p.removedText.count)",
                         p.addedText.isEmpty ? nil : "+\(p.addedText.count)"].compactMap { $0 }
            return (parts.isEmpty ? "mise en page" : parts.joined(separator: " ") + " passage(s)")
                + String(format: " · %.1f %% de la page", p.changedRatio * 100)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $s.mode) {
                ForEach(CompareStore.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            switch s.mode {
            case .overlay:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) {
                        legend(.red, "supprimé")
                        legend(.green, "ajouté")
                        legend(.orange, "modifié")
                        legend(.yellow, "zone touchée")
                    }
                    .font(.caption)
                    imageView(s.overlayImage)
                }
            case .sideBySide:
                HStack(spacing: 8) {
                    VStack(spacing: 4) { Text("Ancienne").font(.caption).foregroundStyle(Color.red); imageView(s.oldImage) }
                    VStack(spacing: 4) { Text("Nouvelle").font(.caption).foregroundStyle(Color.green); imageView(s.newImage) }
                }
            case .text:
                textDiff
            }
        }
        .padding(.leading, 10)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 12, height: 10); Text(t) }
    }

    private func imageView(_ img: NSImage?) -> some View {
        ZStack {
            Color.primary.opacity(0.04)
            if let img = img {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: img).resizable().scaledToFit().frame(minWidth: 300)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .padding(8)
                }
            } else if s.rendering {
                ProgressView()
            } else {
                Text("Pas de page de ce côté.").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var textDiff: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let p = s.current {
                    if p.removedText.isEmpty && p.addedText.isEmpty {
                        Text(p.kind == .identical ? "Texte identique." : "Aucune différence de texte (changement de mise en page, d'image ou de formule).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(p.removedText.enumerated()), id: \.offset) { _, t in
                        Text("− " + t).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)))
                    }
                    ForEach(Array(p.addedText.enumerated()), id: \.offset) { _, t in
                        Text("+ " + t).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.12)))
                    }
                }
            }
            .padding(4)
        }
    }
}
