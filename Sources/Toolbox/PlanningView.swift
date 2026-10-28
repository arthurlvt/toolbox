import SwiftUI
import AppKit
import EventKit
import Vision
import PDFKit
import UniformTypeIdentifiers
import PDFCore

// MARK: - Modèle

struct WorkShift: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var breakMinutes: Int
    var note = ""
    var eventID: String?
    var pauses: [PauseSlot] = []     // trous entre les créneaux d'une même journée
    var repaired = false             // pas enregistré

    var paidMinutes: Int { max(0, Int((end.timeIntervalSince(start) / 60).rounded()) - breakMinutes) }

    var pausesMinutes: Int { pauses.reduce(0) { $0 + Int(($1.end.timeIntervalSince($1.start) / 60).rounded()) } }

    var pausesText: String {
        pauses.map { "\(PlanningToolView.time.string(from: $0.start))–\(PlanningToolView.time.string(from: $0.end))" }
            .joined(separator: ", ")
    }
}

struct PauseSlot: Codable, Equatable {
    var start: Date
    var end: Date
}

extension WorkShift {
    enum CodingKeys: String, CodingKey { case id, start, end, breakMinutes, note, eventID, pauses }

    // les anciens fichiers n'ont pas de pauses
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        breakMinutes = try c.decode(Int.self, forKey: .breakMinutes)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
        pauses = try c.decodeIfPresent([PauseSlot].self, forKey: .pauses) ?? []
        // réparation : une ancienne version ajoutait 1 min par pause
        if !pauses.isEmpty, breakMinutes == pausesMinutes + pauses.count {
            breakMinutes = pausesMinutes
            repaired = true
        }
    }
}

struct ShiftDraft: Identifiable, Equatable {
    var id = UUID()
    var include = true
    var day: Date
    var startMin: Int
    var endMin: Int          // peut dépasser 24 h (fermeture après minuit)
    var breakMinutes: Int
    var source: String
    var warning: String?
    var gaps: [Gap] = []     // pauses entre deux créneaux du même jour

    struct Gap: Equatable {
        var startMin: Int
        var endMin: Int
    }

    var gapMinutes: Int { gaps.reduce(0) { $0 + $1.endMin - $1.startMin } }

    func date(_ minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: day)) ?? day
    }

    var gapsText: String {
        gaps.map { "\(PlanningToolView.time.string(from: date($0.startMin)))–\(PlanningToolView.time.string(from: date($0.endMin)))" }
            .joined(separator: ", ")
    }

    var start: Date { Calendar.current.date(byAdding: .minute, value: startMin, to: Calendar.current.startOfDay(for: day)) ?? day }
    var end: Date { Calendar.current.date(byAdding: .minute, value: endMin, to: Calendar.current.startOfDay(for: day)) ?? day }
    /// Avec des pauses entre créneaux, seules ces pauses comptent (pas de pause en plus).
    var paidMinutes: Int { max(0, endMin - startMin - (gaps.isEmpty ? breakMinutes : gapMinutes)) }
}

/// Un morceau de texte lu sur le planning (coordonnées 0…1, origine en haut à gauche).
struct OCRToken {
    var text: String
    var rect: CGRect
}

struct DayRef: Equatable {
    var weekday: Int?        // 0 = lundi … 6 = dimanche
    var day: Int?
    var month: Int?
    var year: Int?
    var isFull: Bool { day != nil && month != nil }
}

// MARK: - Lecture d'un planning (photo, capture, PDF ou texte)

enum ShiftParser {
    static let dayIndex: [String: Int] = ["lundi": 0, "mardi": 1, "mercredi": 2, "jeudi": 3, "vendredi": 4, "samedi": 5, "dimanche": 6,
                                          "lun": 0, "mar": 1, "mer": 2, "jeu": 3, "ven": 4, "sam": 5, "dim": 6]
    static let monthIndex: [String: Int] = ["janv": 1, "janvier": 1, "fev": 2, "fevr": 2, "fevrier": 2, "mars": 3, "avr": 4, "avril": 4,
                                            "mai": 5, "juin": 6, "juil": 7, "juillet": 7, "aout": 8, "sept": 9, "septembre": 9,
                                            "oct": 10, "octobre": 10, "nov": 11, "novembre": 11, "dec": 12, "decembre": 12]
    static let dayAlt = "lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|lun|mar|mer|jeu|ven|sam|dim"
    static let monthAlt = "janvier|janv|fevrier|fevr|fev|mars|avril|avr|mai|juin|juillet|juil|aout|septembre|sept|octobre|oct|novembre|nov|decembre|dec"

