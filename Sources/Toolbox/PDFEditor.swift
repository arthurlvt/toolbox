import SwiftUI
import AppKit
import PDFKit
import CoreText
import UniformTypeIdentifiers
import PDFCore

// MARK: - Éditeur de PDF
//
// Tout ce qu'on ajoute est une annotation PDFKit posée sur la page : on peut la déplacer, la redimensionner,
// la modifier ou la supprimer jusqu'à l'enregistrement. « Enregistrer » aplatit tout dans une copie
// (PDFEdit.flatten) ; les caches blancs y suppriment vraiment le texte d'origine.

enum EditTool: String, CaseIterable, Identifiable {
    case select, text, editText, note, highlight, underline, strike, ink, rect, ellipse, arrow, whiteout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Sélectionner"
        case .text: return "Texte"
        case .editText: return "Modifier le texte"
        case .note: return "Post-it"
        case .highlight: return "Surligner"
        case .underline: return "Souligner"
        case .strike: return "Barrer"
        case .ink: return "Dessin"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Flèche"
        case .whiteout: return "Cache blanc"
        }
    }

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .editText: return "character.cursor.ibeam"
        case .note: return "note.text"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strike: return "strikethrough"
        case .ink: return "scribble"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .whiteout: return "eraser"
        }
    }

    /// Raccourci clavier (sans modificateur, quand le PDF a le focus).
    var key: String {
        switch self {
        case .select: return "v"
        case .text: return "t"
        case .editText: return "m"
        case .note: return "n"
        case .highlight: return "h"
        case .underline: return "u"
        case .strike: return "b"
        case .ink: return "d"
        case .rect: return "r"
        case .ellipse: return "o"
        case .arrow: return "f"
        case .whiteout: return "e"
        }
    }

    var help: String {
        switch self {
        case .select: return "Cliquer pour sélectionner, glisser pour déplacer, poignée pour redimensionner, double-clic pour modifier un texte (V)"
        case .text: return "Clique où écrire (T)"
        case .editText: return "Sélectionne une phrase du PDF : elle est effacée et remplacée par un texte modifiable (M)"
        case .note: return "Post-it jaune, clique où le poser (N)"
        case .highlight: return "Sélectionne du texte à surligner (H)"
        case .underline: return "Sélectionne du texte à souligner (U)"
        case .strike: return "Sélectionne du texte à barrer (B)"
        case .ink: return "Dessine à main levée (D)"
        case .rect: return "Glisse pour tracer un rectangle (R)"
        case .ellipse: return "Glisse pour tracer une ellipse (O)"
        case .arrow: return "Glisse pour tracer une flèche (F)"
        case .whiteout: return "Glisse sur une zone à cacher : le texte dessous est vraiment supprimé à l'enregistrement (E)"
        }
    }

    var picksText: Bool { [.highlight, .underline, .strike, .editText].contains(self) }
    var drags: Bool { [.ink, .rect, .ellipse, .arrow, .whiteout].contains(self) }
}

/// Image posée sur une page (dessinée par nos soins, aplatie à l'enregistrement).
final class ImageAnnotation: PDFAnnotation {
    var image: CGImage?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let img = image else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(img, in: bounds)
        context.restoreGState()
    }
}

enum EditUndo {
    case added([(PDFAnnotation, PDFPage)])
    case removed([(PDFAnnotation, PDFPage)])
    case bounds(PDFAnnotation, CGRect)
    case text(PDFAnnotation, String?, CGRect)
    case rotated(PDFPage, Int)
    case pageRemoved(PDFPage, Int)
    case pageInserted(PDFPage)
}

final class EditStore: ObservableObject {
    @Published var url: URL?
    @Published var doc: PDFDocument?
    @Published var tool: EditTool = .select { didSet { view?.toolChanged() } }
    @Published var colorIndex = 1 { didSet { applyStyle() } }
    @Published var lineWidth: CGFloat = 2 { didSet { applyStyle() } }
    @Published var fontSize: CGFloat = 14 { didSet { applyStyle() } }
    @Published var selected: PDFAnnotation?
    @Published var dirty = false
    @Published var busy = false
    @Published var status: StatusMessage?
    @Published var canUndo = false
    /// Dernier PDF libéré en quittant l'éditeur (pour le reprendre d'un clic).
    @Published var lastURL: URL?

    weak var view: EditorPDFView?
    private var undoStack: [EditUndo] = [] { didSet { canUndo = !undoStack.isEmpty } }
    /// Annotations à cacher pour de vrai à l'enregistrement.
    static let redactTag = "toolbox.cache"

