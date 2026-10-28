import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFCore

/// Signature enregistrée (PNG à fond transparent).
struct SavedSignature: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let image: NSImage
}

/// Une signature posée sur une page, en points (origine en haut à gauche de la page affichée).
struct PlacedSignature: Identifiable, Equatable {
    let id = UUID()
    var page: Int
    var rect: CGRect
}

final class SignStore: ObservableObject {
    @Published var pdfURL: URL?
    @Published var doc: PDFDocument?
    @Published var page = 0
    @Published var pageImage: NSImage?
    @Published var signatures: [SavedSignature] = []
    @Published var selected: SavedSignature?
    @Published var placed: [PlacedSignature] = []
    @Published var status: StatusMessage?
    @Published var showPad = false

    // Tracé en cours dans la fenêtre « Dessiner »
    @Published var strokes: [[CGPoint]] = []
    @Published var inkBlue = true
    var dragOrigin: [UUID: CGRect] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/Signatures", isDirectory: true)
    }

    init() { loadSignatures() }

    var pageSize: CGSize {
        guard let p = doc?.page(at: page) else { return CGSize(width: 595, height: 842) }
        return PageDrawing.displaySize(p)
    }

    // MARK: Signatures

    func loadSignatures() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        signatures = files.filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { u in NSImage(contentsOf: u).map { SavedSignature(url: u, image: $0) } }
        if selected == nil || !signatures.contains(where: { $0.url == selected?.url }) { selected = signatures.first }
    }

    func deleteSignature(_ s: SavedSignature) {
        try? FileManager.default.trashItem(at: s.url, resultingItemURL: nil)
        loadSignatures()
    }

    private func store(_ cg: CGImage) {
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.folder.appendingPathComponent("signature-\(f.string(from: Date())).png")
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: url)
        loadSignatures()
        selected = signatures.first { $0.url == url }
    }

    /// Image importée (photo ou scan d'une signature sur papier blanc) : le blanc devient transparent.
    func importImage(_ url: URL) {
        guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let clean = Self.removeWhite(cg) else {
            status = .err("Image illisible.")
            return
        }
        store(clean)
        status = .ok("Signature importée.")
    }

    static func removeWhite(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        let made: CGImage? = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = buf.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let lum = (Int(p[i]) * 3 + Int(p[i + 1]) * 6 + Int(p[i + 2])) / 10
                    if lum > 200 || p[i + 3] < 30 {
                        p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0
                    } else {
                        // encre : on garde la couleur, opacité selon la noirceur (bords adoucis)
                        let a = UInt8(min(255, (200 - lum) * 255 / 120))
                        p[i + 3] = max(p[i + 3] == 255 ? a : p[i + 3], 0)
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            return ctx.makeImage()
        }
        guard let full = made, maxX >= minX, maxY >= minY else { return nil }
        let pad = 6
        let crop = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                          width: min(w, maxX + pad) - max(0, minX - pad), height: min(h, maxY + pad) - max(0, minY - pad))
        return full.cropping(to: crop) ?? full
    }

    /// Tracé dessiné au trackpad → PNG transparent, recadré.
    func savePad(canvas: CGSize) {
        let points = strokes.flatMap { $0 }
        guard points.count > 3 else { return }
        let scale: CGFloat = 3
        let xs = points.map { $0.x }, ys = points.map { $0.y }
        let box = CGRect(x: xs.min()! - 8, y: ys.min()! - 8, width: xs.max()! - xs.min()! + 16, height: ys.max()! - ys.min()! + 16)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(3.2)
        ctx.setStrokeColor(inkBlue ? CGColor(red: 0.09, green: 0.18, blue: 0.55, alpha: 1) : CGColor(gray: 0.08, alpha: 1))
        for s in strokes where s.count > 1 {
            ctx.addPath(Self.smooth(s))
            ctx.strokePath()
        }
        if let img = ctx.makeImage() {
            store(img)
            strokes = []
            showPad = false
            status = .ok("Signature enregistrée : clique sur la page pour la poser.")
        }
    }

    /// Lissage du tracé (courbes passant par les milieux des segments).
    static func smooth(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            pts.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    // MARK: PDF

    func open(_ url: URL) {
        guard let d = PDFDocument(url: url), !d.isLocked else {
            status = .err("PDF illisible ou protégé par un mot de passe.")
            return
        }
        pdfURL = url
        doc = d
        placed = []
        page = 0
        status = nil
        RecentFiles.add(url)
        renderPage()
    }

    func go(_ delta: Int) {
        guard let d = doc else { return }
        page = max(0, min(d.pageCount - 1, page + delta))
        renderPage()
    }

    func renderPage() {
        guard let p = doc?.page(at: page) else { pageImage = nil; return }
        let idx = page
        runInBackground({ Converter.render(p, dpi: 130) }) { [weak self] r in
            guard let self = self, self.page == idx else { return }
            if case .success(let cg?) = r { self.pageImage = NSImage(cgImage: cg, size: .zero) }
        }
    }

    /// Clic sur la page : on pose la signature choisie, centrée sur le clic.
    func place(at point: CGPoint) {
        guard let sig = selected else {
            status = .info("Dessine ou importe d'abord une signature (à gauche).")
            return
        }
        let ratio = sig.image.size.height / max(1, sig.image.size.width)
        let width = min(170, pageSize.width * 0.35)
        let size = CGSize(width: width, height: width * ratio)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            placed.append(PlacedSignature(page: page, rect: clamp(rect)))
        }
    }

    func clamp(_ r: CGRect) -> CGRect {
        let s = pageSize
        var r = r
        r.origin.x = max(0, min(s.width - r.width, r.origin.x))
        r.origin.y = max(0, min(s.height - r.height, r.origin.y))
        return r
    }

    func remove(_ p: PlacedSignature) {
        withAnimation { placed.removeAll { $0.id == p.id } }
    }

    func update(_ id: UUID, _ change: (inout CGRect) -> Void) {
        guard let i = placed.firstIndex(where: { $0.id == id }) else { return }
        var r = placed[i].rect
        change(&r)
        placed[i].rect = clamp(r)
    }

    func export() {
        guard let input = pdfURL, let sig = selected else { return }
        guard !placed.isEmpty else {
            status = .info("Clique sur la page pour poser ta signature avant d'enregistrer.")
            return
        }
        guard let cg = sig.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let out = Panels.save(suggested: input.deletingPathExtension().lastPathComponent + " (signé).pdf",
                                    type: .pdf, directory: input.deletingLastPathComponent()) else { return }
        let placements = placed.map { SignaturePlacement(page: $0.page, rect: $0.rect) }
        status = .info("Enregistrement…")
        runInBackground({ try Signature.apply(input, image: cg, placements: placements, to: out) }) { [weak self] r in
            switch r {
            case .success:
                self?.status = .ok("PDF signé enregistré : \(out.lastPathComponent)", files: [out])
                ToastCenter.shared.show("PDF signé ✍️", cheer: true)
            case .failure(let e):
                self?.status = .err(e)
            }
        }
    }
}