    static let reWeekday = try! NSRegularExpression(pattern: "\\b(" + dayAlt + ")\\b\\.?\\s*(\\d{1,2})?(?:\\s*(?:/\\s*(\\d{1,2})|(" + monthAlt + ")\\b\\.?))?")
    static let reDate = try! NSRegularExpression(pattern: #"(?<![\d:h.])(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?!\d)|(?<!\d)(\d{1,2})[.-](\d{1,2})[.-](\d{2,4})(?!\d)"#)
    static let reDayMonth = try! NSRegularExpression(pattern: "(?<!\\d)(\\d{1,2})\\s*(" + monthAlt + ")\\b")
    static let reRange = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\s*[h:.](\d{2})?\s*(?:-|a|>|/|au)\s*(\d{1,2})(?:\s*[h:.](\d{2})?)?(?!\d)"#)
    static let reTime = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\s*[h:](\d{2})?(?!\d)"#)

    static func normalize(_ s: String) -> String {
        var t = CourseLibrary.fold(s).lowercased()
        for d in ["–", "—", "→", "−", "⇒", "~"] { t = t.replacingOccurrences(of: d, with: "-") }
        return t
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] {
        re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound else { return nil }
        return (s as NSString).substring(with: r)
    }

    private static func int(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> Int? { group(m, i, s).flatMap { Int($0) } }

    /// Dates trouvées dans un texte : (position, longueur, date).
    static func dates(in t: String) -> [(Int, Int, DayRef)] {
        var out: [(Int, Int, DayRef)] = []
        func valid(_ d: Int?, _ m: Int?) -> Bool { (d.map { (1...31).contains($0) } ?? true) && (m.map { (1...12).contains($0) } ?? true) }
        for m in matches(reWeekday, t) {
            guard let w = group(m, 1, t).flatMap({ dayIndex[$0] }) else { continue }
            var ref = DayRef(weekday: w, day: int(m, 2, t), month: int(m, 3, t) ?? group(m, 4, t).flatMap { monthIndex[$0] })
            if !valid(ref.day, ref.month) { ref.day = nil; ref.month = nil }
            out.append((m.range.location, m.range.length, ref))
        }
        let taken = out.map { $0.0 }
        for m in matches(reDate, t) where !taken.contains(where: { Swift.abs($0 - m.range.location) < 12 }) {
            let alt = group(m, 1, t) == nil
            let d = int(m, alt ? 4 : 1, t), mo = int(m, alt ? 5 : 2, t)
            var y = int(m, alt ? 6 : 3, t)
            if let yy = y, yy < 100 { y = 2000 + yy }
            guard valid(d, mo) else { continue }
            out.append((m.range.location, m.range.length, DayRef(day: d, month: mo, year: y)))
        }
        let taken2 = out.map { $0.0 }
        for m in matches(reDayMonth, t) where !taken2.contains(where: { Swift.abs($0 - m.range.location) < 12 }) {
            let d = int(m, 1, t), mo = group(m, 2, t).flatMap { monthIndex[$0] }
            guard valid(d, mo) else { continue }
            out.append((m.range.location, m.range.length, DayRef(day: d, month: mo)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Créneaux horaires : (position, longueur, début en minutes, fin en minutes).
    static func ranges(in t: String) -> [(Int, Int, Int, Int)] {
        var out: [(Int, Int, Int, Int)] = []
        func accept(_ a: Int, _ b0: Int) -> Int? {
            var b = b0
            if b <= a { b += 1440 }
            return (45...(14 * 60)).contains(b - a) ? b : nil
        }
        for m in matches(reRange, t) {
            guard let h1 = int(m, 1, t), let h2 = int(m, 3, t), h1 <= 24, h2 <= 24 else { continue }
            let m1 = int(m, 2, t) ?? 0, m2 = int(m, 4, t) ?? 0
            guard m1 < 60, m2 < 60 else { continue }
            let a = h1 * 60 + m1
            if let b = accept(a, h2 * 60 + m2) { out.append((m.range.location, m.range.length, a, b)) }
        }
        if out.isEmpty {
            // « 12:00   16:30 » : deux heures seules qui se suivent
            let times = matches(reTime, t).compactMap { m -> (Int, Int, Int)? in
                guard let h = int(m, 1, t), h <= 24 else { return nil }
                let mm = int(m, 2, t) ?? 0
                return mm < 60 ? (m.range.location, m.range.length, h * 60 + mm) : nil
            }
            var i = 0
            while i + 1 < times.count {
                if let b = accept(times[i].2, times[i + 1].2) {
                    out.append((times[i].0, times[i + 1].0 + times[i + 1].1 - times[i].0, times[i].2, b))
                    i += 2
                } else {
                    i += 1
                }
            }
        }
        return out
    }

    static func monday(of date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = .current
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    /// Lundi de la semaine visée par défaut : celle-ci en début de semaine, la suivante à partir du jeudi.
    static func defaultWeek(_ now: Date = Date()) -> Date {
        let wd = (Calendar.current.component(.weekday, from: now) + 5) % 7   // 0 = lundi
        let m = monday(of: now)
        return wd >= 3 ? (Calendar.current.date(byAdding: .day, value: 7, to: m) ?? m) : m
    }

    static func resolve(_ ref: DayRef, weekStart: Date) -> Date? {
        let cal = Calendar.current
        if let d = ref.day, let m = ref.month {
            let baseYear = cal.component(.year, from: weekStart)
            let years = ref.year.map { [$0] } ?? [baseYear - 1, baseYear, baseYear + 1]
            let candidates = years.compactMap { cal.date(from: DateComponents(year: $0, month: m, day: d)) }
            return candidates.min { Swift.abs($0.timeIntervalSince(weekStart)) < Swift.abs($1.timeIntervalSince(weekStart)) }
        }
        if let d = ref.day {
            for offset in -10...40 {
                guard let date = cal.date(byAdding: .day, value: offset, to: weekStart) else { continue }
                let wd = (cal.component(.weekday, from: date) + 5) % 7
                if cal.component(.day, from: date) == d, ref.weekday.map({ $0 == wd }) ?? true { return date }
            }
            return nil
        }
        if let w = ref.weekday { return cal.date(byAdding: .day, value: w, to: weekStart) }
        return nil
    }

    struct Found {
        var drafts: [ShiftDraft]
        var weekStart: Date
        var nameFound: Bool
    }

    static func parse(_ tokens: [OCRToken], name: String?, weekStart forced: Date?, breakFor: (Int) -> Int) -> Found {
        struct Header { var ref: DayRef; var rect: CGRect; var token: Int; var offset: Int }
        struct Slot { var start: Int; var end: Int; var rect: CGRect; var token: Int; var offset: Int; var text: String }
        var headers: [Header] = []
        var slots: [Slot] = []
        for (i, tok) in tokens.enumerated() {
            let t = normalize(tok.text)
            let len = Double(max(1, (t as NSString).length))
            let x0 = Double(tok.rect.minX), w0 = Double(tok.rect.width)
            func sub(_ off: Int, _ l: Int) -> CGRect {
                CGRect(x: x0 + w0 * Double(off) / len, y: Double(tok.rect.minY),
                       width: Swift.max(0.005, w0 * Double(l) / len), height: Double(tok.rect.height))
            }
            for d in dates(in: t) { headers.append(Header(ref: d.2, rect: sub(d.0, d.1), token: i, offset: d.0)) }
            for r in ranges(in: t) { slots.append(Slot(start: r.2, end: r.3, rect: sub(r.0, r.1), token: i, offset: r.0, text: tok.text)) }
        }

        // ne garder que la ligne de la personne (plannings d'équipe)
        var nameFound = false
        if let n = name.map(normalize)?.trimmingCharacters(in: .whitespaces), n.count >= 2,
           let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: n) + "\\b") {
            let nameTokens = tokens.indices.filter { !matches(re, normalize(tokens[$0].text)).isEmpty }
            if !nameTokens.isEmpty {
                let inside = slots.filter { nameTokens.contains($0.token) }
                if !inside.isEmpty {
                    slots = inside
                    nameFound = true
                } else {
                    let band = slots.filter { s in
                        nameTokens.contains { k in
                            let r = tokens[k].rect
                            return Swift.abs(r.midY - s.rect.midY) < max(r.height, s.rect.height) * 0.75
                        }
                    }
                    if !band.isEmpty { slots = band; nameFound = true }
                }
            }
        }

        // semaine de référence (pour les « Lundi », « Mardi »… sans date)
        let weekStart: Date = forced ?? {
            let full = headers.compactMap { h -> Date? in h.ref.isFull ? resolve(h.ref, weekStart: defaultWeek()) : nil }
            return full.min().map(monday(of:)) ?? defaultWeek()
        }()

        // en-têtes alignés sur une ligne = planning en colonnes (un jour par colonne)
        let ys = headers.map { $0.rect.midY }.sorted()
        let median = ys.isEmpty ? 0 : ys[ys.count / 2]
        let sameRow = headers.filter { Swift.abs($0.rect.midY - median) < 0.02 }
        let xs = sameRow.map { $0.rect.midX }
        let columns = sameRow.count >= 2 && Double(sameRow.count) >= 0.6 * Double(headers.count) && ((xs.max() ?? 0) - (xs.min() ?? 0)) > 0.15

        var drafts: [ShiftDraft] = []
        var seen = Set<String>()
        for s in slots {
            var header: Header?
            let same = headers.filter { $0.token == s.token }
            if !same.isEmpty {
                header = same.last { $0.offset <= s.offset } ?? same.first
            } else if columns {
                header = headers.filter { $0.rect.midY <= s.rect.midY + 0.01 }
                    .min { Swift.abs($0.rect.midX - s.rect.midX) < Swift.abs($1.rect.midX - s.rect.midX) }
            } else {
                header = headers.filter { $0.rect.midY <= s.rect.midY + 0.01 }.max { a, b in
                    if Swift.abs(a.rect.midY - b.rect.midY) > 0.005 { return a.rect.midY < b.rect.midY }
                    return Swift.abs(a.rect.midX - s.rect.midX) > Swift.abs(b.rect.midX - s.rect.midX)
                }
            }
            guard let h = header, let day = resolve(h.ref, weekStart: weekStart) else { continue }
            let key = "\(Calendar.current.startOfDay(for: day).timeIntervalSince1970)-\(s.start)-\(s.end)"
            guard seen.insert(key).inserted else { continue }
            drafts.append(ShiftDraft(day: Calendar.current.startOfDay(for: day), startMin: s.start, endMin: s.end,
                                     breakMinutes: breakFor(s.end - s.start), source: s.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        drafts.sort { ($0.day, $0.startMin) < ($1.day, $1.startMin) }
        return Found(drafts: drafts, weekStart: weekStart, nameFound: nameFound)
    }

    /// Texte tapé ou collé : une ligne = un morceau.
    static func tokens(fromText text: String) -> [OCRToken] {
        text.components(separatedBy: .newlines).enumerated().compactMap { i, line in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                : OCRToken(text: line, rect: CGRect(x: 0, y: Double(i) * 0.02, width: 1, height: 0.015))
        }
    }

    static func tokens(fromImage image: CGImage, yOffset: Double = 0) throws -> [OCRToken] {
        try recognize(VNImageRequestHandler(cgImage: image, options: [:]), yOffset: yOffset)
    }

    /// Depuis le fichier : Vision gère lui-même le format (HEIC, PNG…) et l'orientation des photos.
    static func tokens(fromURL url: URL) throws -> [OCRToken] {
        try recognize(VNImageRequestHandler(url: url, options: [:]), yOffset: 0)
    }

    /// Lecture précise en français, puis, si rien n'est trouvé, lecture rapide sans contrainte de langue.
    static func recognize(_ handler: VNImageRequestHandler, yOffset: Double) throws -> [OCRToken] {
        var lastError: Error?
        for attempt in 0..<2 {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = attempt == 0 ? .accurate : .fast
            request.usesLanguageCorrection = attempt == 0
            if attempt == 0 { request.recognitionLanguages = ["fr-FR", "en-US"] }
            do {
                try handler.perform([request])
            } catch {
                lastError = error
                continue
            }
            let found = (request.results ?? []).compactMap { obs -> OCRToken? in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                let b = obs.boundingBox
                return OCRToken(text: text, rect: CGRect(x: b.minX, y: 1 - b.maxY + CGFloat(yOffset), width: b.width, height: b.height))
            }
            if !found.isEmpty { return found }
        }
        if let e = lastError { throw e }
        return []
    }

    /// Texte lisible dans l'ordre de lecture (pour vérifier ce qui a été lu).
    static func readingText(_ tokens: [OCRToken]) -> String {
        let sorted = tokens.sorted { a, b in
            Swift.abs(a.rect.midY - b.rect.midY) < 0.008 ? a.rect.minX < b.rect.minX : a.rect.midY < b.rect.midY
        }
        var lines: [String] = []
        var lastY = -1.0
        for t in sorted {
            if lastY >= 0, Swift.abs(t.rect.midY - lastY) < 0.008, !lines.isEmpty {
                lines[lines.count - 1] += "   " + t.text
            } else {
                lines.append(t.text)
                lastY = t.rect.midY
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Stockage, calendrier, heures

final class PlanningStore: ObservableObject {
    static let shared = PlanningStore()

    @Published var shifts: [WorkShift] = [] { didSet { if shifts != oldValue { save(); refreshConflicts() } } }
    @Published var drafts: [ShiftDraft] = []
    @Published var importing = false
    @Published var reading = false
    @Published var ocrText = ""
    @Published var image: NSImage?
    @Published var tokens: [OCRToken] = []
    @Published var weekStart = ShiftParser.defaultWeek()
    @Published var weekForced = false
    @Published var nameFound = false
    @Published var weekOffset = 0
    @Published var editing: WorkShift?
    @Published var showSettings = false
    @Published var conflicts: [UUID: String] = [:]
    @Published var addToCalendar = UserDefaults.standard.object(forKey: "planning.calendar.on") as? Bool ?? true {
        didSet { UserDefaults.standard.set(addToCalendar, forKey: "planning.calendar.on") }
    }
    @Published var calendarID = UserDefaults.standard.string(forKey: "planning.calendar") ?? "" {
        didSet {
            UserDefaults.standard.set(calendarID, forKey: "planning.calendar")
            // nouveau calendrier choisi : les shifts à venir y déménagent
            if calendarID != oldValue, !shifts.isEmpty, !movingCalendar { syncCalendar(all: true) }
        }
    }
    private var movingCalendar = false
    @Published var eventTitle = UserDefaults.standard.string(forKey: "planning.title") ?? "Travail McDo" {
        didSet { UserDefaults.standard.set(eventTitle, forKey: "planning.title") }
    }
    @Published var breakMinutes = UserDefaults.standard.object(forKey: "planning.break") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(breakMinutes, forKey: "planning.break"); applyBreakRule() }
    }
    @Published var breakAfterHours = UserDefaults.standard.object(forKey: "planning.breakAfter") as? Double ?? 6 {
        didSet { UserDefaults.standard.set(breakAfterHours, forKey: "planning.breakAfter"); applyBreakRule() }
    }
    @Published var contractHours = UserDefaults.standard.string(forKey: "planning.contract") ?? "" {
        didSet { UserDefaults.standard.set(contractHours, forKey: "planning.contract") }
    }
    @Published var alarmMinutes = UserDefaults.standard.object(forKey: "planning.alarm") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(alarmMinutes, forKey: "planning.alarm") }
    }
    @Published var filterByName = UserDefaults.standard.object(forKey: "planning.filterName") as? Bool ?? true {
        didSet { UserDefaults.standard.set(filterByName, forKey: "planning.filterName"); reparse() }
    }
    @Published var nameOnPlanning = UserDefaults.standard.string(forKey: "planning.name") ?? UserProfile.firstName {
        didSet { UserDefaults.standard.set(nameOnPlanning, forKey: "planning.name") }
    }
    @Published var mergeDays = UserDefaults.standard.object(forKey: "planning.merge") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mergeDays, forKey: "planning.merge"); reparse() }
    }
    @Published var status: StatusMessage?

    let events = EKEventStore()

    var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/Planning.json")
    }

    init() {
        var needsResync = false
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([WorkShift].self, from: data) {
            shifts = list.map { var s = $0; if s.repaired { needsResync = true }; s.repaired = false; return s }
        }
        refreshConflicts()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
            self?.refreshConflicts()
            self?.objectWillChange.send()     // calendrier créé ou renommé dans l'app Calendrier
        }
        adoptWorkCalendar()
        if needsResync {
            save()
            // les notes « Payé : … » des événements étaient fausses
            if HomeStore.hasAccess, addToCalendar { DispatchQueue.main.async { self.syncCalendar(all: true) } }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(shifts) { try? data.write(to: file, options: .atomic) }
    }

    func breakFor(_ minutes: Int) -> Int {
        breakMinutes > 0 && Double(minutes) >= breakAfterHours * 60 ? breakMinutes : 0
    }

    private func applyBreakRule() {
        for i in drafts.indices where drafts[i].gaps.isEmpty { drafts[i].breakMinutes = breakFor(drafts[i].endMin - drafts[i].startMin) }
    }

    // MARK: Import

    func beginImport() {
        status = nil
        drafts = []
        tokens = []
        ocrText = ""
        image = nil
        weekForced = false
        weekStart = ShiftParser.defaultWeek()
        importing = true
    }

    func importFile(_ url: URL) {
        beginImport()
        let isPDF = url.pathExtension.lowercased() == "pdf"
        read(preview: isPDF ? nil : NSImage(contentsOf: url)) {
            if isPDF {
                guard let doc = PDFDocument(url: url) else { throw MathError(message: "PDF illisible") }
                var all: [OCRToken] = []
                for i in 0..<min(doc.pageCount, 4) {
                    guard let page = doc.page(at: i) else { continue }
                    if let text = page.string, text.count > 40 {
                        all += ShiftParser.tokens(fromText: text).map { var t = $0; t.rect.origin.y += CGFloat(i); return t }
                    } else if let img = Converter.render(page, dpi: 220) {
                        all += try ShiftParser.tokens(fromImage: img, yOffset: Double(i))
                    }
                }
                return all
            }
            let viaURL = (try? ShiftParser.tokens(fromURL: url)) ?? []
            if !viaURL.isEmpty { return viaURL }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw MathError(message: "Image illisible") }
            return try ShiftParser.tokens(fromImage: img)
        }
    }

    func importPasteboard() {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            beginImport()
            read(preview: img) { try ShiftParser.tokens(fromImage: cg) }
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            beginImport()
            ocrText = text
            tokens = ShiftParser.tokens(fromText: text)
            reparse()
        } else {
            ToastCenter.shared.show("Rien à coller : copie d'abord une image ou le texte du planning.")
        }
    }

    func captureScreen() {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-planning-\(UUID().uuidString).png")
            _ = try? Shell.run("/usr/sbin/screencapture", ["-i", "-x", tmp.path])
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: tmp.path) else { return }
                self.importFile(tmp)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { try? FileManager.default.removeItem(at: tmp) }
            }
        }
    }

    func typeText() {
        beginImport()
        ocrText = "Lundi 9h-14h\nMercredi 18h-23h30\nSamedi 11h-15h"
        tokens = ShiftParser.tokens(fromText: ocrText)
        reparse()
    }

    private func read(preview: NSImage?, _ work: @escaping () throws -> [OCRToken]) {
        image = preview
        reading = true
        runInBackground(work) { [weak self] r in
            guard let self = self else { return }
            self.reading = false
            switch r {
            case .success(let t):
                if t.isEmpty {
                    self.status = .err("Aucun texte trouvé dans l'image. Essaie « Coller » avec le texte, ou tape les horaires à gauche puis « Relire ».")
                } else {
                    self.status = nil
                }
                self.tokens = t
                self.ocrText = ShiftParser.readingText(t)
                self.reparse()
            case .failure(let e):
                self.ocrText = ""
                self.status = .err(e)
            }
        }
    }

    /// Relit le texte corrigé à la main.
    func rereadText() {
        tokens = ShiftParser.tokens(fromText: ocrText)
        reparse()
    }

    func reparse() {
        guard !tokens.isEmpty else { return }
        let found = ShiftParser.parse(tokens, name: filterByName ? nameOnPlanning : nil, weekStart: weekForced ? weekStart : nil,
                                      breakFor: breakFor)
        if !weekForced { weekStart = found.weekStart }
        nameFound = found.nameFound
        drafts = (mergeDays ? Self.mergeByDay(found.drafts) : found.drafts).map { d in
            var d = d
            if shifts.contains(where: { Swift.abs($0.start.timeIntervalSince(d.start)) < 60 && Swift.abs($0.end.timeIntervalSince(d.end)) < 60 }) {
                d.include = false
                d.warning = "Déjà dans ton planning"
            } else {
                d.warning = conflict(start: d.start, end: d.end, ignoring: nil)
            }
            return d
        }
    }

    /// Les créneaux d'un même jour deviennent une seule journée ; les trous entre eux sont les pauses.
    static func mergeByDay(_ list: [ShiftDraft]) -> [ShiftDraft] {
        let byDay = Dictionary(grouping: list) { Calendar.current.startOfDay(for: $0.day) }
        return byDay.keys.sorted().compactMap { day -> ShiftDraft? in
            let parts = (byDay[day] ?? []).sorted { $0.startMin < $1.startMin }
            guard var merged = parts.first else { return nil }
            guard parts.count > 1 else { return merged }
            merged.breakMinutes = 0
            var reach = merged.endMin
            for p in parts.dropFirst() {
                if p.startMin > reach { merged.gaps.append(ShiftDraft.Gap(startMin: reach, endMin: p.startMin)) }
                reach = max(reach, p.endMin)
            }
            merged.endMin = reach
            merged.source = "\(parts.count) créneaux"
            return merged
        }
    }

    func setWeek(_ d: Date) {
        weekStart = ShiftParser.monday(of: d)
        weekForced = true
        reparse()
    }

    func confirm() {
        let chosen = drafts.filter { $0.include }
        guard !chosen.isEmpty else { importing = false; return }
        var created: [WorkShift] = []
        var calendarError: String?
        for d in chosen {
            var s = WorkShift(start: d.start, end: d.end, breakMinutes: d.gaps.isEmpty ? d.breakMinutes : d.gapMinutes,
                              pauses: d.gaps.map { PauseSlot(start: d.date($0.startMin), end: d.date($0.endMin)) })
            if addToCalendar {
                do { s.eventID = try writeEvent(for: s) } catch { calendarError = error.localizedDescription }
            }
            created.append(s)
        }
        shifts = (shifts + created).sorted { $0.start < $1.start }
        importing = false
        let minutes = created.reduce(0) { $0 + $1.paidMinutes }
        if let e = calendarError { status = .err("Pas ajouté au Calendrier : \(e)") }
        ToastCenter.shared.show(calendarError.map { "Shifts ajoutés, mais pas au Calendrier : \($0)" }
            ?? "\(created.count) shift\(created.count > 1 ? "s" : "") ajouté\(created.count > 1 ? "s" : "") (\(Self.hours(minutes))) ✓", cheer: calendarError == nil)
    }

    // MARK: Calendrier

    var calendars: [EKCalendar] { events.calendars(for: .event).filter { $0.allowsContentModifications } }

    private func ensureAccess() throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        var ok = HomeStore.hasAccess
        if #available(macOS 14.0, *) { ok = ok || status == .writeOnly }
        guard ok else {
            requestAccess()
            throw MathError(message: "autorise l'accès au Calendrier (Réglages Système → Confidentialité → Calendriers) puis réessaie")
        }
    }

    func requestAccess() {
        if #available(macOS 14.0, *) {
            events.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { self.accessChanged(ok) } }
        } else {
            events.requestAccess(to: .event) { ok, _ in DispatchQueue.main.async { self.accessChanged(ok) } }
        }
    }

    /// Accès accordé : le magasin d'événements ouvert avant l'autorisation ne voit encore aucun calendrier.
    private func accessChanged(_ granted: Bool) {
        events.reset()
        refreshConflicts()
        objectWillChange.send()
        if granted, addToCalendar, !missingInCalendar.isEmpty { syncCalendar() }
    }

    private func targetCalendar() -> EKCalendar? {
        calendars.first { $0.calendarIdentifier == calendarID } ?? events.defaultCalendarForNewEvents ?? calendars.first
    }

    /// Shifts à venir qui n'ont pas (ou plus) leur événement dans Calendrier.
    var missingInCalendar: [WorkShift] {
        guard addToCalendar else { return [] }
        return shifts.filter { $0.end > Date() && $0.eventID.flatMap { events.event(withIdentifier: $0) } == nil }
    }

    func syncCalendar(all: Bool = false) {
        do { try ensureAccess() } catch { status = .err("Calendrier : \(error.localizedDescription)"); return }
        events.refreshSourcesIfNecessary()
        var done = 0
        var lastError: String?
        for i in shifts.indices where shifts[i].end > Date() {
            let existing = shifts[i].eventID.flatMap { events.event(withIdentifier: $0) }
            guard all || existing == nil else { continue }
            do {
                shifts[i].eventID = try writeEvent(for: shifts[i], existing: existing?.eventIdentifier)
                done += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        objectWillChange.send()
        if let e = lastError {
            status = .err("Calendrier : \(e)")
        } else {
            status = .ok("\(done) shift\(done > 1 ? "s" : "") dans Calendrier ✓")
            ToastCenter.shared.show("Planning synchronisé avec Calendrier ✓", cheer: true)
        }
    }

    /// Calendrier rien que pour le travail (jaune), pour l'afficher ou le masquer d'un clic dans Calendrier.
    func createWorkCalendar() {
        do {
            try ensureAccess()
            if let existing = workCalendar {
                movingCalendar = true
                calendarID = existing.calendarIdentifier
                movingCalendar = false
            } else {
                let source = events.defaultCalendarForNewEvents?.source
                    ?? events.sources.first { $0.sourceType == .calDAV }
                    ?? events.sources.first { $0.sourceType == .local }
                guard let src = source else { throw MathError(message: "aucun compte de calendrier trouvé") }
                let cal = EKCalendar(for: .event, eventStore: events)
                cal.title = eventTitleCalendarName
                cal.cgColor = NSColor.systemYellow.cgColor
                cal.source = src
                try events.saveCalendar(cal, commit: true)
                movingCalendar = true
                calendarID = cal.calendarIdentifier
                movingCalendar = false
            }
            syncCalendar(all: true)
        } catch {
            status = .err("Calendrier : \(error.localizedDescription)")
        }
    }

    var eventTitleCalendarName: String { "McDo" }

    /// Un calendrier déjà créé pour le travail : « Macdo », « McDo », « McDonald's », « Travail »…
    var workCalendar: EKCalendar? {
        calendars.first { c in
            let t = CourseLibrary.fold(c.title).filter { $0.isLetter }
            return t.hasPrefix("macdo") || t.hasPrefix("mcdo") || t == "travail" || t == "boulot" || t == "taf"
        }
    }

    /// Au lancement : si aucun calendrier n'a été choisi et qu'un calendrier « travail » existe, on le prend.
    func adoptWorkCalendar() {
        guard calendarID.isEmpty, HomeStore.hasAccess, let c = workCalendar else { return }
        calendarID = c.calendarIdentifier
    }

    private func writeEvent(for s: WorkShift, existing: String? = nil) throws -> String? {
        try ensureAccess()
        events.refreshSourcesIfNecessary()
        let ev = existing.flatMap { events.event(withIdentifier: $0) } ?? EKEvent(eventStore: events)
        ev.title = eventTitle
        ev.startDate = s.start
        ev.endDate = s.end
        let pauseLine = s.pauses.isEmpty ? (s.breakMinutes > 0 ? "Pause : \(s.breakMinutes) min\n" : "")
            : "Pauses : \(s.pausesText) (\(Self.hours(s.breakMinutes)))\n"
        ev.notes = pauseLine + "Payé : \(Self.hours(s.paidMinutes))\nAjouté par Toolbox"
        var target = targetCalendar()
        if target == nil {
            events.reset()
            target = targetCalendar()
        }
        guard let cal = target else {
            throw MathError(message: "aucun calendrier modifiable trouvé (ouvre l'app Calendrier une fois, puis « Ajouter au Calendrier »)")
        }
        ev.calendar = cal
        ev.alarms = alarmMinutes > 0 ? [EKAlarm(relativeOffset: -Double(alarmMinutes * 60))] : nil
        try events.save(ev, span: .thisEvent)
        return ev.eventIdentifier
    }

    func remove(_ s: WorkShift) {
        if let id = s.eventID, let ev = events.event(withIdentifier: id) { try? events.remove(ev, span: .thisEvent) }
        withAnimation { shifts.removeAll { $0.id == s.id } }
    }

    func saveEdited(_ s: WorkShift) {
        var s = s
        if s.end <= s.start { s.end = s.end.addingTimeInterval(86400) }
        if addToCalendar || s.eventID != nil {
            do { s.eventID = try writeEvent(for: s, existing: s.eventID) } catch { ToastCenter.shared.show("Calendrier : \(error.localizedDescription)") }
        }
        if let i = shifts.firstIndex(where: { $0.id == s.id }) { shifts[i] = s } else { shifts.append(s) }
        shifts.sort { $0.start < $1.start }
        editing = nil
    }

    func newShift() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let start = cal.date(byAdding: .hour, value: 11, to: tomorrow) ?? tomorrow
        editing = WorkShift(start: start, end: start.addingTimeInterval(4 * 3600), breakMinutes: 0)
    }

    // MARK: Chevauchements (cours, CC…)

    func conflict(start: Date, end: Date, ignoring: String?) -> String? {
        let ours = Set(shifts.compactMap { $0.eventID })
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        if HomeStore.hasAccess {
            let dayStart = Calendar.current.startOfDay(for: start)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let evs = events.events(matching: events.predicateForEvents(withStart: dayStart, end: max(end, dayEnd), calendars: nil))
                .filter { $0.eventIdentifier != ignoring && !ours.contains($0.eventIdentifier ?? "") }
            let isExam: (EKEvent) -> Bool = { ($0.title ?? "").range(of: ExamsStore.pattern, options: .regularExpression) != nil }
            if let e = evs.first(where: { isExam($0) && ($0.isAllDay || Calendar.current.isDate($0.startDate, inSameDayAs: start)) }) {
                return "⚠️ \(e.title ?? "Examen") ce jour-là" + (e.isAllDay ? "" : " (\(tf.string(from: e.startDate)))")
            }
            if let e = evs.first(where: { !$0.isAllDay && $0.startDate < end && $0.endDate > start }) {
                return "Chevauche « \(e.title ?? "événement") » (\(tf.string(from: e.startDate))–\(tf.string(from: e.endDate)))"
            }
        }
        if let data = UserDefaults.standard.data(forKey: "home.exams"),
           let list = try? JSONDecoder().decode([Countdown].self, from: data),
           let c = list.first(where: { Calendar.current.isDate($0.date, inSameDayAs: start) }) {
            return "⚠️ \(c.title) ce jour-là"
        }
        return nil
    }

    func refreshConflicts() {
        let now = Date()
        var map: [UUID: String] = [:]
        for s in shifts where s.end > now {
            if let c = conflict(start: s.start, end: s.end, ignoring: s.eventID) { map[s.id] = c }
        }
        conflicts = map
        PhoneWidget.export(self)
    }

    // MARK: Heures

    static func hours(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", m))"
    }

    func weekInterval(_ offset: Int) -> DateInterval {
        let start = Calendar.current.date(byAdding: .day, value: 7 * offset, to: ShiftParser.monday(of: Date())) ?? Date()
        return DateInterval(start: start, duration: 7 * 86400)
    }

    func shifts(in interval: DateInterval) -> [WorkShift] {
        shifts.filter { $0.start >= interval.start && $0.start < interval.end }
    }

    func minutes(in interval: DateInterval) -> Int {
        shifts(in: interval).reduce(0) { $0 + $1.paidMinutes }
    }

    var monthInterval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: Date()) ?? DateInterval(start: Date(), duration: 30 * 86400)
    }

    var next: WorkShift? { shifts.first { $0.end > Date() } }

    func monthRecap() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateFormat = "EEE d MMM"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let mf = DateFormatter()
        mf.locale = Locale(identifier: "fr_FR")
        mf.dateFormat = "LLLL yyyy"
        let list = shifts(in: monthInterval)
        var lines = ["Heures de \(mf.string(from: Date()))", ""]
        for s in list {
            lines.append("\(df.string(from: s.start)) · \(tf.string(from: s.start))–\(tf.string(from: s.end)) · \(Self.hours(s.paidMinutes))"
                         + (s.pauses.isEmpty ? (s.breakMinutes > 0 ? " (pause \(s.breakMinutes) min)" : "") : " (pauses \(s.pausesText))"))
        }
        lines += ["", "Total : \(Self.hours(list.reduce(0) { $0 + $1.paidMinutes })) sur \(list.count) shift\(list.count > 1 ? "s" : "")"]
        return lines.joined(separator: "\n")
    }
}

