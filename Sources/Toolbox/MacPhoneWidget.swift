import Foundation
import EventKit

// MARK: - État du Mac → iPhone (ToolboxMac.json dans iCloud)

extension PhoneWidget {
    static let macFileName = "ToolboxMac.json"
    static let macScriptName = "Mon Mac.js"

    private static var lastMacExport = Date.distantPast
    private static var lastMacKey = ""
    static let macName: String = Host.current().localizedName ?? "Mac"

    /// Appelé à chaque relevé. iCloud n'aime pas un fichier réécrit sans arrêt (il freine toute la synchro) :
    /// on n'écrit que si la batterie change (%, branché, en charge), sinon au plus toutes les 10 minutes.
    static func exportMac(_ m: MacStatusStore, force: Bool = false) {
        guard enabled else { return }
        let now = Date()
        let b = m.battery
        let key = "\(b?.percent ?? -1)|\(b?.plugged ?? true)|\(b?.charging ?? false)|\(m.thermal == .serious || m.thermal == .critical)"
        guard force || key != lastMacKey || now.timeIntervalSince(lastMacExport) >= 600 else { return }
        lastMacExport = now
        lastMacKey = key
        let iso = ISO8601DateFormatter()
        var root: [String: Any] = [
            "updated": iso.string(from: now),
            "name": macName,
            "cpu": (m.cpu * 100).rounded(),
            "memoryUsed": m.memoryUsed,
            "memoryTotal": m.memoryTotal,
            "diskFree": m.diskFree,
            "diskTotal": m.diskTotal,
            "lowPower": m.lowPower,
            "hot": m.thermal == .serious || m.thermal == .critical,
        ]
        if let b = m.battery {
            var bat: [String: Any] = ["percent": b.percent, "charging": b.charging, "plugged": b.plugged, "charged": b.charged]
            if let left = b.minutesLeft { bat["minutesLeft"] = left }
            root["battery"] = bat
        }
        var health: [String: Any] = [:]
        if let h = m.health.percent { health["percent"] = h }
        if let c = m.health.cycles { health["cycles"] = c }
        if let t = m.health.temperature { health["temperature"] = (t * 10).rounded() / 10 }
        if !health.isEmpty { root["health"] = health }
        if let boot = m.bootDate { root["boot"] = iso.string(from: boot) }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return }
        let dir = targetDir
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(macFileName), options: .atomic)
        }
    }

    static func installMacScript() throws {
        try macScript.data(using: .utf8)?.write(to: scriptableDir.appendingPathComponent(macScriptName), options: .atomic)
    }

    static let macScript = ##"""
// Variables used by Scriptable.
// These must be at the very top of the file. Do not edit.
// icon-color: deep-blue; icon-glyph: laptop;

// Mon Mac — widget de Toolbox : batterie et état du Mac, envoyés par Toolbox via iCloud chaque minute.
// Petit, moyen, et écran verrouillé (cercle, rectangle, ligne).

const FILE = "ToolboxMac.json"
const GREEN = new Color("#32D74B"), ORANGE = new Color("#FF9F0A"), RED = new Color("#FF453A")
const CYAN = new Color("#64D2FF"), GRAY = new Color("#9A9AA0"), DIM = new Color("#6E6E73")

async function load() {
  // 1) le signet « Toolbox » (dossier iCloud Drive/Toolbox, synchronisé en priorité) ; 2) le dossier de Scriptable
  const fm = FileManager.iCloud()
  const paths = []
  try { paths.push(fm.joinPath(fm.bookmarkedPath("Toolbox"), FILE)) } catch (e) {}
  paths.push(fm.joinPath(fm.documentsDirectory(), FILE))
  for (const path of paths) {
    if (!fm.fileExists(path)) continue
    try {
      await fm.downloadFileFromiCloud(path)
      return JSON.parse(fm.readString(path))
    } catch (e) {}
  }
  return null
}

