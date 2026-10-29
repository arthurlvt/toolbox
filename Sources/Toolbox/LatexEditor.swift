import SwiftUI
import AppKit
import PDFCore

/// Ordre envoyé à l'éditeur par le modèle (le jeton change à chaque ordre).
struct EditorCommand: Equatable {
    enum Action: Equatable {
        case goTo(line: Int)
        case insert(String)                                   // au curseur, annulable (⌘Z)
        case replaceLines(from: Int, to: Int, with: String)   // lignes 1…, annulable
        case replaceAll(String)                               // tout le fichier, annulable
    }
    let action: Action
    let token: Int
}

/// Éditeur de code LaTeX intégré : numéros de ligne, coloration, fermeture automatique,
/// complétion, \end automatique, glisser-déposer d'images, collage de tableaux.
struct LatexEditor: NSViewRepresentable {
    @Binding var text: String
    let command: EditorCommand?
    let fontSize: CGFloat
    let folder: URL?                      // dossier du fichier principal (images, .bib…)
    let onCursorLine: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator

        // Pile TextKit 1 explicite (numéros de ligne via NSLayoutManager).
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let tv = LatexTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        c.textView = tv

        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.folder = { [weak c] in c?.parent.folder }
        tv.onCompletionAccepted = { [weak c] word in c?.completionAccepted(word) }

        c.applyFont(fontSize)
        tv.string = text
        tv.delegate = c
        storage.delegate = c
        c.highlightAll()
        c.commandToken = command?.token ?? 0   // un ordre déjà exécuté ne doit pas être rejoué