// MARK: - Vue

struct PlanningToolView: View {
    @ObservedObject var p: PlanningStore
    @StateObject private var drop = HoverFlag()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d"
        return f
    }()
    private static let longFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMMM"
        return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(tool: .planning)
            actions
            stats
            calendarBanner
            week
            upcoming
            StatusBanner(message: p.status)
        }
        .padding(20)
        .fileDrop(types: [.image, .pdf], isTargeted: Binding(get: { drop.on }, set: { drop.on = $0 })) { urls in
            p.importFile(urls[0])
        }
        .overlay {
            if drop.on {
                RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .overlay(Text("Dépose la photo ou le PDF du planning").font(.title3.bold()).foregroundStyle(Color.accentColor))
            }
        }
        .sheet(isPresented: $p.importing) { ImportShiftsSheet(p: p) }
        .sheet(item: $p.editing) { s in ShiftEditSheet(p: p, shift: s) }
    }

    @ViewBuilder
    private var calendarBanner: some View {
        let missing = p.missingInCalendar
        if !missing.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark").font(.title3).foregroundStyle(Color.orange)
                Text("\(missing.count) shift\(missing.count > 1 ? "s" : "") à venir pas encore dans Calendrier")
                Spacer()
                Button("Ajouter au Calendrier") { p.syncCalendar() }.buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Choisir une photo ou un PDF…") {
                    if let u = Panels.open([.image, .pdf]).first { p.importFile(u) }
                }
                Button("Capturer une zone de l'écran") { p.captureScreen() }
                Button("Coller (image ou texte)") { p.importPasteboard() }
                Button("Taper le planning à la main") { p.typeText() }
            } label: {
                Label("Importer le planning", systemImage: "camera.viewfinder")
            } primaryAction: {
                if let u = Panels.open([.image, .pdf]).first { p.importFile(u) }
            }
            .fixedSize()
            Button { p.newShift() } label: { Label("Ajouter un shift", systemImage: "plus") }
            Spacer()
            Button { p.copyRecap() } label: { Label("Récap du mois", systemImage: "doc.on.clipboard") }
                .help("Copie la liste des heures du mois (pour vérifier ta fiche de paie)")
            Button { p.showSettings.toggle() } label: { Label("Réglages", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $p.showSettings) { PlanningSettings(p: p).padding(16).frame(width: 380) }
        }
    }

    private var stats: some View {
        let weekMin = p.minutes(in: p.weekInterval(0))
        let monthMin = p.minutes(in: p.monthInterval)
        let contract = GradeCalc.num(p.contractHours)
        return HStack(spacing: 12) {
            tile("Cette semaine", PlanningStore.hours(weekMin),
                 contract.map { c -> String in
                     let diff = Double(weekMin) / 60 - c
                     return diff > 0.01 ? "+\(GradeCalc.fmt(diff)) h au-delà du contrat (\(GradeCalc.fmt(c)) h)" : "sur \(GradeCalc.fmt(c)) h de contrat"
                 } ?? "", color: .orange)
            tile("Ce mois-ci", PlanningStore.hours(monthMin), "\(p.shifts(in: p.monthInterval).count) shifts", color: .red)
            if let n = p.next {
                let now = Date()
                tile(n.start <= now ? "En service" : "Prochain shift",
                     "\(Self.dayFormat.string(from: n.start).capitalized) · \(Self.time.string(from: n.start))–\(Self.time.string(from: n.end))",
                     n.start <= now ? "jusqu'à \(Self.time.string(from: n.end))" : Self.relative(n.start), color: .yellow)
            }
        }
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func tile(_ title: String, _ value: String, _ footer: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(footer).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)))
    }

    private var week: some View {
        let interval = p.weekInterval(p.weekOffset)
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { withAnimation { p.weekOffset -= 1 } } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text("Semaine du \(Self.longFormat.string(from: interval.start))").font(.headline)
                Button { withAnimation { p.weekOffset += 1 } } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                if p.weekOffset != 0 { Button("Aujourd'hui") { withAnimation { p.weekOffset = 0 } }.controlSize(.small) }
                Spacer()
                Text(PlanningStore.hours(p.minutes(in: interval))).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    let day = cal.date(byAdding: .day, value: i, to: interval.start) ?? interval.start
                    let list = p.shifts.filter { cal.isDate($0.start, inSameDayAs: day) }
                    let today = cal.isDateInToday(day)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.dayFormat.string(from: day).capitalized)
                            .font(.caption.weight(today ? .bold : .medium))
                            .foregroundStyle(today ? Color.accentColor : Color.secondary)
                        if list.isEmpty {
                            Text("Repos").font(.caption2).foregroundStyle(.tertiary)
                        }
                        ForEach(list) { s in shiftChip(s) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(today ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035)))
                }
            }
        }
    }

    private func shiftChip(_ s: WorkShift) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Self.time.string(from: s.start))–\(Self.time.string(from: s.end))").font(.callout.weight(.semibold).monospacedDigit())
            Text(PlanningStore.hours(s.paidMinutes) + (s.pauses.isEmpty ? (s.breakMinutes > 0 ? " · pause \(s.breakMinutes)′" : "")
                                                        : " · \(s.pauses.count) pause\(s.pauses.count > 1 ? "s" : "")"))
                .help(s.pauses.isEmpty ? "" : "Pauses : \(s.pausesText)")
                .font(.caption2).foregroundStyle(.secondary)
            if let c = p.conflicts[s.id] {
                Text(c).font(.caption2).foregroundStyle(c.hasPrefix("⚠️") ? Color.red : Color.orange).lineLimit(3)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.conflicts[s.id] == nil ? Color.clear : Color.red.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { p.editing = s }
        .contextMenu {
            Button("Modifier") { p.editing = s }
            Button("Supprimer", role: .destructive) { p.remove(s) }
        }
    }

    private var upcoming: some View {
        let list = p.shifts.filter { $0.end > Date() && p.conflicts[$0.id] != nil }
        return Group {
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("À surveiller", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(Color.orange)
                    ForEach(list) { s in
                        HStack {
                            Text("\(Self.dayFormat.string(from: s.start).capitalized) \(Self.time.string(from: s.start))–\(Self.time.string(from: s.end))")
                                .font(.callout.monospacedDigit()).frame(width: 150, alignment: .leading)
                            Text(p.conflicts[s.id] ?? "").font(.callout)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
            }
        }
    }
}

extension PlanningStore {
    func copyRecap() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(monthRecap(), forType: .string)
        ToastCenter.shared.show("Récap du mois copié ✓")
    }
}