const pad = n => String(n).padStart(2, "0")
const dur = m => m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${pad(m % 60)}`
const go = b => { const g = b / 1e9; return g >= 100 ? `${Math.round(g)} Go` : `${(Math.round(g * 10) / 10).toString().replace(".", ",")} Go` }

const data = await load()
const now = new Date()
const b = data && data.battery
const age = data ? Math.max(0, Math.round((now - new Date(data.updated)) / 60000)) : null
const stale = age !== null && age > 10
const family = config.widgetFamily || "medium"

function color(p, plugged) { return plugged ? GREEN : (p <= 10 ? RED : (p <= 20 ? ORANGE : GREEN)) }

function stateLine() {
  if (!data) return "Ouvre Toolbox sur le Mac"
  if (!b) return "Branché sur secteur"
  if (b.charged || (b.plugged && b.percent >= 100)) return "Branché · chargé"
  if (b.charging) return b.minutesLeft ? `En charge · plein dans ${dur(b.minutesLeft)}` : "En charge"
  if (b.plugged) return "Branché · charge en pause"
  return b.minutesLeft ? `${dur(b.minutesLeft)} restantes` : "Sur batterie"
}

function ageLine() {
  if (age === null) return ""
  if (stale) return `Mac en veille ? · vu il y a ${age >= 60 ? dur(age) : age + " min"}`
  return age <= 1 ? "à l'instant" : `il y a ${age} min`
}

// pile dessinée
function batteryImage(p, plugged, charging, w = 64, h = 30, tint = null) {
  const d = new DrawContext()
  d.size = new Size(w + 6, h)
  d.opaque = false
  d.respectScreenScale = true
  const frame = tint || new Color("#FFFFFF", 0.55)
  const body = new Path()
  body.addRoundedRect(new Rect(1, 1, w - 2, h - 2), h * 0.25, h * 0.25)
  d.addPath(body); d.setStrokeColor(frame); d.setLineWidth(2); d.strokePath()
  const fillW = Math.max(3, (w - 8) * Math.min(100, Math.max(0, p)) / 100)
  const fill = new Path()
  fill.addRoundedRect(new Rect(4, 4, fillW, h - 8), h * 0.15, h * 0.15)
  d.addPath(fill); d.setFillColor(tint || color(p, plugged)); d.fillPath()
  const cap = new Path()
  cap.addRoundedRect(new Rect(w + 1, h * 0.3, 4, h * 0.4), 1.5, 1.5)
  d.addPath(cap); d.setFillColor(frame); d.fillPath()
  if (charging) {
    const bolt = SFSymbol.named("bolt.fill").image
    d.drawImageInRect(bolt, new Rect(w / 2 - h * 0.3, h * 0.2, h * 0.6, h * 0.6))
  }
  return d.getImage()
}

function text(stack, s, font, col, lines = 1) {
  const t = stack.addText(s); t.font = font; t.textColor = col; t.lineLimit = lines; t.minimumScaleFactor = 0.6; return t
}

const w = new ListWidget()
w.refreshAfterDate = new Date(now.getTime() + 5 * 60000)

if (family === "accessoryInline") {
  w.addText(b ? `💻 ${b.percent} %${b.charging ? " ⚡" : (b.minutesLeft ? " · " + dur(b.minutesLeft) : "")}` : "💻 Mac branché")
} else if (family === "accessoryCircular") {
  const s = w.addStack(); s.layoutVertically(); s.centerAlignContent()
  if (b) {
    const img = s.addImage(batteryImage(b.percent, b.plugged, b.charging, 30, 15, Color.white()))
    img.imageSize = new Size(32, 15)
    text(s, `${b.percent}%`, Font.boldRoundedSystemFont(16), Color.white())
  } else {
    text(s, "💻", Font.systemFont(20), Color.white())
  }
} else if (family === "accessoryRectangular") {
  text(w, `💻 ${data ? data.name : "Mon Mac"}`, Font.semiboldSystemFont(12), Color.white())
  text(w, b ? `${b.percent} %${b.charging ? " ⚡" : ""}` : "Secteur", Font.boldRoundedSystemFont(20), Color.white())
  text(w, stale ? ageLine() : stateLine(), Font.systemFont(11), Color.white())
} else {
  const g = new LinearGradient()
  g.colors = [new Color("#1F2A33"), new Color("#15181C")]
  g.locations = [0, 1]
  w.backgroundGradient = g
  w.setPadding(14, 14, 12, 14)
  const small = family === "small"

  const head = w.addStack(); head.centerAlignContent()
  const icon = head.addImage(SFSymbol.named("laptopcomputer").image)
  icon.imageSize = new Size(16, 13); icon.tintColor = CYAN
  head.addSpacer(5)
  text(head, data ? data.name : "Mon Mac", Font.boldSystemFont(13), CYAN)
  head.addSpacer()
  if (!small) text(head, ageLine(), Font.systemFont(10), stale ? ORANGE : DIM)
  w.addSpacer(small ? 8 : 10)

  if (!data) {
    text(w, "Pas de données : dans Scriptable, Réglages → Signets de fichiers → + → dossier iCloud Drive/Toolbox, nommé « Toolbox ».", Font.systemFont(12), GRAY, 4)
  } else {
    const row = w.addStack(); row.centerAlignContent()
    const left = row.addStack(); left.layoutVertically()
    if (b) {
      const img = left.addImage(batteryImage(b.percent, b.plugged, b.charging))
      img.imageSize = new Size(small ? 52 : 64, small ? 24 : 30)
      left.addSpacer(4)
      text(left, `${b.percent} %`, Font.boldRoundedSystemFont(small ? 26 : 30), color(b.percent, b.plugged))
    } else {
      text(left, "Secteur", Font.boldRoundedSystemFont(22), Color.white())
    }
    text(left, stateLine(), Font.systemFont(11), GRAY, 2)
    if (small) {
      if (stale) text(left, ageLine(), Font.systemFont(10), ORANGE, 2)
    } else {
      row.addSpacer()
      const right = row.addStack(); right.layoutVertically()
      const line = (sym, s, col = Color.white()) => {
        const l = right.addStack(); l.centerAlignContent()
        const i = l.addImage(SFSymbol.named(sym).image); i.imageSize = new Size(11, 11); i.tintColor = GRAY
        l.addSpacer(5)
        text(l, s, Font.mediumSystemFont(11), col)
        right.addSpacer(4)
      }
      line("cpu", `Processeur ${data.cpu} %`, data.cpu > 85 ? RED : Color.white())
      line("memorychip", `Mémoire ${go(data.memoryUsed)} / ${go(data.memoryTotal)}`)
      line("internaldrive", `${go(data.diskFree)} libres`, data.diskTotal && data.diskFree / data.diskTotal < 0.1 ? ORANGE : Color.white())
      if (data.health && data.health.percent) {
        line("heart.fill", `Santé ${data.health.percent} %${data.health.cycles ? " · " + data.health.cycles + " cycles" : ""}`)
      }
      if (data.hot) line("thermometer.sun.fill", "Le Mac chauffe", RED)
    }
  }
  w.addSpacer()
}

Script.setWidget(w)
if (!config.runsInWidget) await w.presentMedium()
Script.complete()
"""##
}

// MARK: - Alerte sur l'iPhone : un rappel « Recharge ton Mac » (synchronisé par iCloud)

enum BatteryReminder {
    static let store = EKEventStore()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "mac.reminder") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mac.reminder") }
    }

    static var threshold: Int {
        get { UserDefaults.standard.object(forKey: "mac.reminder.threshold") as? Int ?? 20 }
        set { UserDefaults.standard.set(newValue, forKey: "mac.reminder.threshold") }
    }

    private static var lastID: String? {
        get { UserDefaults.standard.string(forKey: "mac.reminder.id") }
        set { UserDefaults.standard.set(newValue, forKey: "mac.reminder.id") }
    }

    /// 3 = .fullAccess (macOS 14+) / .authorized (avant)
    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder).rawValue == 3 }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        // le magasin ouvert avant l'autorisation ne voit aucune liste : on le recharge
        let finish: (Bool, Error?) -> Void = { ok, _ in DispatchQueue.main.async { store.reset(); done(ok) } }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders(completion: finish)
        } else {
            store.requestAccess(to: .reminder, completion: finish)
        }
    }

    /// Crée (ou remplace) le rappel, avec une alarme 2 minutes plus tard pour laisser iCloud le livrer à l'iPhone.
    /// Renvoie un message d'erreur, ou nil si tout va bien.
    @discardableResult
    static func post(_ percent: Int, minutesLeft: Int?, retry: Bool = true) -> String? {
        guard enabled else { return "alerte désactivée" }
        guard hasAccess else {
            if retry, EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                requestAccess { ok in if ok { post(percent, minutesLeft: minutesLeft, retry: false) } }
            }
            return "pas d'accès aux Rappels (Réglages Système → Confidentialité et sécurité → Rappels)"
        }
        clear()
        store.refreshSourcesIfNecessary()
        var target = store.defaultCalendarForNewReminders() ?? store.calendars(for: .reminder).first { $0.allowsContentModifications }
        if target == nil {
            store.reset()
            target = store.defaultCalendarForNewReminders() ?? store.calendars(for: .reminder).first { $0.allowsContentModifications }
        }
        guard let list = target else { return "aucune liste de rappels trouvée (ouvre l'app Rappels une fois)" }
        let r = EKReminder(eventStore: store)
        r.title = "🔋 Recharge ton Mac (\(percent) %)"
        r.notes = (minutesLeft.map { "Environ \(MacStatusStore.duration($0)) d'autonomie. " } ?? "") + "Envoyé par Toolbox, disparaît tout seul quand le Mac est branché."
        r.calendar = list
        let when = Date().addingTimeInterval(120)
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
        r.addAlarm(EKAlarm(absoluteDate: when))
        r.priority = 1
        do {
            try store.save(r, commit: true)
            lastID = r.calendarItemIdentifier
            return nil
        } catch {
            NSLog("Toolbox rappel batterie : \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Mac branché : le rappel est coché tout seul.
    static func clear() {
        guard let id = lastID else { return }
        lastID = nil
        guard hasAccess, let r = store.calendarItem(withIdentifier: id) as? EKReminder, !r.isCompleted else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
    }
}