    static let palette: [(String, NSColor)] = [
        ("Noir", .black),
        ("Rouge", NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)),
        ("Bleu", NSColor(srgbRed: 0.10, green: 0.35, blue: 0.85, alpha: 1)),
        ("Vert", NSColor(srgbRed: 0.10, green: 0.60, blue: 0.25, alpha: 1)),
        ("Orange", NSColor(srgbRed: 0.95, green: 0.55, blue: 0.10, alpha: 1)),
        ("Jaune", NSColor(srgbRed: 1.00, green: 0.85, blue: 0.10, alpha: 1)),
        ("Violet", NSColor(srgbRed: 0.55, green: 0.25, blue: 0.80, alpha: 1)),
        ("Blanc", .white),
    ]
    static let widths: [CGFloat] = [1, 2, 3, 5, 8]
    static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 40]

    /// Même police à une autre taille (garde aussi les polices embarquées du PDF, que le nom seul ne retrouve pas).
    static func resized(_ f: NSFont, _ size: CGFloat) -> NSFont {
        CTFontCreateCopyWithAttributes(f as CTFont, size, nil, nil) as NSFont
    }

    var color: NSColor { Self.palette[min(max(colorIndex, 0), Self.palette.count - 1)].1 }
    /// Surligneur : jaune si la couleur choisie est du noir ou du blanc.
    var highlightColor: NSColor {
        (colorIndex == 0 || colorIndex == 7 ? Self.palette[5].1 : color).withAlphaComponent(0.45)
    }
    var hasImages: Bool {
        guard let d = doc else { return false }
        return (0..<d.pageCount).contains { i in d.page(at: i)?.annotations.contains { $0 is ImageAnnotation } ?? false }
    }

    // MARK: Fichier

    func open(_ u: URL) {
        if dirty, !confirmDestructive("Abandonner les modifications ?", "Les modifications de « \(url?.lastPathComponent ?? "") » n'ont pas été enregistrées.", button: "Abandonner") { return }
        guard let d = PDFDocument(url: u) else { status = .err("PDF illisible."); return }
        if d.isLocked {
            status = .err("Ce PDF est protégé par un mot de passe : retire-le d'abord (Sécurité & infos).")
            return
        }
        view?.endEditing()
        url = u
        doc = d
        selected = nil
        undoStack = []
        dirty = false
        tool = .select
        status = nil
        RecentFiles.add(u)
    }

    /// En quittant l'outil : on libère le PDF (vue, pages, annotations) s'il n'y a rien à perdre.
    /// Avec des modifications non enregistrées, il reste en mémoire pour ne rien perdre.
    func release() {
        guard doc != nil, !dirty, !busy else { return }
        view?.endEditing()
        lastURL = url
        doc = nil
        url = nil
        selected = nil
        undoStack = []
        view = nil
    }

    func close() {
        if dirty, !confirmDestructive("Fermer sans enregistrer ?", "Les modifications seront perdues.", button: "Fermer") { return }
        view?.endEditing()
        doc = nil
        url = nil
        selected = nil
        undoStack = []
        dirty = false
        status = nil
    }

    /// Copie aplatie : ce qu'on voit est ce qu'on obtient, dans n'importe quel lecteur.
    func save() {
        guard let d = doc, let src = url else { return }
        view?.endEditing()
        let stem = src.deletingPathExtension().lastPathComponent
        guard let out = Panels.save(suggested: stem + "-modifié.pdf", type: .pdf, directory: src.deletingLastPathComponent()) else { return }
        busy = true
        status = .info("Enregistrement…")
        runInBackground({
            try PDFEdit.flatten(d, to: out, redact: { $0.userName == EditStore.redactTag })
        }) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let res):
                self.dirty = false
                var text = "Enregistré : \(out.lastPathComponent)."
                if res.redactedPages > 0 {
                    text += " Texte sous les caches supprimé (\(res.redactedPages) page(s) recréée(s) en image, restée(s) cherchable(s))."
                }
                self.status = .ok(text, files: [out])
                RecentFiles.add(out)
            case .failure(let e):
                self.status = .err(e)
            }
        }
    }

    /// Garde les annotations modifiables (Aperçu, Acrobat…). Pas pour les images ni les caches.
    func saveEditable() {
        guard let d = doc, let src = url else { return }
        view?.endEditing()
        if hasImages {
            status = .err("Les images ne restent pas modifiables : utilise « Enregistrer une copie… ».")
            return
        }
        let stem = src.deletingPathExtension().lastPathComponent
        guard let out = Panels.save(suggested: stem + "-annoté.pdf", type: .pdf, directory: src.deletingLastPathComponent()) else { return }
        do {
            try PDFEdit.saveEditable(d, to: out)
            dirty = false
            status = .ok("Enregistré avec les annotations modifiables : \(out.lastPathComponent). Attention : un cache blanc s'y retire, le texte dessous reste lisible.", files: [out])
        } catch {
            status = .err(error)
        }
    }

    // MARK: Annotations

    func record(_ u: EditUndo) {
        undoStack.append(u)
        if undoStack.count > 200 { undoStack.removeFirst() }
        dirty = true
    }

    func undo() {
        view?.endEditing()
        guard let u = undoStack.popLast() else { return }
        var pages: [PDFPage] = []
        switch u {
        case .added(let list):
            for (a, p) in list { p.removeAnnotation(a); pages.append(p) }
        case .removed(let list):
            for (a, p) in list { p.addAnnotation(a); pages.append(p) }
        case .bounds(let a, let r):
            a.bounds = r
            if let p = a.page { pages.append(p) }
        case .text(let a, let s, let r):
            a.contents = s
            a.bounds = r
            if let p = a.page { pages.append(p) }
        case .rotated(let p, let r):
            p.rotation = r
        case .pageRemoved(let p, let i):
            doc?.insert(p, at: min(i, doc?.pageCount ?? 0))
        case .pageInserted(let p):
            if let d = doc { let i = d.index(for: p); if i < d.pageCount { d.removePage(at: i) } }
        }
        selected = nil
        dirty = true
        view?.refresh(pages)
    }

    func deleteSelected() {
        guard let a = selected, let p = a.page else { return }
        p.removeAnnotation(a)
        record(.removed([(a, p)]))
        selected = nil
        view?.refresh([p])
    }

    /// La couleur / l'épaisseur / la taille choisies s'appliquent aussi à l'élément sélectionné.
    func applyStyle() {
        guard let a = selected, let p = a.page else { return }
        switch PDFEdit.kind(a) {
        case "FreeText":
            a.fontColor = color
            let f = a.font ?? NSFont(name: "Helvetica", size: fontSize) ?? .systemFont(ofSize: fontSize)
            a.font = Self.resized(f, fontSize)
            view?.fit(a)
        case "Highlight":
            a.color = highlightColor
        case "Square", "Circle", "Line", "Ink":
            if a.userName == Self.redactTag { return }
            a.color = color
            let b = PDFBorder()
            b.lineWidth = lineWidth
            a.border = b
        case "Underline", "StrikeOut":
            a.color = color
        default:
            return
        }
        dirty = true
        view?.refresh([p])
    }

    /// Les réglages reprennent ceux de l'élément sélectionné (sans le modifier).
    func adopt(_ a: PDFAnnotation) {
        let c: NSColor? = PDFEdit.kind(a) == "FreeText" ? a.fontColor : a.color
        let target = c?.usingColorSpace(.sRGB)
        let match = Self.palette.firstIndex { p in
            guard let t = target, let q = p.1.usingColorSpace(.sRGB) else { return false }
            return abs(t.redComponent - q.redComponent) < 0.05 && abs(t.greenComponent - q.greenComponent) < 0.05
                && abs(t.blueComponent - q.blueComponent) < 0.05
        }
        let saved = selected
        selected = nil                     // pas d'applyStyle pendant qu'on recopie
        if let m = match, m != colorIndex { colorIndex = m }
        if PDFEdit.kind(a) == "FreeText", let s = a.font?.pointSize, s != fontSize { fontSize = s }
        if let w = a.border?.lineWidth, w > 0, ["Square", "Circle", "Line", "Ink"].contains(PDFEdit.kind(a)), w != lineWidth { lineWidth = w }
        selected = saved
    }

    // MARK: Images

    func insertImage() {
        guard let u = Panels.open([.image]).first else { return }
        guard let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            status = .err("Image illisible.")
            return
        }
        view?.place(img)
    }

    var signatures: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: SignStore.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func insertSignature(_ u: URL) {
        guard let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        view?.place(img, maxSide: 150)
    }

    // MARK: Pages

    func rotatePage() {
        guard let p = view?.currentPage else { return }
        record(.rotated(p, p.rotation))
        p.rotation = (p.rotation + 90) % 360
        view?.refresh([])
    }

    func insertBlankPage() {
        guard let d = doc, let cur = view?.currentPage, let blank = PDFEdit.blankPage(size: PageDrawing.displaySize(cur)) else { return }
        d.insert(blank, at: d.index(for: cur) + 1)
        record(.pageInserted(blank))
        view?.refresh([])
        view?.go(to: blank)
    }

    func deletePage() {
        guard let d = doc, d.pageCount > 1, let cur = view?.currentPage else { return }
        let i = d.index(for: cur)
        d.removePage(at: i)
        record(.pageRemoved(cur, i))
        selected = nil
        view?.refresh([])
    }
}