struct PlanningSettings: View {
    @ObservedObject var p: PlanningStore

    var body: some View {
        Form {
            TextField("Titre dans le Calendrier", text: $p.eventTitle)
            Toggle("Ajouter les shifts au Calendrier", isOn: $p.addToCalendar)
            if p.addToCalendar {
                Picker("Calendrier", selection: $p.calendarID) {
                    Text("Calendrier par défaut").tag("")
                    ForEach(p.calendars, id: \.calendarIdentifier) { c in Text(c.title).tag(c.calendarIdentifier) }
                }
                if let w = p.workCalendar {
                    if w.calendarIdentifier != p.calendarID {
                        Button("Utiliser mon calendrier « \(w.title) »") { p.calendarID = w.calendarIdentifier }
                    }
                } else {
                    Button("Créer un calendrier « McDo » rien que pour le travail") { p.createWorkCalendar() }
                }
                Picker("Rappel", selection: $p.alarmMinutes) {
                    Text("Aucun").tag(0)
                    Text("30 min avant").tag(30)
                    Text("1 h avant").tag(60)
                    Text("2 h avant").tag(120)
                }
            }
            HStack {
                Text("Pause non payée")
                TextField("0", value: $p.breakMinutes, format: .number).frame(width: 44)
                Text("min si le shift dure au moins")
                TextField("6", value: $p.breakAfterHours, format: .number).frame(width: 36)
                Text("h")
            }
            HStack {
                Text("Heures du contrat par semaine")
                TextField("ex. 24", text: $p.contractHours).frame(width: 60)
            }
            Text("Les heures affichées sont les heures de présence moins la pause : compare-les avec ta fiche de paie.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}

struct ImportShiftsSheet: View {
    @ObservedObject var p: PlanningStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Importer le planning").font(.title2.bold())
                Spacer()
                if p.reading { ProgressView().controlSize(.small); Text("Lecture…").foregroundStyle(.secondary) }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let img = p.image {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text("Texte lu (corrige-le si besoin) :").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $p.ocrText)
                        .font(.callout.monospaced())
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                    Button("Relire le texte") { p.rereadText() }.disabled(p.ocrText.isEmpty)
                    StatusBanner(message: p.status)
                }
                .frame(width: 300)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Seulement la ligne de", isOn: $p.filterByName).toggleStyle(.checkbox)
                        TextField("Prénom", text: $p.nameOnPlanning).textFieldStyle(.roundedBorder).frame(width: 110)
                            .onSubmit { p.reparse() }
                        if p.filterByName, !p.tokens.isEmpty {
                            Text(p.nameFound ? "trouvé ✓" : "pas trouvé : tout est gardé")
                                .font(.caption).foregroundStyle(p.nameFound ? Color.green : Color.orange)
                        }
                    }
                    Toggle("Un seul shift par jour : les trous entre les créneaux sont des pauses", isOn: $p.mergeDays)
                        .toggleStyle(.checkbox)
                    HStack {
                        Text("Semaine du")
                        DatePicker("", selection: Binding(get: { p.weekStart }, set: { p.setWeek($0) }), displayedComponents: .date)
                            .labelsHidden()
                        Text("(pour les jours écrits sans date)").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    if p.drafts.isEmpty && !p.reading {
                        Text(p.tokens.isEmpty ? "Rien de lu pour l'instant." : "Aucun créneau reconnu. Corrige le texte à gauche (ex. « Lundi 4 nov 9h-14h ») puis « Relire ».")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach($p.drafts) { $d in DraftRow(d: $d) }
                        }
                    }
                    .frame(minHeight: 220)
                }
            }
            Divider()
            HStack {
                let chosen = p.drafts.filter { $0.include }
                Text("\(chosen.count) shift\(chosen.count > 1 ? "s" : "") · \(PlanningStore.hours(chosen.reduce(0) { $0 + $1.paidMinutes }))")
                    .font(.headline)
                Toggle("Ajouter au Calendrier", isOn: $p.addToCalendar).toggleStyle(.checkbox)
                Spacer()
                Button("Annuler") { p.importing = false }.keyboardShortcut(.cancelAction)
                Button("Ajouter") { p.confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 900, height: 600)
    }
}