// MARK: - Vue

struct SignToolView: View {
    @ObservedObject var s: SignStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(tool: .sign)
            HSplitView {
                library.frame(minWidth: 200, idealWidth: 230, maxWidth: 300)
                pageArea.frame(minWidth: 420)
            }
            StatusBanner(message: s.status)
        }
        .padding(20)
        .sheet(isPresented: $s.showPad) { SignaturePad(s: s) }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mes signatures").font(.headline)
            Button { s.strokes = []; s.showPad = true } label: {
                Label("Dessiner une signature…", systemImage: "signature")
            }
            Button {
                if let u = Panels.open([.image]).first { s.importImage(u) }
            } label: { Label("Importer une image…", systemImage: "photo") }
                .help("Photo ou scan d'une signature sur papier blanc : le fond est retiré automatiquement")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(s.signatures) { sig in
                        Image(nsImage: sig.image)
                            .resizable().scaledToFit()
                            .frame(height: 54)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(s.selected == sig ? Color.accentColor : Color.primary.opacity(0.12),
                                        lineWidth: s.selected == sig ? 2.5 : 1))
                            .contentShape(Rectangle())
                            .onTapGesture { s.selected = sig }
                            .contextMenu { Button("Supprimer") { s.deleteSignature(sig) } }
                    }
                }
                .padding(2)
            }
            Text("Tes signatures restent sur ce Mac.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.trailing, 10)
    }

    private var pageArea: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    if let u = Panels.open([.pdf]).first { s.open(u) }
                } label: { Label(s.pdfURL?.lastPathComponent ?? "Choisir un PDF…", systemImage: "doc.richtext") }
                Spacer()
                if let d = s.doc {
                    Button { s.go(-1) } label: { Image(systemName: "chevron.left") }.disabled(s.page == 0)
                    Text("Page \(s.page + 1) / \(d.pageCount)").monospacedDigit()
                    Button { s.go(1) } label: { Image(systemName: "chevron.right") }.disabled(s.page >= d.pageCount - 1)
                }
                Spacer()
                Button { s.export() } label: { Label("Enregistrer le PDF signé…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .disabled(s.doc == nil || s.placed.isEmpty)
            }
            if s.doc == nil {
                DropZone(title: "Dépose le PDF à signer", subtitle: "Puis clique sur la page à l'endroit où signer.",
                         types: [.pdf], multiple: false) { urls in if let u = urls.first { s.open(u) } }
            } else {
                GeometryReader { geo in
                    let size = s.pageSize
                    let k = min(geo.size.width / size.width, geo.size.height / size.height)
                    ZStack(alignment: .topLeading) {
                        if let img = s.pageImage {
                            Image(nsImage: img).resizable().frame(width: size.width * k, height: size.height * k)
                        } else {
                            Color.white
                        }
                        ForEach(s.placed.filter { $0.page == s.page }) { p in
                            placedView(p, k: k)
                        }
                    }
                    .frame(width: size.width * k, height: size.height * k)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { loc in
                        s.place(at: CGPoint(x: loc.x / k, y: loc.y / k))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("Clic : poser · glisser : déplacer · coin bleu : agrandir · ✕ : retirer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func placedView(_ p: PlacedSignature, k: CGFloat) -> some View {
        let r = p.rect
        return ZStack(alignment: .bottomTrailing) {
            if let sig = s.selected {
                Image(nsImage: sig.image).resizable()
            }
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            // poignée de redimensionnement
            Circle().fill(Color.accentColor).frame(width: 14, height: 14)
                .offset(x: 7, y: 7)
                .gesture(DragGesture().onChanged { v in
                    if s.dragOrigin[p.id] == nil { s.dragOrigin[p.id] = r }
                    let o = s.dragOrigin[p.id]!
                    let ratio = o.height / max(1, o.width)
                    let w = max(40, o.width + v.translation.width / k)
                    s.update(p.id) { $0.size = CGSize(width: w, height: w * ratio) }
                }.onEnded { _ in s.dragOrigin[p.id] = nil })
        }
        .overlay(alignment: .topTrailing) {
            Button { s.remove(p) } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.red)
            }
            .buttonStyle(.plain)
            .offset(x: 8, y: -8)
        }
        .frame(width: r.width * k, height: r.height * k)
        .contentShape(Rectangle())
        .onTapGesture {}          // un clic sur une signature posée n'en ajoute pas une autre
        .gesture(DragGesture().onChanged { v in
            if s.dragOrigin[p.id] == nil { s.dragOrigin[p.id] = r }
            let o = s.dragOrigin[p.id]!
            s.update(p.id) { $0.origin = CGPoint(x: o.minX + v.translation.width / k, y: o.minY + v.translation.height / k) }
        }.onEnded { _ in s.dragOrigin[p.id] = nil })
        .offset(x: r.minX * k, y: r.minY * k)
        .transition(.scale.combined(with: .opacity))
    }
}

/// Fenêtre pour dessiner sa signature au trackpad ou à la souris.
struct SignaturePad: View {
    @ObservedObject var s: SignStore
    static let size = CGSize(width: 560, height: 220)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dessine ta signature").font(.title3.bold())
            Text("Au trackpad : clique-glisse (ou appuie fort) en traçant. Tu peux lever le doigt entre les lettres.")
                .font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.white)
                Path { p in
                    p.move(to: CGPoint(x: 30, y: Self.size.height - 50))
                    p.addLine(to: CGPoint(x: Self.size.width - 30, y: Self.size.height - 50))
                }
                .stroke(Color.gray.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                Canvas { ctx, _ in
                    for stroke in s.strokes where stroke.count > 1 {
                        ctx.stroke(Path(SignStore.smooth(stroke)),
                                   with: .color(s.inkBlue ? Color(red: 0.09, green: 0.18, blue: 0.55) : .black),
                                   style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                    }
                }
                if s.strokes.isEmpty {
                    Text("Signe ici").font(.title2).foregroundStyle(Color.gray.opacity(0.4))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.15)))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    if v.translation == .zero || s.strokes.isEmpty || isNewStroke(v) {
                        s.strokes.append([v.location])
                    } else {
                        s.strokes[s.strokes.count - 1].append(v.location)
                    }
                }
                .onEnded { _ in s.strokes.append([]) })
            HStack {
                Picker("", selection: $s.inkBlue) {
                    Text("Encre bleue").tag(true)
                    Text("Encre noire").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Button("Effacer") { s.strokes = [] }
                Spacer()
                Button("Annuler") { s.strokes = []; s.showPad = false }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { s.savePad(canvas: Self.size) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(s.strokes.flatMap { $0 }.count < 4)
            }
        }
        .padding(20)
    }

    /// Le dernier trait est terminé (tableau vide ajouté à la fin du geste) : on en commence un nouveau.
    private func isNewStroke(_ v: DragGesture.Value) -> Bool {
        s.strokes.last?.isEmpty == true
    }
}