// MARK: - Vue PDF éditable

final class SelectionBox: NSView {
    var handle = true
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let p = NSBezierPath(rect: r)
        p.lineWidth = 1.2
        p.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        p.stroke()
        if handle {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(rect: NSRect(x: bounds.maxX - 9, y: isFlipped ? bounds.maxY - 9 : 0, width: 9, height: 9)).fill()
        }
    }
}

final class InlineTextView: NSTextView {
    var onDone: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onDone?() }
}

/// Délégué de la zone de texte en cours d'édition (séparé : PDFView gère déjà ses propres champs).
final class InlineTextDelegate: NSObject, NSTextViewDelegate {
    var onChange: (() -> Void)?
    func textDidChange(_ notification: Notification) { onChange?() }
}

final class EditorPDFView: PDFView {
    weak var store: EditStore?

    private var dragStart: CGPoint?
    private var dragPage: PDFPage?
    private var live: PDFAnnotation?
    private var inkPoints: [CGPoint] = []
    private var moveOrigin: CGRect?
    private var resizing = false
    private let box = SelectionBox()
    private var editor: InlineTextView?
    private var editing: PDFAnnotation?
    private var editingNew = false
    private var editingOld: (String?, CGRect) = (nil, .zero)
    /// Zones de texte dont la largeur suit le texte (pas encore redimensionnées à la main).
    private var autoWidth = Set<ObjectIdentifier>()
    private let textDelegate = InlineTextDelegate()
    /// Texte réécrit : police embarquée du PDF et police de secours (choisie selon les lettres tapées).
    private var fontChoices: [ObjectIdentifier: (embedded: NSFont?, fallback: NSFont)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let nc = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewDisplayModeChanged, .PDFViewDocumentChanged] {
            nc.addObserver(self, selector: #selector(layoutChanged), name: name, object: self)
        }
    }