struct DraftRow: View {
    @Binding var d: ShiftDraft

    private func time(_ keyPath: WritableKeyPath<ShiftDraft, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(byAdding: .minute, value: d[keyPath: keyPath] % 1440, to: Calendar.current.startOfDay(for: d.day)) ?? d.day
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            var m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if keyPath == \ShiftDraft.endMin, m <= d.startMin { m += 1440 }
            d[keyPath: keyPath] = m
            if keyPath == \ShiftDraft.startMin, d.endMin <= m { d.endMin += 1440 }
            if d.endMin - d.startMin > 1440 { d.endMin -= 1440 }
            d.gaps.removeAll { $0.startMin < d.startMin || $0.endMin > d.endMin }
        })
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $d.include).labelsHidden()
            DatePicker("", selection: $d.day, displayedComponents: .date).labelsHidden().frame(width: 120)
            DatePicker("", selection: time(\.startMin), displayedComponents: .hourAndMinute).labelsHidden()
            Text("→")
            DatePicker("", selection: time(\.endMin), displayedComponents: .hourAndMinute).labelsHidden()
            if d.gaps.isEmpty {
                Text("pause").font(.caption).foregroundStyle(.secondary)
                TextField("0", value: $d.breakMinutes, format: .number).frame(width: 36)
            } else {
                Text("pauses \(PlanningStore.hours(d.gapMinutes))").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .leading)
            }
            Text(PlanningStore.hours(d.paidMinutes)).font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                if d.gaps.isEmpty {
                    Text(d.source).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                } else {
                    Text("pauses \(d.gapsText)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let w = d.warning {
                    Text(w).font(.caption2).foregroundStyle(w.hasPrefix("⚠️") || w.hasPrefix("Déjà") ? Color.red : Color.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(d.include ? Color.yellow.opacity(0.12) : Color.primary.opacity(0.03)))
        .opacity(d.include ? 1 : 0.6)
    }
}

