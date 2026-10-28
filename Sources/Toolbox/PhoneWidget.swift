import Foundation
import AppKit

/// Widget iPhone : Toolbox écrit les prochains shifts dans iCloud Drive, un script Scriptable les affiche.
enum PhoneWidget {
    static let fileName = "Toolbox.json"
    static let scriptName = "Prochain shift.js"

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// Dossier iCloud de l'app Scriptable (présent sur le Mac dès que Scriptable utilise iCloud sur l'iPhone).
    static var scriptableDir: URL { home.appendingPathComponent("Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents") }
    /// Sinon : iCloud Drive/Toolbox (à relier dans Scriptable avec un signet de fichier nommé « Toolbox »).
    static var iCloudDriveDir: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Toolbox") }

    static var hasScriptable: Bool { FileManager.default.fileExists(atPath: scriptableDir.path) }
    /// Les données vont dans iCloud Drive/Toolbox : synchronisé en priorité, contrairement au dossier de Scriptable
    /// (traité « en arrière-plan » par macOS quand Scriptable n'est pas installé sur le Mac).
    static var targetDir: URL { iCloudDriveDir }

    /// Anciennes copies des données dans le dossier de Scriptable : retirées pour ne pas afficher de vieilles infos.
    private static var cleaned = false
    static func cleanOldCopies() {
        guard !cleaned else { return }
        cleaned = true
        publishScriptsAsText()
        for name in [fileName, "ToolboxMac.json"] {
            try? FileManager.default.removeItem(at: scriptableDir.appendingPathComponent(name))
        }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "phone.widget") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "phone.widget") }
    }

    static var lastExport: Date? {
        get { UserDefaults.standard.object(forKey: "phone.widget.last") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "phone.widget.last") }
    }

    private static let queue = DispatchQueue(label: "fr.arthur.toolbox.phonewidget")
    private static var lastPayload: Data?

    /// Shifts des 3 prochaines semaines (et celui en cours) → Toolbox.json.
    static func export(_ p: PlanningStore, force: Bool = false) {
        guard enabled else { return }
        let iso = ISO8601DateFormatter()
        let now = Date()
        let limit = now.addingTimeInterval(21 * 86400)
        let monday = ShiftParser.monday(of: now)
        let list: [[String: Any]] = p.shifts
            .filter { $0.end > monday && $0.start < limit }
            .map { s in
                var d: [String: Any] = [
                    "start": iso.string(from: s.start),
                    "end": iso.string(from: s.end),
                    "paidMinutes": s.paidMinutes,
                    "pauses": s.pauses.map { ["start": iso.string(from: $0.start), "end": iso.string(from: $0.end)] },
                ]
                if let c = p.conflicts[s.id] { d["conflict"] = c }
                if !s.note.isEmpty { d["note"] = s.note }
                return d
            }
        var root: [String: Any] = ["title": p.eventTitle, "shifts": list]
        if let c = GradeCalc.num(p.contractHours) { root["contractHours"] = c }
        // rien n'a changé : on ne touche pas au fichier (moins de travail pour iCloud)
        let payload = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard payload != lastPayload || force else { return }
        lastPayload = payload
        root["updated"] = iso.string(from: now)
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        let dir = targetDir
        queue.async {
            cleanOldCopies()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
                DispatchQueue.main.async { lastExport = Date() }
            } catch {
                NSLog("Toolbox widget iPhone : \(error.localizedDescription)")
            }
        }
    }

    /// Dépose le script directement dans Scriptable (il apparaît tout seul sur l'iPhone).
    static func installScript() throws {
        try script.data(using: .utf8)?.write(to: scriptableDir.appendingPathComponent(scriptName), options: .atomic)
        try installMacScript()
        exportMac(MacStatusStore.shared, force: true)
        export(PlanningStore.shared, force: true)
    }

    /// Les scripts en texte dans iCloud Drive/Toolbox : sur l'iPhone, Fichiers → ouvrir → tout sélectionner → copier.
    static func publishScriptsAsText() {
        let dir = iCloudDriveDir
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, text) in [("Script Prochain shift.txt", script), ("Script Mon Mac.txt", macScript)] {
                let u = dir.appendingPathComponent(name)
                if (try? String(contentsOf: u, encoding: .utf8)) != text {
                    try? text.write(to: u, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    static func copyScript(mac: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mac ? macScript : script, forType: .string)
    }

    // MARK: Script Scriptable

    static let script = ##"""
// Variables used by Scriptable.
// These must be at the very top of the file. Do not edit.
// icon-color: yellow; icon-glyph: hamburger;

// Prochain shift — widget de Toolbox.
// Les données sont écrites par Toolbox sur le Mac (iCloud) : rien à régler ici.
// Tailles : petit, moyen, et écran verrouillé (rectangle, cercle, ligne).

const FILE = "Toolbox.json"
const YELLOW = new Color("#FFC72C")
const RED = new Color("#FF5F57")
const GREEN = new Color("#32D74B")
const GRAY = new Color("#9A9AA0")

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

const DAYS = ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]
const MONTHS = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]
const pad = n => String(n).padStart(2, "0")
const hm = d => pad(d.getHours()) + ":" + pad(d.getMinutes())
const hours = m => { const h = Math.floor(m / 60), r = m % 60; return r ? `${h} h ${pad(r)}` : `${h} h` }