    @objc private func layoutChanged() {
        endEditing()
        DispatchQueue.main.async { self.updateBox() }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Utilitaires

    private func pagePoint(_ event: NSEvent, on page: PDFPage? = nil) -> (PDFPage, CGPoint)? {
        let vp = convert(event.locationInWindow, from: nil)
        guard let pg = page ?? self.page(for: vp, nearest: true) else { return nil }
        var p = convert(vp, to: pg)
        let b = pg.bounds(for: .cropBox)
        p.x = min(max(p.x, b.minX), b.maxX)
        p.y = min(max(p.y, b.minY), b.maxY)
        return (pg, p)
    }

    private func editable(_ a: PDFAnnotation) -> Bool {
        let k = PDFEdit.kind(a)
        return a.shouldDisplay && k != "Link" && k != "Popup" && k != "Widget"
    }

    private func resizable(_ a: PDFAnnotation) -> Bool {
        a is ImageAnnotation || ["FreeText", "Square", "Circle"].contains(PDFEdit.kind(a))
    }

    private func hit(_ page: PDFPage, _ p: CGPoint) -> PDFAnnotation? {
        let tol = 3 / max(scaleFactor, 0.1)
        return page.annotations.reversed().first { editable($0) && $0.bounds.insetBy(dx: -tol, dy: -tol).contains(p) }
    }

    private func onHandle(_ a: PDFAnnotation, _ p: CGPoint) -> Bool {
        guard resizable(a) else { return false }
        let tol = 10 / max(scaleFactor, 0.1)
        return abs(p.x - a.bounds.maxX) < tol && abs(p.y - a.bounds.minY) < tol
    }

    func refresh(_ pages: [PDFPage]) {
        for p in pages { annotationsChanged(on: p) }
        if pages.isEmpty { layoutDocumentView() }
        needsDisplay = true
        updateBox()
    }

    func select(_ a: PDFAnnotation?) {
        store?.selected = a
        if let a = a { store?.adopt(a) }
        updateBox()
    }

    func updateBox() {
        guard let a = store?.selected, let page = a.page, a.shouldDisplay, let doc = documentView,
              document?.index(for: page) ?? NSNotFound != NSNotFound else {
            box.removeFromSuperview()
            return
        }
        let r = doc.convert(convert(a.bounds, from: page), from: self).insetBy(dx: -4, dy: -4)
        box.handle = resizable(a)
        if box.superview !== doc { doc.addSubview(box) }
        box.frame = r
        box.needsDisplay = true
    }

    func toolChanged() {
        endEditing()
        if store?.tool != .select { select(nil) }
        clearSelection()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Souris

    override func mouseMoved(with event: NSEvent) {
        guard let t = store?.tool else { return super.mouseMoved(with: event) }
        if t.drags { NSCursor.crosshair.set(); return }
        if t == .text || t == .note { NSCursor.iBeam.set(); return }
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let s = store else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        endEditing()
        guard let hitPoint = pagePoint(event) else { return super.mouseDown(with: event) }
        let (page, p) = hitPoint
        switch s.tool {
        case .select:
            if let a = s.selected, a.page === page, onHandle(a, p) {
                resizing = true
                moveOrigin = a.bounds
                dragStart = p
                dragPage = page
            } else if let a = hit(page, p) {
                select(a)
                if event.clickCount == 2, PDFEdit.kind(a) == "FreeText" { beginEditing(a, new: false); return }
                moveOrigin = a.bounds
                dragStart = p
                dragPage = page
            } else {
                select(nil)
                super.mouseDown(with: event)
            }
        case .text, .note:
            if let a = hit(page, p), PDFEdit.kind(a) == "FreeText" {
                select(a)
                beginEditing(a, new: false)
                return
            }
            let a = makeTextBox(at: p, on: page, note: s.tool == .note, text: "")
            page.addAnnotation(a)
            autoWidth.insert(ObjectIdentifier(a))
            select(a)
            beginEditing(a, new: true)
        case .highlight, .underline, .strike, .editText:
            select(nil)
            super.mouseDown(with: event)
            finishTextSelection()          // si PDFView a suivi la souris jusqu'au bout
        case .ink, .rect, .ellipse, .arrow, .whiteout:
            select(nil)
            dragStart = p
            dragPage = page
            inkPoints = [p]
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = store, let page = dragPage, let start = dragStart, let hitPoint = pagePoint(event, on: page) else {
            return super.mouseDragged(with: event)
        }
        let p = hitPoint.1
        switch s.tool {
        case .select:
            guard let a = s.selected, let o = moveOrigin else { return }
            if resizing {
                a.bounds = resized(a, from: o, to: p)
                autoWidth.remove(ObjectIdentifier(a))
            } else {
                a.bounds = o.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            }
            refresh([page])
        case .ink:
            inkPoints.append(p)
            replaceLive(makeInk(inkPoints), on: page)
        case .rect, .ellipse, .arrow, .whiteout:
            replaceLive(makeShape(s.tool, from: start, to: p), on: page)
        default:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragPage = nil
            moveOrigin = nil
            resizing = false
            live = nil
            inkPoints = []
        }
        guard let s = store else { return super.mouseUp(with: event) }
        switch s.tool {
        case .select:
            if let a = s.selected, let o = moveOrigin {
                if a.bounds != o { s.record(.bounds(a, o)) }
            } else {
                super.mouseUp(with: event)
            }
        case .ink, .rect, .ellipse, .arrow, .whiteout:
            guard let a = live, let page = dragPage else { return }
            let tiny = s.tool == .ink ? inkPoints.count < 2 : (a.bounds.width < 4 && a.bounds.height < 4)
            if tiny {
                page.removeAnnotation(a)
                refresh([page])
            } else {
                s.record(.added([(a, page)]))
            }
        case .highlight, .underline, .strike, .editText:
            super.mouseUp(with: event)
            finishTextSelection()
        default:
            super.mouseUp(with: event)
        }
    }

    private func replaceLive(_ a: PDFAnnotation, on page: PDFPage) {
        if let old = live { page.removeAnnotation(old) }
        page.addAnnotation(a)
        live = a
        annotationsChanged(on: page)
    }

    private func resized(_ a: PDFAnnotation, from o: CGRect, to p: CGPoint) -> CGRect {
        let w = max(12, p.x - o.minX)
        var h = max(8, o.maxY - p.y)
        if a is ImageAnnotation, o.height > 0 { h = w * o.height / o.width }
        return CGRect(x: o.minX, y: o.maxY - h, width: w, height: h)
    }

    // MARK: Clavier

    override func keyDown(with event: NSEvent) {
        guard let s = store else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty {
            switch event.keyCode {
            case 51, 117:                                           // effacer
                if s.selected != nil { s.deleteSelected(); return }
            case 53:                                                // Échap
                select(nil)
                s.tool = .select
                return
            case 36, 76:                                            // Entrée : modifier le texte sélectionné
                if let a = s.selected, PDFEdit.kind(a) == "FreeText" { beginEditing(a, new: false); return }
            case 123, 124, 125, 126:                                // flèches : déplacer
                if let a = s.selected {
                    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                    let o = a.bounds
                    var dx: CGFloat = 0, dy: CGFloat = 0
                    switch event.keyCode {
                    case 123: dx = -step
                    case 124: dx = step
                    case 125: dy = -step
                    default: dy = step
                    }
                    a.bounds = o.offsetBy(dx: dx, dy: dy)
                    s.record(.bounds(a, o))
                    refresh(a.page.map { [$0] } ?? [])
                    return
                }
            default:
                if !event.modifierFlags.contains(.shift), let c = event.charactersIgnoringModifiers?.lowercased(),
                   let t = EditTool.allCases.first(where: { $0.key == c }) {
                    s.tool = t
                    return
                }
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Texte sélectionné dans le PDF

    private func finishTextSelection() {
        guard let s = store, s.tool.picksText, let sel = currentSelection,
              !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearSelection()
        if s.tool == .editText {
            replaceText(sel)
        } else {
            markup(sel, s.tool)
        }
    }

    private func markup(_ sel: PDFSelection, _ tool: EditTool) {
        guard let s = store else { return }
        let type: PDFAnnotationSubtype = tool == .highlight ? .highlight : tool == .underline ? .underline : .strikeOut
        var added: [(PDFAnnotation, PDFPage)] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0.5, b.height > 0.5 else { continue }
                let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                a.color = tool == .highlight ? s.highlightColor : s.color
                a.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: b.height)), NSValue(point: NSPoint(x: b.width, y: b.height)),
                                         NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: b.width, y: 0))]
                page.addAnnotation(a)
                added.append((a, page))
            }
        }
        if !added.isEmpty {
            s.record(.added(added))
            var pages: [PDFPage] = []
            for (_, p) in added where !pages.contains(where: { $0 === p }) { pages.append(p) }
            refresh(pages)
        }
    }

    /// « Modifier le texte » : la phrase est cachée par un cache blanc et réécrite dans une zone de texte.
    private func replaceText(_ sel: PDFSelection) {
        guard let s = store, let page = sel.pages.first else { return }
        let lines = sel.selectionsByLine().filter { $0.pages.first === page }
        let rects = lines.map { $0.bounds(for: page) }.filter { $0.width > 0.5 }
        guard var r = rects.first else { return }
        for x in rects.dropFirst() { r = r.union(x) }
        // police d'origine : embarquée dans le PDF, sinon installée, sinon une qui ressemble ; taille ≈ hauteur de ligne
        let attr = sel.attributedString
        let text = (sel.string ?? "").replacingOccurrences(of: "\r", with: "\n")
        var size = (rects.map { $0.height }.min() ?? 12) * 0.82
        var font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        var choices: (embedded: NSFont?, fallback: NSFont)?
        if let a = attr, a.length > 0, let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            size = f.pointSize
            let c = PDFFonts.candidates(for: f.fontName, on: page, size: size)
            choices = c
            font = PDFFonts.pick(c, for: text)
        }
        var color = NSColor.black
        if let a = attr, a.length > 0, let c = a.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor { color = c }

        let cover = PDFAnnotation(bounds: r.insetBy(dx: -1, dy: -1), forType: .square, withProperties: nil)
        styleCover(cover)
        page.addAnnotation(cover)
        s.record(.added([(cover, page)]))

        let box = PDFAnnotation(bounds: r, forType: .freeText, withProperties: nil)
        box.font = font
        box.fontColor = color
        box.color = .clear
        box.contents = text
        let b = PDFBorder()
        b.lineWidth = 0
        box.border = b
        page.addAnnotation(box)
        if let c = choices { fontChoices[ObjectIdentifier(box)] = c }
        select(box)
        beginEditing(box, new: true)
    }

    // MARK: Fabrication des annotations

    private func styleCover(_ a: PDFAnnotation) {
        a.color = .white
        a.interiorColor = .white
        let b = PDFBorder()
        b.lineWidth = 0
        a.border = b
        a.userName = EditStore.redactTag
    }

    func makeTextBox(at p: CGPoint, on page: PDFPage, note: Bool, text: String) -> PDFAnnotation {
        let s = store
        let size = s?.fontSize ?? 14
        let font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        let pb = page.bounds(for: .cropBox)
        let w = min(note ? 180 : 240, pb.maxX - p.x - 4)
        let h = textSize("M", font: font, width: w).height + (note ? 12 : 4)
        let a = PDFAnnotation(bounds: CGRect(x: p.x, y: max(pb.minY, p.y - h), width: max(w, 30), height: h),
                              forType: .freeText, withProperties: nil)
        a.font = font
        a.fontColor = note ? .black : (s?.color ?? .black)
        a.color = note ? NSColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 1) : .clear
        a.contents = text
        let b = PDFBorder()
        b.lineWidth = 0
        a.border = b
        return a
    }

    private func makeShape(_ tool: EditTool, from st: CGPoint, to en: CGPoint) -> PDFAnnotation {
        let s = store
        let lw = s?.lineWidth ?? 2
        let r = CGRect(x: min(st.x, en.x), y: min(st.y, en.y), width: abs(en.x - st.x), height: abs(en.y - st.y))
        let border = PDFBorder()
        border.lineWidth = lw
        switch tool {
        case .arrow:
            let pad = lw * 4 + 6
            let b = r.insetBy(dx: -pad, dy: -pad)
            let a = PDFAnnotation(bounds: b, forType: .line, withProperties: nil)
            a.startPoint = CGPoint(x: st.x - b.minX, y: st.y - b.minY)
            a.endPoint = CGPoint(x: en.x - b.minX, y: en.y - b.minY)
            a.endLineStyle = .openArrow
            a.color = s?.color ?? .red
            a.border = border
            return a
        case .ellipse:
            let a = PDFAnnotation(bounds: r, forType: .circle, withProperties: nil)
            a.color = s?.color ?? .red
            a.border = border
            return a
        case .whiteout:
            let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
            styleCover(a)
            return a
        default:
            let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
            a.color = s?.color ?? .red
            a.border = border
            return a
        }
    }

    private func makeInk(_ pts: [CGPoint]) -> PDFAnnotation {
        let lw = store?.lineWidth ?? 2
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let pad = lw + 2
        let b = CGRect(x: (xs.min() ?? 0) - pad, y: (ys.min() ?? 0) - pad,
                       width: (xs.max() ?? 0) - (xs.min() ?? 0) + 2 * pad, height: (ys.max() ?? 0) - (ys.min() ?? 0) + 2 * pad)
        let path = NSBezierPath()
        path.lineWidth = lw
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let rel = pts.map { CGPoint(x: $0.x - b.minX, y: $0.y - b.minY) }
        if let f = rel.first { path.move(to: f) }
        if rel.count < 3 {
            rel.dropFirst().forEach { path.line(to: $0) }
        } else {
            // courbes passant par les milieux : trait lissé
            for i in 1..<(rel.count - 1) {
                let mid = CGPoint(x: (rel[i].x + rel[i + 1].x) / 2, y: (rel[i].y + rel[i + 1].y) / 2)
                path.curve(to: mid, controlPoint1: rel[i], controlPoint2: rel[i])
            }
            path.line(to: rel[rel.count - 1])
        }
        let a = PDFAnnotation(bounds: b, forType: .ink, withProperties: nil)
        a.add(path)
        a.color = store?.color ?? .red
        let border = PDFBorder()
        border.lineWidth = lw
        a.border = border
        return a
    }

    /// Image (ou signature) posée au milieu de la partie visible de la page courante.
    func place(_ img: CGImage, maxSide: CGFloat = 220) {
        guard let s = store, let page = currentPage else { return }
        let c = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: page)
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        let k = min(1, maxSide / max(iw, ih) * 1)
        let w = max(20, iw * k), h = max(20, ih * k)
        let pb = page.bounds(for: .cropBox)
        let x = min(max(c.x - w / 2, pb.minX), pb.maxX - w), y = min(max(c.y - h / 2, pb.minY), pb.maxY - h)
        let a = ImageAnnotation(bounds: CGRect(x: x, y: y, width: w, height: h), forType: .stamp, withProperties: nil)
        a.image = img
        page.addAnnotation(a)
        s.record(.added([(a, page)]))
        s.tool = .select
        select(a)
        refresh([page])
    }

    // MARK: Édition du texte sur la page

    private func textSize(_ text: String, font: NSFont, width: CGFloat) -> CGSize {
        let r = (text as NSString).boundingRect(with: NSSize(width: max(width - 4, 10), height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Ajuste la zone au texte : hauteur toujours, largeur si elle n'a pas été réglée à la main. Le haut reste fixe.
    func fit(_ a: PDFAnnotation) {
        guard PDFEdit.kind(a) == "FreeText", let page = a.page else { return }
        let font = a.font ?? .systemFont(ofSize: 14)
        let text = (a.contents ?? "").isEmpty ? "M" : (a.contents ?? "")
        var r = a.bounds
        let top = r.maxY
        let pad: CGFloat = a.color.alphaComponent > 0.01 ? 12 : 4
        if autoWidth.contains(ObjectIdentifier(a)) {
            let natural = textSize(text, font: font, width: 10_000).width + pad + 6
            r.size.width = min(natural, page.bounds(for: .cropBox).maxX - r.minX - 2)
        }
        r.size.height = textSize(text, font: font, width: r.width - pad).height + pad
        r.origin.y = top - r.height
        a.bounds = r
        refresh([page])
    }

    func beginEditing(_ a: PDFAnnotation, new: Bool) {
        guard let page = a.page, let doc = documentView else { return }
        endEditing()
        editing = a
        editingNew = new
        editingOld = (a.contents, a.bounds)
        let base = a.font ?? .systemFont(ofSize: 14)
        let tv = InlineTextView(frame: frameFor(a, in: doc, page: page))
        tv.font = EditStore.resized(base, base.pointSize * scaleFactor)
        tv.textColor = a.fontColor ?? .black
        tv.string = a.contents ?? ""
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = true
        tv.backgroundColor = a.color.alphaComponent > 0.01 ? a.color : NSColor.white.withAlphaComponent(0.92)
        tv.textContainerInset = NSSize(width: 0, height: 1)
        tv.textContainer?.lineFragmentPadding = 2
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.focusRingType = .none
        tv.wantsLayer = true
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tv.layer?.borderWidth = 1
        textDelegate.onChange = { [weak self] in self?.resizeEditor() }
        tv.delegate = textDelegate
        tv.onDone = { [weak self] in self?.endEditing() }
        a.shouldDisplay = false
        annotationsChanged(on: page)
        box.removeFromSuperview()
        doc.addSubview(tv)
        editor = tv
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        resizeEditor()
    }

    private func frameFor(_ a: PDFAnnotation, in doc: NSView, page: PDFPage) -> NSRect {
        doc.convert(convert(a.bounds, from: page), from: self)
    }

    /// La zone grandit pendant la frappe (le haut reste en place).
    private func resizeEditor() {
        guard let tv = editor, let a = editing, let page = a.page, let doc = documentView,
              let font = tv.font else { return }
        let text = tv.string.isEmpty ? "M" : tv.string
        var r = frameFor(a, in: doc, page: page)
        if autoWidth.contains(ObjectIdentifier(a)) {
            let pageRight = doc.convert(convert(page.bounds(for: .cropBox), from: page), from: self).maxX
            r.size.width = max(r.width, min(textSize(text, font: font, width: 100_000).width + 16, pageRight - r.minX - 2))
        }
        let h = max(r.height, textSize(text, font: font, width: r.width - 4).height + 6)
        let top = doc.isFlipped ? r.minY : r.maxY
        r.size.height = h
        r.origin.y = doc.isFlipped ? top : top - h
        tv.frame = r
    }

    func endEditing() {
        guard let a = editing, let tv = editor else { return }
        editing = nil
        editor = nil
        let text = tv.string
        tv.removeFromSuperview()
        a.shouldDisplay = true
        guard let page = a.page else { return }
        let s = store
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            page.removeAnnotation(a)
            if !editingNew { s?.record(.removed([(a, page)])) }
            if s?.selected === a { s?.selected = nil }
        } else {
            a.contents = text
            if let c = fontChoices[ObjectIdentifier(a)], let size = a.font?.pointSize {
                // une police embarquée n'a souvent que les lettres déjà utilisées : sinon, celle de secours
                let chosen = PDFFonts.pick(c, for: text)
                a.font = EditStore.resized(chosen, size)
            }
            fit(a)
            if editingNew {
                s?.record(.added([(a, page)]))
            } else if editingOld.0 != text {
                s?.record(.text(a, editingOld.0, editingOld.1))
            }
            if s?.tool == .text || s?.tool == .note || s?.tool == .editText { s?.selected = a }
        }
        refresh([page])
        window?.makeFirstResponder(self)
    }
}

// MARK: - SwiftUI

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var s: EditStore

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let pdf = EditorPDFView()
        pdf.store = s
        s.view = pdf
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displaysPageBreaks = true
        pdf.backgroundColor = .underPageBackgroundColor
        pdf.document = s.doc

        let thumbs = PDFThumbnailView()
        thumbs.pdfView = pdf
        thumbs.thumbnailSize = NSSize(width: 76, height: 100)
        thumbs.backgroundColor = .clear

        for v in [thumbs, pdf] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumbs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbs.topAnchor.constraint(equalTo: container.topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            thumbs.widthAnchor.constraint(equalToConstant: 104),
            pdf.leadingAnchor.constraint(equalTo: thumbs.trailingAnchor),
            pdf.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdf.topAnchor.constraint(equalTo: container.topAnchor),
            pdf.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ v: NSView, context: Context) {
        if let pdf = s.view, pdf.document !== s.doc {
            pdf.document = s.doc
        }
    }
}

