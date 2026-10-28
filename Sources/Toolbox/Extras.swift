import SwiftUI
import AppKit
import EventKit
import PDFCore

// MARK: - Bulles de la mascotte (« Texte copié », « Bravo, plus d'erreurs ! »…)

final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Equatable {
        let id = UUID()
        let text: String
        let cheer: Bool        // la mascotte saute de joie
    }

    @Published var current: Toast?
    private var hide: DispatchWorkItem?

    func show(_ text: String, cheer: Bool = false, seconds: Double = 3) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { self.current = Toast(text: text, cheer: cheer) }
            self.hide?.cancel()
            let work = DispatchWorkItem { [weak self] in
                withAnimation(.easeInOut(duration: 0.3)) { self?.current = nil }
            }
            self.hide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }
}

struct ToastView: View {
    @ObservedObject var center = ToastCenter.shared

    var body: some View {
        if let t = center.current {
            HStack(spacing: 10) {
                FeuilleMascot(mood: t.cheer ? .party : .normal, poke: t.cheer ? Date() : nil)
                    .frame(width: 58, height: 52)
                Text(t.text)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.35)))
            }
            .padding(14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
            .onTapGesture { withAnimation { center.current = nil } }
        }
    }
}

// MARK: - Historique du presse-papiers

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
    }

    @Published var items: [Item] = []
    @Published var paused = UserDefaults.standard.bool(forKey: "clipboard.paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "clipboard.paused") }
    }
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var ownCopy = false
    let limit = 20

    /// Gestionnaires de mots de passe : ils marquent ce qu'ils copient, on ne le garde jamais.
    private let secretTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                               "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType"]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        if ownCopy { ownCopy = false; return }
        guard !paused else { return }
        let types = (pb.types ?? []).map { $0.rawValue }
        if types.contains(where: { secretTypes.contains($0) }) { return }
        guard let s = pb.string(forType: .string) else { return }
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { return }
        items.removeAll { $0.text == text }
        items.insert(Item(text: text, date: Date()), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    func copy(_ item: Item) {
        ownCopy = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        // remonte en tête
        items.removeAll { $0.id == item.id }
        items.insert(Item(text: item.text, date: Date()), at: 0)
        ToastCenter.shared.show("Copié !")
    }

    func remove(_ item: Item) { items.removeAll { $0.id == item.id } }
    func clear() { items = [] }
}

// MARK: - Capture d'écran → texte (OCR hors ligne)

enum ScreenText {
    /// Sélection d'une zone de l'écran, reconnaissance du texte, copie dans le presse-papiers.
    static func capture() {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-capture-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            // -i : sélection à la souris (Espace = fenêtre, Échap = annuler) ; -x : sans bruit
            _ = try? Shell.run("/usr/sbin/screencapture", ["-i", "-x", tmp.path])
            guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return   // annulé
            }
            do {
                let text = try OCR.text(of: image).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    if text.isEmpty {
                        ToastCenter.shared.show("Aucun texte trouvé dans la zone.")
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        let n = text.count
                        ToastCenter.shared.show("Texte copié (\(n) caractère\(n > 1 ? "s" : "")) — colle-le avec ⌘V", cheer: true)
                    }
                }
            } catch {
                DispatchQueue.main.async { ToastCenter.shared.show("Lecture impossible : \(error.localizedDescription)") }
            }
        }
    }
}

// MARK: - Dossier surveillé

final class WatchFolderStore: ObservableObject {
    static let shared = WatchFolderStore()

    enum Action: String, CaseIterable, Identifiable {
        case compress, ocr, both
        var id: String { rawValue }
        var title: String {
            switch self {
            case .compress: return "Compresser"
            case .ocr: return "Rendre cherchable (OCR)"
            case .both: return "OCR puis compresser"
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let ok: Bool
        let output: URL?
    }

    @Published var folder: URL? = UserDefaults.standard.string(forKey: "watch.folder").map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(folder?.path, forKey: "watch.folder"); seedSeen() }
    }
    @Published var action = Action(rawValue: UserDefaults.standard.string(forKey: "watch.action") ?? "") ?? .compress {
        didSet { UserDefaults.standard.set(action.rawValue, forKey: "watch.action") }
    }
    @Published var enabled = UserDefaults.standard.bool(forKey: "watch.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "watch.enabled"); if enabled { seedSeen() } }
    }
    @Published var busy: String?
    @Published var log: [Entry] = []

    private var seen = Set<String>()
    private var timer: Timer?
    private var queue: [URL] = []

    static let outputName = "Traités par Toolbox"