function dayLabel(d, now) {
  const a = new Date(now); a.setHours(0, 0, 0, 0)
  const b = new Date(d); b.setHours(0, 0, 0, 0)
  const diff = Math.round((b - a) / 86400000)
  if (diff === 0) return "Aujourd'hui"
  if (diff === 1) return "Demain"
  return `${DAYS[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()]}`
}

const data = await load()
const now = new Date()
const shifts = ((data && data.shifts) || []).map(s => ({
  ...s,
  start: new Date(s.start),
  end: new Date(s.end),
  pauses: (s.pauses || []).map(p => ({ start: new Date(p.start), end: new Date(p.end) })),
})).sort((a, b) => a.start - b.start)
const next = shifts.find(s => s.end > now)
const after = next ? shifts.find(s => s.start >= next.end) : null
const working = next ? next.start <= now : false
const pause = next ? next.pauses.find(p => p.end > now) : null
const family = config.widgetFamily || "medium"

// heures de la semaine (lundi → dimanche)
const monday = new Date(now); monday.setHours(0, 0, 0, 0)
monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7))
const sunday = new Date(monday.getTime() + 7 * 86400000)
const weekMinutes = shifts.filter(s => s.start >= monday && s.start < sunday).reduce((t, s) => t + s.paidMinutes, 0)

const w = new ListWidget()
if (next) w.url = "calshow:" + Math.round(next.start.getTime() / 1000 - 978307200)

// prochaine mise à jour : au début, à la fin du shift, aux pauses, sinon dans 1 h
const moments = [now.getTime() + 3600000]
if (next) {
  moments.push(next.start.getTime(), next.end.getTime())
  next.pauses.forEach(p => moments.push(p.start.getTime(), p.end.getTime()))
}
w.refreshAfterDate = new Date(Math.min(...moments.filter(t => t > now.getTime() + 30000)))

function text(stack, s, font, color, lines = 1) {
  const t = stack.addText(s)
  t.font = font
  t.textColor = color
  t.lineLimit = lines
  t.minimumScaleFactor = 0.6
  return t
}

function relative(stack, prefix, date, font, color) {
  const row = stack.addStack()
  row.centerAlignContent()
  if (prefix) text(row, prefix, font, color)
  const d = row.addDate(date)
  d.applyRelativeStyle()
  d.font = font
  d.textColor = color
  return row
}