struct ShiftEditSheet: View {
    @ObservedObject var p: PlanningStore
    @StateObject private var model: Holder

    final class Holder: ObservableObject {
        @Published var shift: WorkShift
        init(_ s: WorkShift) { shift = s }
    }

    init(p: PlanningStore, shift: WorkShift) {
        self.p = p
        _model = StateObject(wrappedValue: Holder(shift))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(p.shifts.contains { $0.id == model.shift.id } ? "Modifier le shift" : "Nouveau shift").font(.title2.bold())
            Form {
                DatePicker("Début", selection: $model.shift.start)
                DatePicker("Fin", selection: $model.shift.end)
                HStack {
                    Text("Pause non payée")
                    TextField("0", value: $model.shift.breakMinutes, format: .number).frame(width: 50)
                    Text("min")
                }
                if !model.shift.pauses.isEmpty {
                    Text("Pauses : \(model.shift.pausesText)").foregroundStyle(.secondary)
                }
                TextField("Note", text: $model.shift.note)
                Text("Payé : \(PlanningStore.hours(model.shift.paidMinutes))").foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                if p.shifts.contains(where: { $0.id == model.shift.id }) {
                    Button("Supprimer", role: .destructive) { p.remove(model.shift); p.editing = nil }
                }
                Spacer()
                Button("Annuler") { p.editing = nil }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { p.saveEdited(model.shift) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Widget d'accueil

struct PlanningWidget: View {
    @ObservedObject var p = PlanningStore.shared
    let open: () -> Void

    var body: some View {
        Card(title: "Planning", icon: "fork.knife", tint: .yellow,
             accessory: AnyView(Button("Ouvrir", action: open).buttonStyle(.borderless))) {
            let weekMin = p.minutes(in: p.weekInterval(0))
            let contract = GradeCalc.num(p.contractHours)
            if let n = p.next {
                let now = Date()
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.start <= now ? "En service jusqu'à \(PlanningToolView.time.string(from: n.end))" : "Prochain shift")
                        .font(.caption).foregroundStyle(.secondary)
                    if n.start > now {
                        Text("\(PlanningToolView.relative(n.start).capitalized) · \(PlanningToolView.time.string(from: n.start))–\(PlanningToolView.time.string(from: n.end))")
                            .font(.callout.weight(.semibold))
                    }
                    if let c = p.conflicts[n.id] { Text(c).font(.caption).foregroundStyle(Color.red) }
                }
            } else {
                Text("Aucun shift prévu. Importe une photo du planning.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Cette semaine").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(PlanningStore.hours(weekMin) + (contract.map { " / \(GradeCalc.fmt($0)) h" } ?? ""))
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            if let c = contract, c > 0 {
                ProgressView(value: min(1, Double(weekMin) / 60 / c)).tint(.yellow)
            }
            let n = p.conflicts.count
            if n > 1 {
                Label("\(n) shifts tombent sur des cours ou des CC", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.orange)
            }
        }
    }
}

// MARK: - Widget « Prochain shift »

struct NextShiftWidget: View {
    @ObservedObject var p = PlanningStore.shared
    let open: () -> Void

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Aujourd'hui" }
        if cal.isDateInTomorrow(d) { return "Demain" }
        return Self.day.string(from: d).capitalized
    }

    private func countdown(to d: Date, now: Date) -> String {
        let m = max(0, Int(d.timeIntervalSince(now) / 60))
        if m < 60 { return "dans \(m) min" }
        if m < 24 * 60 { return "dans \(m / 60) h \(String(format: "%02d", m % 60))" }
        return PlanningToolView.relative(d)
    }

    var body: some View {
        Card(title: "Prochain shift", icon: "fork.knife", tint: .yellow,
             accessory: AnyView(Button("Planning", action: open).buttonStyle(.borderless))) {
            TimelineView(.periodic(from: Date(), by: 300)) { context in
                let now = context.date
                if let s = p.shifts.first(where: { $0.end > now }) {
                    let working = s.start <= now
                    VStack(alignment: .leading, spacing: 6) {
                        Text(working ? "En service" : dayLabel(s.start))
                            .font(.callout.weight(.semibold)).foregroundStyle(working ? Color.green : Color.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(PlanningToolView.time.string(from: s.start)) → \(PlanningToolView.time.string(from: s.end))")
                                .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                            Text(working ? "fin " + countdown(to: s.end, now: now) : countdown(to: s.start, now: now))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if working {
                            let total = s.end.timeIntervalSince(s.start)
                            ProgressView(value: min(1, max(0, now.timeIntervalSince(s.start) / max(total, 1)))).tint(.yellow)
                            if let pause = s.pauses.first(where: { $0.end > now }) {
                                Text(pause.start <= now ? "En pause jusqu'à \(PlanningToolView.time.string(from: pause.end)) ☕"
                                     : "Prochaine pause à \(PlanningToolView.time.string(from: pause.start)) (\(countdown(to: pause.start, now: now)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 6) {
                            Text("\(PlanningStore.hours(s.paidMinutes)) payées")
                            if !s.pauses.isEmpty { Text("· pauses \(s.pausesText)") }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let c = p.conflicts[s.id] {
                            Label(c, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.red)
                        }
                        if let after = p.shifts.first(where: { $0.start > s.end }) {
                            Text("Ensuite : \(dayLabel(after.start).lowercased()), \(PlanningToolView.time.string(from: after.start))–\(PlanningToolView.time.string(from: after.end))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("Aucun shift prévu 🎉 Importe ton planning pour le voir ici.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}