    func start() {
        guard timer == nil else { return }
        seedSeen()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
    }

    /// Les PDF déjà présents quand on active la surveillance ne sont pas traités : seulement les nouveaux.
    private func seedSeen() {
        seen = Set(currentPDFs().map(key))
    }

    private func key(_ u: URL) -> String {
        let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(u.lastPathComponent)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private func currentPDFs() -> [URL] {
        guard let f = folder,
              let list = try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        return list.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    private func scan() {
        guard enabled, busy == nil, folder != nil else { return }
        for u in currentPDFs() {
            let k = key(u)
            guard !seen.contains(k) else { continue }
            // encore en cours de copie ? on attend qu'il ne bouge plus
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(m) < 2 { continue }
            seen.insert(k)
            queue.append(u)
        }
        processNext()
    }

    private func processNext() {
        guard busy == nil, !queue.isEmpty, let folder = folder else { return }
        let input = queue.removeFirst()
        let action = self.action
        busy = input.lastPathComponent
        let outDir = folder.appendingPathComponent(Self.outputName, isDirectory: true)
        runInBackground({ () -> (URL, String) in
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let output = FileUtils.unique(outDir.appendingPathComponent(input.lastPathComponent))
            switch action {
            case .compress:
                let r = try Compressor.compress(input, level: .balanced, to: output)
                return (output, Self.saving(r))
            case .ocr:
                _ = try OCR.makeSearchable(input, to: output)
                return (output, "texte reconnu")
            case .both:
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                defer { try? FileManager.default.removeItem(at: tmp) }
                _ = try OCR.makeSearchable(input, to: tmp)
                let r = try Compressor.compress(tmp, level: .balanced, to: output)
                return (output, "OCR + " + Self.saving(r))
            }
        }) { [weak self] r in
            guard let self = self else { return }
            self.busy = nil
            switch r {
            case .success(let (out, detail)):
                self.log.insert(Entry(name: input.lastPathComponent, detail: detail, ok: true, output: out), at: 0)
                ToastCenter.shared.show("\(input.lastPathComponent) traité (\(detail))")
            case .failure(let e):
                self.log.insert(Entry(name: input.lastPathComponent, detail: e.localizedDescription, ok: false, output: nil), at: 0)
            }
            if self.log.count > 8 { self.log.removeLast(self.log.count - 8) }
            self.processNext()
        }
    }

    static func saving(_ r: CompressionResult) -> String {
        guard r.before > 0 else { return "compressé" }
        let pct = Int((1 - Double(r.after) / Double(r.before)) * 100)
        return pct > 0 ? "−\(pct) %" : "déjà optimisé"
    }
}

// MARK: - Comptes à rebours (examens)

struct Countdown: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var date: Date
    var fromCalendar = false
}

final class ExamsStore: ObservableObject {
    @Published var manual: [Countdown] = [] { didSet { save() } }
    @Published var fromCalendar: [Countdown] = []
    @Published var newTitle = ""
    @Published var newDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @Published var adding = false

    private let store = EKEventStore()
    static let pattern = #"(?i)\b(cc\d*|partiels?|examens?|exams?|contr[oô]les?|ds\d*|rattrapages?|interros?|qcm|soutenances?|oraux|oral)\b"#

    init() {
        if let data = UserDefaults.standard.data(forKey: "home.exams"),
           let list = try? JSONDecoder().decode([Countdown].self, from: data) { manual = list }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(manual) { UserDefaults.standard.set(data, forKey: "home.exams") }
    }

    var all: [Countdown] {
        let today = Calendar.current.startOfDay(for: Date())
        return (manual + fromCalendar).filter { $0.date >= today }.sorted { $0.date < $1.date }
    }

    /// Événements des 120 prochains jours dont le titre ressemble à un examen.
    func loadCalendar() {
        guard HomeStore.hasAccess else { fromCalendar = []; return }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 120, to: start) else { return }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        var seen = Set<String>()
        fromCalendar = events.compactMap { e -> Countdown? in
            guard let title = e.title, title.range(of: Self.pattern, options: .regularExpression) != nil else { return nil }
            let key = title + "\(Calendar.current.startOfDay(for: e.startDate).timeIntervalSince1970)"
            guard seen.insert(key).inserted else { return nil }
            return Countdown(title: title, date: e.startDate, fromCalendar: true)
        }
    }

    func add() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            manual.append(Countdown(title: t, date: newDate))
            newTitle = ""
            adding = false
        }
    }

    func remove(_ c: Countdown) {
        withAnimation { manual.removeAll { $0.id == c.id } }
    }

    static func daysLeft(_ d: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
    }
}