        let ruler = LineNumberRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        c.ruler = ruler

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if c.fontSize != fontSize {
            c.applyFont(fontSize)
            c.highlightAll()
            c.ruler?.needsDisplay = true
        }
        if tv.string != text {
            // Autre fichier (onglet), rechargement, restauration : on remplace tout le texte.
            c.updatingFromModel = true
            tv.string = text
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.undoManager?.removeAllActions()
            c.updatingFromModel = false
            c.highlightAll()
            c.ruler?.needsDisplay = true
        }
        if let cmd = command, cmd.token != c.commandToken {
            c.commandToken = cmd.token
            DispatchQueue.main.async { c.run(cmd.action) }
        }
    }

    // MARK: - Coordinateur

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: LatexEditor
        weak var textView: LatexTextView?
        weak var ruler: LineNumberRuler?
        var commandToken = 0
        var fontSize: CGFloat = 0
        var updatingFromModel = false
        private var lastTyped: String?
        private var autoCompleting = false
        private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        private var boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

        private static let rules: [(NSRegularExpression, NSColor, Bool)] = {
            func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
            return [
                (rx(#"\\[a-zA-Z@]+\*?|\\[^a-zA-Z\s]"#), .systemPurple, false),
                (rx(#"\\(?:begin|end)\{[^}\n]*\}"#), .systemTeal, true),
                (rx(#"\\(?:part|chapter|section|subsection|subsubsection|paragraph)\*?\{[^}\n]*\}"#), .systemBlue, true),
                (rx(#"(?<!\\)\$\$[^$]*\$\$|(?<!\\)\$(?:[^$\\\n]|\\.)+\$|\\\([^\n]*?\\\)"#), .systemGreen, false),
                (rx(#"(?<!\\)%.*$"#), .secondaryLabelColor, false),
            ]
        }()

        init(_ parent: LatexEditor) { self.parent = parent }

        func applyFont(_ size: CGFloat) {
            fontSize = size
            font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            textView?.font = font
            textView?.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        }

        @objc func boundsChanged() { ruler?.needsDisplay = true }

        // MARK: Ordres du modèle

        func run(_ action: EditorCommand.Action) {
            guard let tv = textView else { return }
            switch action {
            case .goTo(let line):
                goTo(line: line)
            case .insert(let s):
                tv.window?.makeFirstResponder(tv)
                tv.replace(tv.selectedRange(), with: s)
            case .replaceAll(let s):
                tv.window?.makeFirstResponder(tv)
                tv.replace(NSRange(location: 0, length: (tv.string as NSString).length), with: s)
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
            case .replaceLines(let from, let to, let s):
                let ns = tv.string as NSString
                let a = Self.lineRange(ns, line: from)
                let b = Self.lineRange(ns, line: max(from, to))
                var range = NSUnionRange(a, b)
                var replacement = s
                // on garde le saut de ligne final des lignes remplacées
                if NSMaxRange(range) <= ns.length, range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 10,
                   !replacement.hasSuffix("\n") {
                    range.length -= 1
                }
                if replacement.hasSuffix("\n") && NSMaxRange(range) < ns.length { replacement.removeLast() }
                tv.window?.makeFirstResponder(tv)
                tv.replace(range, with: replacement)
                tv.setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
                tv.scrollRangeToVisible(tv.selectedRange())
            }
        }

        // MARK: Texte → modèle

        func textDidChange(_ notification: Notification) {
            guard !updatingFromModel, let tv = textView else { return }
            parent.text = tv.string
            ruler?.needsDisplay = true
            let typed = lastTyped
            lastTyped = nil
            if typed == "}" { tv.closeEnvironmentIfNeeded() }
            if let t = typed, let ch = t.first, ch.isLetter || ch == ":" || ch == "-" {
                triggerCompletionIfUseful()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.onCursorLine(Self.lineNumber(in: tv.string as NSString, at: tv.selectedRange().location))
        }

        /// Fermeture automatique de { [ $, saut par-dessus le caractère fermant déjà présent.
        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString s: String?) -> Bool {
            guard let tv = textView, !tv.programmatic, let s = s, !tv.hasMarkedText() else { lastTyped = nil; return true }
            lastTyped = (s as NSString).length == 1 ? s : nil
            let ns = tv.string as NSString
            let after = NSMaxRange(range)
            let next: Character? = after < ns.length ? Character(UnicodeScalar(ns.character(at: after)) ?? " ") : nil
            let prev: Character? = range.location > 0 ? Character(UnicodeScalar(ns.character(at: range.location - 1)) ?? " ") : nil
            let freeAfter = next == nil || " \n\t}])$,.;:".contains(next!)

            switch s {
            case "{", "[":
                guard prev != "\\" else { return true }                     // \{  \[
                let close = s == "{" ? "}" : "]"
                if range.length > 0 {                                      // entoure la sélection
                    let selected = ns.substring(with: range)
                    tv.replace(range, with: s + selected + close)
                    tv.setSelectedRange(NSRange(location: range.location + 1, length: range.length))
                    lastTyped = nil
                    return false
                }
                guard freeAfter else { return true }
                lastTyped = nil
                tv.replace(range, with: s + close)
                tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                if s == "{" { triggerCompletionIfUseful() }
                return false
            case "}", "]":
                if range.length == 0, let n = next, String(n) == s {
                    lastTyped = nil
                    tv.setSelectedRange(NSRange(location: after + 1, length: 0))
                    if s == "}" { tv.closeEnvironmentIfNeeded() }
                    return false
                }
            case "$":
                guard prev != "\\" else { return true }
                if range.length > 0 {
                    let selected = ns.substring(with: range)
                    tv.replace(range, with: "$" + selected + "$")
                    tv.setSelectedRange(NSRange(location: range.location + 1, length: range.length))
                    lastTyped = nil
                    return false
                }
                if next == "$" {
                    lastTyped = nil
                    tv.setSelectedRange(NSRange(location: after + 1, length: 0))
                    return false
                }
                guard freeAfter, prev.map({ !$0.isLetter && !$0.isNumber }) ?? true else { return true }
                lastTyped = nil
                tv.replace(range, with: "$$")
                tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return false
            default:
                break
            }
            return true
        }

        /// Tabulation → 2 espaces ; Entrée → garde l'indentation (et l'augmente après \begin{…}).
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let tv = textView else { return false }
            if selector == #selector(NSResponder.insertTab(_:)) {
                tv.replace(tv.selectedRange(), with: "  ")
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let ns = tv.string as NSString
                let sel = tv.selectedRange()
                let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
                let current = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
                var indent = String(current.prefix { $0 == " " || $0 == "\t" })
                if current.range(of: #"\\begin\{[^}]*\}"#, options: .regularExpression) != nil,
                   !current.contains("\\end{") {
                    indent += "  "
                }
                tv.replace(sel, with: "\n" + indent)
                return true
            }
            return false
        }

        // MARK: Complétion

        func textView(_ view: NSTextView, completions words: [String], forPartialWordRange range: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let tv = textView else { return [] }
            let list = LatexCompletion.candidates(text: tv.string, partialRange: range, folder: parent.folder)
            // Déclenchée automatiquement : rien de présélectionné (la frappe continue normalement).
            index?.pointee = autoCompleting ? -1 : 0
            autoCompleting = false
            tv.lastCandidates = Set(list)
            return list
        }

        func triggerCompletionIfUseful() {
            guard let tv = textView else { return }
            let range = tv.rangeForUserCompletion
            let ns = tv.string as NSString
            let isCommand = range.location > 0 && ns.character(at: range.location - 1) == 92 /* \ */
            if isCommand && range.length < 2 { return }
            guard !LatexCompletion.candidates(text: tv.string, partialRange: range, folder: parent.folder).isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let tv = self.textView else { return }
                self.autoCompleting = true
                tv.complete(nil)
            }
        }

        /// Une proposition acceptée (Entrée/Tab) : arguments {} des commandes, \end des environnements.
        func completionAccepted(_ word: String) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let cursor = tv.selectedRange().location
            let before = ns.substring(to: cursor)
            let next: unichar? = cursor < ns.length ? ns.character(at: cursor) : nil

            if before.hasSuffix("\\" + word) {
                // commande : on ajoute ses accolades
                let n = LatexCompletion.argumentCount[word] ?? 0
                guard n > 0, next != 123 /* { */ else { return }
                tv.replace(NSRange(location: cursor, length: 0), with: String(repeating: "{}", count: n))
                tv.setSelectedRange(NSRange(location: cursor + 1, length: 0))
                if word == "begin" || word == "ref" || word == "eqref" || word == "cite" || word == "usepackage" {
                    triggerCompletionIfUseful()
                }
            } else if next == 125 /* } */ {
                // argument complété : on sort de l'accolade
                tv.setSelectedRange(NSRange(location: cursor + 1, length: 0))
                tv.closeEnvironmentIfNeeded()
            }
        }

        // MARK: Coloration

        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                         range: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters) else { return }
            let ns = storage.string as NSString
            var r = ns.lineRange(for: range)
            if r.location > 0 { r = NSUnionRange(r, ns.lineRange(for: NSRange(location: r.location - 1, length: 0))) }
            if NSMaxRange(r) < ns.length { r = NSUnionRange(r, ns.lineRange(for: NSRange(location: NSMaxRange(r), length: 0))) }
            highlight(storage, in: r)
        }

        func highlightAll() {
            guard let storage = textView?.textStorage else { return }
            storage.beginEditing()
            highlight(storage, in: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }

        private func highlight(_ storage: NSTextStorage, in range: NSRange) {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: range)
            let s = storage.string
            for (rx, color, bold) in Self.rules {
                rx.enumerateMatches(in: s, range: range) { m, _, _ in
                    guard let m = m else { return }
                    storage.addAttribute(.foregroundColor, value: color, range: m.range)
                    if bold { storage.addAttribute(.font, value: boldFont, range: m.range) }
                }
            }
        }

        // MARK: Navigation

        static func lineNumber(in ns: NSString, at location: Int) -> Int {
            var line = 1
            let end = min(location, ns.length)
            var i = 0
            while i < end {
                if ns.character(at: i) == 10 { line += 1 }
                i += 1
            }
            return line
        }

        /// Plage (saut de ligne compris) de la ligne n (1…).
        static func lineRange(_ ns: NSString, line: Int) -> NSRange {
            var current = 1
            var loc = 0
            while current < line && loc < ns.length {
                loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
                current += 1
            }
            return ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
        }

        func goTo(line: Int) {
            guard let tv = textView else { return }
            let target = Self.lineRange(tv.string as NSString, line: line)
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: target.location, length: 0))
            tv.scrollRangeToVisible(target)
            if target.length > 0 { tv.showFindIndicator(for: target) }
        }
    }
}

// MARK: - Vue texte

final class LatexTextView: NSTextView {
    var folder: (() -> URL?)?
    var onCompletionAccepted: ((String) -> Void)?
    var lastCandidates: Set<String> = []
    private(set) var programmatic = false

    /// Remplacement annulable (⌘Z) qui ne repasse pas par la fermeture automatique.
    func replace(_ range: NSRange, with text: String) {
        programmatic = true
        defer { programmatic = false }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    // MARK: Complétion

    /// Le mot en cours : s'arrête sur \ { [ espace… (garde « fig:… » ou « sec-… » entiers).
    override var rangeForUserCompletion: NSRange {
        let ns = string as NSString
        let end = selectedRange().location
        var start = end
        let stops = " \\{}[]()$,%\n\t~&^="
        while start > 0 {
            let c = ns.character(at: start - 1)
            if let scalar = UnicodeScalar(c), stops.unicodeScalars.contains(scalar) { break }
            start -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        let accepted = movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue
        if flag, accepted, lastCandidates.contains(word) {
            DispatchQueue.main.async { [weak self] in self?.onCompletionAccepted?(word) }
        }
    }

    // MARK: \begin{…} → \end{…}

    func closeEnvironmentIfNeeded() {
        let ns = string as NSString
        let cursor = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: cursor - line.location))
        guard let r = before.range(of: #"\\begin\{([^}]+)\}$"#, options: .regularExpression) else { return }
        let env = String(before[r].dropFirst("\\begin{".count).dropLast())
        let opens = string.components(separatedBy: "\\begin{\(env)}").count - 1
        let closes = string.components(separatedBy: "\\end{\(env)}").count - 1
        guard opens > closes else { return }
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let lineEnd = line.location + line.length - (NSMaxRange(line) > line.location && NSMaxRange(line) <= ns.length
                                                      && ns.character(at: NSMaxRange(line) - 1) == 10 ? 1 : 0)
        let insertAt = lineEnd
        let block = "\n" + indent + "  \n" + indent + "\\end{\(env)}"
        replace(NSRange(location: insertAt, length: 0), with: block)
        // Environnements qui attendent des arguments ({lll}, {0.5\linewidth}) : curseur après \begin{…}.
        if ["tabular", "tabularx", "tabular*", "array", "minipage", "multicols", "wrapfigure"].contains(env) {
            setSelectedRange(NSRange(location: cursor, length: 0))
        } else {
            setSelectedRange(NSRange(location: insertAt + 1 + (indent as NSString).length + 2, length: 0))
        }
    }

    // MARK: Images glissées ou collées, tableaux collés

    static let graphicExtensions = ["png", "jpg", "jpeg", "pdf", "eps"]
    static let convertibleExtensions = ["heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func isGraphic(_ u: URL) -> Bool {
        let e = u.pathExtension.lowercased()
        return graphicExtensions.contains(e) || convertibleExtensions.contains(e)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = urls.filter(Self.isGraphic)
        guard !images.isEmpty, let dir = folder?() else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        window?.makeFirstResponder(self)
        insertFigures(images, in: dir)
        return true
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let dir = folder?() {
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let images = urls.filter(Self.isGraphic)
            if !images.isEmpty { insertFigures(images, in: dir); return }
            // Capture d'écran copiée (⌃⇧⌘4) : une image sans texte dans le presse-papiers.
            if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb),
               let rel = Self.savePNG(image, into: dir, base: "capture") {
                insertBlock(Self.figure(rel))
                ensurePackage("graphicx")
                return
            }
        }
        // Tableau copié depuis Excel, Numbers ou Google Sheets.
        if let text = pb.string(forType: .string), let table = LatexSnippets.tabular(fromTSV: text) {
            insertBlock(table)
            return
        }
        pasteAsPlainText(sender)
    }

    func insertFigures(_ urls: [URL], in dir: URL) {
        let snippets = urls.compactMap { Self.importGraphic($0, into: dir) }.map(Self.figure)
        guard !snippets.isEmpty else { return }
        insertBlock(snippets.joined(separator: "\n"))
        ensurePackage("graphicx")
    }

    /// Insère un bloc sur ses propres lignes.
    func insertBlock(_ block: String) {
        let ns = string as NSString
        let sel = selectedRange()
        var text = block
        if sel.location > 0 && ns.character(at: sel.location - 1) != 10 { text = "\n" + text }
        if !text.hasSuffix("\n") { text += "\n" }
        replace(sel, with: text)
    }

    /// Ajoute \usepackage{…} avant \begin{document} s'il manque (sauf classe annales, qui l'a déjà).
    func ensurePackage(_ name: String) {
        let s = string
        if s.contains("{annales}") { return }
        if s.range(of: #"\\usepackage(\[[^\]]*\])?\{[^}]*\b"# + name + #"\b"#, options: .regularExpression) != nil { return }
        guard let r = s.range(of: "\\begin{document}") else { return }
        let loc = NSRange(r, in: s).location
        let sel = selectedRange()
        let line = "\\usepackage{\(name)}\n"
        replace(NSRange(location: loc, length: 0), with: line)
        setSelectedRange(NSRange(location: sel.location + (line as NSString).length, length: sel.length))
    }

    static func figure(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return """
        \\begin{figure}[h]
          \\centering
          \\includegraphics[width=0.8\\linewidth]{\(path)}
          \\caption{}
          \\label{fig:\(String(label))}
        \\end{figure}
        """
    }

    /// Copie l'image dans <dossier>/images (ou la garde si elle y est déjà) ; renvoie le chemin relatif.
    static func importGraphic(_ url: URL, into dir: URL) -> String? {
        let fm = FileManager.default
        let base = dir.standardizedFileURL.path + "/"
        let src = url.standardizedFileURL
        let ext = src.pathExtension.lowercased()
        if src.path.hasPrefix(base) && graphicExtensions.contains(ext) {
            return String(src.path.dropFirst(base.count))
        }
        let images = dir.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: images, withIntermediateDirectories: true)
        let clean = cleanName(src.deletingPathExtension().lastPathComponent)
        if graphicExtensions.contains(ext) {
            let dest = FileUtils.unique(images.appendingPathComponent(clean + "." + ext))
            guard (try? fm.copyItem(at: src, to: dest)) != nil else { return nil }
            return "images/" + dest.lastPathComponent
        }
        guard let image = NSImage(contentsOf: src) else { return nil }
        return savePNG(image, into: dir, base: clean)
    }

    static func savePNG(_ image: NSImage, into dir: URL, base: String) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let images = dir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let stamp = base == "capture" ? "-" + String(Int(Date().timeIntervalSince1970)) : ""
        let dest = FileUtils.unique(images.appendingPathComponent(cleanName(base) + stamp + ".png"))
        guard (try? data.write(to: dest)) != nil else { return nil }
        return "images/" + dest.lastPathComponent
    }

    /// LaTeX n'aime pas les espaces ni les accents dans les noms de fichiers d'images.
    static func cleanName(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        let mapped = folded.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let joined = String(mapped).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "image" : joined
    }
}

// MARK: - Numéros de ligne

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, (tv.font?.pointSize ?? 13) - 2), weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        func draw(_ number: Int, fragmentY: CGFloat, height: CGFloat) {
            let y = convert(NSPoint(x: 0, y: fragmentY + tv.textContainerOrigin.y), from: tv).y
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (height - size.height) / 2),
                       withAttributes: attrs)
        }

        var number = LatexEditor.Coordinator.lineNumber(in: ns, at: chars.location)
        var index = ns.lineRange(for: NSRange(location: min(chars.location, ns.length), length: 0)).location
        while index < ns.length && index <= NSMaxRange(chars) {
            let line = ns.lineRange(for: NSRange(location: index, length: 0))
            let glyph = lm.glyphIndexForCharacter(at: line.location)
            let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(number, fragmentY: frag.minY, height: frag.height)
            number += 1
            let next = NSMaxRange(line)
            if next <= index { break }
            index = next
        }
        if index >= ns.length && (ns.length == 0 || ns.character(at: ns.length - 1) == 10) {
            let extra = lm.extraLineFragmentRect
            if extra.height > 0 { draw(number, fragmentY: extra.minY, height: extra.height) }
        }
    }
}