if (family === "accessoryInline") {
  w.addText(next ? `🍟 ${working ? "fin " + hm(next.end) : dayLabel(next.start, now) + " " + hm(next.start)}` : "🍟 Pas de shift")
} else if (family === "accessoryCircular") {
  const s = w.addStack(); s.layoutVertically(); s.centerAlignContent()
  if (next) {
    text(s, working ? "fin" : (dayLabel(next.start, now) === "Aujourd'hui" ? "auj." : DAYS[next.start.getDay()]), Font.systemFont(10), Color.white())
    text(s, hm(working ? next.end : next.start), Font.boldRoundedSystemFont(15), Color.white())
  } else {
    text(s, "🍟", Font.systemFont(18), Color.white())
  }
} else if (family === "accessoryRectangular") {
  if (next) {
    text(w, working ? "🍟 En service" : "🍟 " + dayLabel(next.start, now), Font.semiboldSystemFont(12), Color.white())
    text(w, `${hm(next.start)} → ${hm(next.end)}`, Font.boldRoundedSystemFont(18), Color.white())
    relative(w, working ? "fin dans " : "dans ", working ? next.end : next.start, Font.systemFont(12), Color.white())
  } else {
    text(w, "🍟 Pas de shift prévu", Font.semiboldSystemFont(13), Color.white())
  }
} else {
  const g = new LinearGradient()
  g.colors = [new Color("#2C2C2E"), new Color("#1C1C1E")]
  g.locations = [0, 1]
  w.backgroundGradient = g
  w.setPadding(14, 14, 14, 14)
  const small = family === "small"

  const head = w.addStack(); head.centerAlignContent()
  const icon = head.addImage(SFSymbol.named("fork.knife").image)
  icon.imageSize = new Size(13, 13); icon.tintColor = YELLOW
  head.addSpacer(5)
  text(head, "Prochain shift", Font.boldSystemFont(13), YELLOW)
  if (!small) {
    head.addSpacer()
    text(head, `Semaine : ${hours(weekMinutes)}${data && data.contractHours ? " / " + data.contractHours + " h" : ""}`, Font.mediumSystemFont(11), GRAY)
  }
  w.addSpacer(small ? 6 : 8)

  if (!data) {
    text(w, "Pas de données : dans Scriptable, Réglages → Signets de fichiers → + → dossier iCloud Drive/Toolbox, nommé « Toolbox ».", Font.systemFont(12), GRAY, 4)
  } else if (!next) {
    text(w, "Aucun shift prévu 🎉", Font.semiboldSystemFont(15), Color.white(), 2)
  } else {
    text(w, working ? (pause && pause.start <= now ? "En pause ☕" : "En service") : dayLabel(next.start, now),
         Font.semiboldSystemFont(12), working ? GREEN : GRAY)
    w.addSpacer(2)
    text(w, `${hm(next.start)} → ${hm(next.end)}`, Font.boldRoundedSystemFont(small ? 24 : 30), Color.white())
    if (working && pause && pause.start <= now) {
      relative(w, "reprise dans ", pause.end, Font.systemFont(12), GRAY)
    } else if (working) {
      relative(w, "fin dans ", next.end, Font.systemFont(12), GRAY)
    } else {
      relative(w, "dans ", next.start, Font.systemFont(12), GRAY)
    }
    w.addSpacer(small ? 4 : 6)
    let info = `${hours(next.paidMinutes)} payées`
    if (!small && next.pauses.length) info += " · pauses " + next.pauses.map(p => `${hm(p.start)}–${hm(p.end)}`).join(", ")
    text(w, info, Font.systemFont(11), GRAY, 2)
    if (next.conflict) {
      w.addSpacer(3)
      text(w, "⚠️ " + next.conflict.replace(/^⚠️\s*/, ""), Font.semiboldSystemFont(11), RED, 2)
    } else if (!small && after) {
      w.addSpacer(3)
      text(w, `Ensuite : ${dayLabel(after.start, now).toLowerCase()}, ${hm(after.start)}–${hm(after.end)}`, Font.systemFont(11), new Color("#6E6E73"))
    }
  }
  w.addSpacer()
}

Script.setWidget(w)
if (!config.runsInWidget) await w.presentMedium()
Script.complete()
"""##
}