struct EditToolView: View {
    @ObservedObject var s: EditStore

    private let groups: [[EditTool]] = [
        [.select],
        [.text, .editText, .note],
        [.highlight, .underline, .strike],
        [.ink, .rect, .ellipse, .arrow],
        [.whiteout],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolHeader(tool: .edit)
            if s.doc == nil {
                DropZone(title: "Dépose un PDF à éditer",
                         subtitle: "Ajouter du texte, modifier une phrase, surligner, dessiner, poser une image ou ta signature, cacher une zone…",
                         types: [.pdf], multiple: false) { urls in
                    if let u = urls.first { s.open(u) }
                }
                if let last = s.lastURL, FileManager.default.fileExists(atPath: last.path) {
                    Button { s.open(last) } label: {
                        Label("Reprendre « \(last.lastPathComponent) »", systemImage: "arrow.uturn.forward")
                    }
                }
                StatusBanner(message: s.status)
                Spacer()
            } else {
                toolbar
                styleBar
                EditorCanvas(s: s)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                    .overlay {
                        if s.busy {
                            ProgressView().controlSize(.large).padding(24)
                                .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                        }
                    }
                    .fileDrop(types: [.image]) { urls in
                        if let u = urls.first, let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            s.view?.place(img)
                        }
                    }
                    .disabled(s.busy)
                    .tourTarget("edit.canvas")
                StatusBanner(message: s.status)
            }
        }
        .padding(20)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(groups.indices, id: \.self) { gi in
                HStack(spacing: 2) {
                    ForEach(groups[gi]) { t in
                        Button { s.tool = t } label: {
                            Image(systemName: t.icon)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 30, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(s.tool == t ? Color.accentColor.opacity(0.22) : Color.clear))
                                .foregroundStyle(s.tool == t ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help(t.title + " : " + t.help)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Menu {
                Button("Image…") { s.insertImage() }
                let sigs = s.signatures
                if !sigs.isEmpty {
                    Section("Mes signatures") {
                        ForEach(sigs, id: \.self) { u in
                            Button(Self.signatureName(u)) { s.insertSignature(u) }
                        }
                    }
                }
            } label: {
                Label("Image", systemImage: "photo")
            }
            .fixedSize()
            .help("Poser une image ou une de tes signatures (outil Signer)")
            .tourTarget("edit.tools")

            Spacer()

            Button { s.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!s.canUndo)
                .help("Annuler (⌘Z)")
            Menu {
                Button("Pivoter la page") { s.rotatePage() }
                Button("Insérer une page blanche après") { s.insertBlankPage() }
                Divider()
                Button("Supprimer la page") { s.deletePage() }
                    .disabled((s.doc?.pageCount ?? 0) < 2)
            } label: {
                Image(systemName: "doc.badge.gearshape")
            }
            .fixedSize()
            .help("Page courante")
            Menu {
                Button("Garder les annotations modifiables…") { s.saveEditable() }
                    .disabled(s.hasImages)
                Divider()
                Button("Fermer le PDF") { s.close() }
            } label: {
                Text(s.dirty ? "Enregistrer une copie… ●" : "Enregistrer une copie…")
            } primaryAction: {
                s.save()
            }
            .fixedSize()
            .background(Button("") { s.save() }.keyboardShortcut("s", modifiers: .command).opacity(0).frame(width: 0, height: 0))
            .help("Copie où tout est intégré aux pages ; le texte sous les caches blancs est vraiment supprimé (⌘S)")
            .tourTarget("edit.save")
        }
    }

    /// « signature-2026-10-12_18-03-22.png » → « Signature du 12/10/2026 à 18:03 »
    static func signatureName(_ u: URL) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "signature-", with: "")
        guard let d = f.date(from: stem) else { return stem }
        let o = DateFormatter()
        o.dateFormat = "dd/MM/yyyy 'à' HH:mm"
        return "Signature du " + o.string(from: d)
    }

    private var styleBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                ForEach(EditStore.palette.indices, id: \.self) { i in
                    Button { s.colorIndex = i } label: {
                        Circle()
                            .fill(Color(nsColor: EditStore.palette[i].1))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                            .padding(2)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: s.colorIndex == i ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(EditStore.palette[i].0)
                }
            }
            Picker("Trait", selection: $s.lineWidth) {
                ForEach(EditStore.widths, id: \.self) { w in Text("\(Int(w)) pt").tag(w) }
            }
            .fixedSize()
            Picker("Texte", selection: $s.fontSize) {
                ForEach(EditStore.sizes, id: \.self) { v in Text("\(Int(v))").tag(v) }
            }
            .fixedSize()
            if s.selected != nil {
                Button(role: .destructive) { s.deleteSelected() } label: { Label("Supprimer", systemImage: "trash") }
                    .help("Supprimer l'élément sélectionné (⌫)")
            }
            Spacer()
            if let u = s.url {
                Text(u.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .controlSize(.small)
    }
}
