import Foundation

// Widget iPhone « Ma journée » : cours du jour, shift, prochain CC et batteries, en un seul widget.

extension PhoneWidget {
    static let dayScriptName = "Ma journée.js"

    static let dayScript = ##"""
// Variables used by Scriptable.
// These must be at the very top of the file. Do not edit.
// icon-color: orange; icon-glyph: sun;

// Ma journée — widget de Toolbox : cours, shift, prochain CC et batteries (Mac, casque, iPhone).
// Tailles : petit, moyen, grand. Données envoyées par Toolbox via iCloud (signet « Toolbox »).

const ORANGE = new Color("#FF9F0A"), RED = new Color("#FF453A"), GREEN = new Color("#32D74B")
const MINT = new Color("#63E6BE"), YELLOW = new Color("#FFC72C"), CYAN = new Color("#64D2FF")
const GRAY = new Color("#9A9AA0"), DIM = new Color("#6E6E73"), WHITE = Color.white()

async function read(fm, dir, file) {
  const path = fm.joinPath(dir, file)
  if (!fm.fileExists(path)) return null
  try { await fm.downloadFileFromiCloud(path); return JSON.parse(fm.readString(path)) } catch (e) { return null }
}

const fm = FileManager.iCloud()
let dir = null
try { dir = fm.bookmarkedPath("Toolbox") } catch (e) {}

// batterie de l'iPhone → Mac
async function reportPhone() {
  let msg
  try {
    const info = {
      updated: new Date().toISOString(), name: Device.name(), model: Device.model(),
      battery: Math.round(Device.batteryLevel() * 100), charging: Device.isCharging(), full: Device.isFullyCharged(),
    }
    fm.writeString(fm.joinPath(dir, "ToolboxPhone.json"), JSON.stringify(info))
    msg = `Batterie envoyée au Mac : ${info.battery} %`
  } catch (e) {
    msg = "Envoi impossible : " + e + "\n(vérifie le signet « Toolbox » dans Settings → File Bookmarks)"
  }
  if (config.runsInApp) { const a = new Alert(); a.title = "Toolbox"; a.message = msg; a.addAction("OK"); await a.present() }
}
if (dir) await reportPhone()

const day = dir ? await read(fm, dir, "ToolboxDay.json") : null
const plan = dir ? await read(fm, dir, "Toolbox.json") : null
const mac = dir ? await read(fm, dir, "ToolboxMac.json") : null

const now = new Date()
const pad = n => String(n).padStart(2, "0")
const hm = d => pad(d.getHours()) + ":" + pad(d.getMinutes())
const DAYS = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
const MONTHS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
const family = config.widgetFamily || "large"

// le soir (après le dernier cours), on montre demain
let lessons = ((day && day.today) || []).map(l => ({ ...l, start: new Date(l.start), end: new Date(l.end) }))
let label = "Aujourd'hui"
if (lessons.length && lessons.every(l => l.end < now) && day && day.tomorrow && day.tomorrow.length) {
  lessons = day.tomorrow.map(l => ({ ...l, start: new Date(l.start), end: new Date(l.end) }))
  label = "Demain"
} else if (!lessons.length && now.getHours() >= 18 && day && day.tomorrow && day.tomorrow.length) {
  lessons = day.tomorrow.map(l => ({ ...l, start: new Date(l.start), end: new Date(l.end) }))
  label = "Demain"
}
const upcomingLessons = lessons.filter(l => l.end > now)
const shifts = ((plan && plan.shifts) || []).map(s => ({ ...s, start: new Date(s.start), end: new Date(s.end) })).sort((a, b) => a.start - b.start)
const shift = shifts.find(s => s.end > now)
const exam = day && day.exam ? { ...day.exam, date: new Date(day.exam.date) } : null
const examDays = exam ? Math.round((new Date(exam.date).setHours(0, 0, 0, 0) - new Date(now).setHours(0, 0, 0, 0)) / 86400000) : null

function text(stack, s, font, col, lines = 1) {
  const t = stack.addText(s); t.font = font; t.textColor = col; t.lineLimit = lines; t.minimumScaleFactor = 0.6; return t
}

function dayName(d) {
  if (sameDay(d, now)) return "auj."
  const t = new Date(now); t.setDate(t.getDate() + 1)
  if (sameDay(d, t)) return "demain"
  return DAYS[d.getDay()].slice(0, 3) + ". " + d.getDate()
}

function bar(progress, color, w = 120, h = 6) {
  const d = new DrawContext(); d.size = new Size(w, h); d.opaque = false; d.respectScreenScale = true
  const bg = new Path(); bg.addRoundedRect(new Rect(0, 0, w, h), h / 2, h / 2)
  d.addPath(bg); d.setFillColor(new Color("#FFFFFF", 0.15)); d.fillPath()
  const fg = new Path(); fg.addRoundedRect(new Rect(0, 0, Math.max(h, w * Math.min(1, progress)), h), h / 2, h / 2)
  d.addPath(fg); d.setFillColor(color); d.fillPath()
  return d.getImage()
}

function row(stack, symbol, tint) {
  const r = stack.addStack(); r.centerAlignContent()
  const i = r.addImage(SFSymbol.named(symbol).image); i.imageSize = new Size(13, 13); i.tintColor = tint
  r.addSpacer(6)
  return r
}

function examColor() {
  if (!exam) return GRAY
  if (exam.total && exam.done === exam.total) return GREEN
  if (exam.urgent) return RED
  return examDays <= 7 ? ORANGE : MINT
}

function devices(stack) {
  const r = stack.addStack(); r.centerAlignContent()
  const item = (sym, pct, charging) => {
    const i = r.addImage(SFSymbol.named(sym).image); i.imageSize = new Size(12, 12); i.tintColor = GRAY
    r.addSpacer(3)
    text(r, `${pct} %${charging ? "⚡" : ""}`, Font.semiboldRoundedSystemFont(12), pct <= 20 && !charging ? RED : WHITE)
    r.addSpacer(10)
  }
  if (mac && mac.battery) item(mac.sleeping ? "moon.zzz.fill" : "laptopcomputer", mac.battery.percent, mac.battery.charging)
  if (mac && mac.headphone) item("headphones", mac.headphone.percent, mac.headphone.charging)
  item("iphone", Math.round(Device.batteryLevel() * 100), Device.isCharging())
}

const w = new ListWidget()
w.refreshAfterDate = new Date(now.getTime() + 10 * 60000)
const g = new LinearGradient()
g.colors = [new Color("#2B2A33"), new Color("#18171C")]
g.locations = [0, 1]
w.backgroundGradient = g
w.setPadding(14, 14, 12, 14)

if (!dir) {
  text(w, "Signet « Toolbox » introuvable : Scriptable → Settings → File Bookmarks → + → Pick Folder → iCloud Drive → Toolbox, nommé « Toolbox ».", Font.systemFont(12), GRAY, 6)
} else if (family === "small") {
  text(w, `${DAYS[now.getDay()]} ${now.getDate()}`, Font.boldSystemFont(13), ORANGE)
  w.addSpacer(6)
  const next = upcomingLessons[0]
  if (next) {
    text(w, next.name, Font.semiboldSystemFont(15), WHITE, 2)
    text(w, `${label === "Demain" ? "demain " : ""}${hm(next.start)}–${hm(next.end)}`, Font.systemFont(12), GRAY)
  } else if (shift) {
    text(w, "🍟 " + dayName(shift.start), Font.semiboldSystemFont(14), YELLOW)
    text(w, `${hm(shift.start)} → ${hm(shift.end)}`, Font.boldRoundedSystemFont(17), WHITE)
  } else {
    text(w, "Journée libre 🎉", Font.semiboldSystemFont(15), WHITE)
  }
  w.addSpacer()
  if (exam && examDays !== null && examDays <= 14) {
    text(w, `📝 ${exam.title}`, Font.mediumSystemFont(11), examColor())
    text(w, `J-${examDays} · ${exam.done}/${exam.total}`, Font.systemFont(11), GRAY)
  }
} else {
  // en-tête
  const head = w.addStack(); head.centerAlignContent()
  text(head, `☀️ ${DAYS[now.getDay()].replace(/^./, c => c.toUpperCase())} ${now.getDate()} ${MONTHS[now.getMonth()]}`, Font.boldSystemFont(14), ORANGE)
  head.addSpacer()
  devices(head)
  w.addSpacer(family === "large" ? 12 : 8)

  // cours
  const max = family === "large" ? 5 : 2
  if (upcomingLessons.length) {
    text(w, label === "Demain" ? "Demain" : "Cours", Font.semiboldSystemFont(11), GRAY)
    w.addSpacer(3)
    for (const l of upcomingLessons.slice(0, max)) {
      const live = l.start <= now && l.end > now
      const r = row(w, live ? "dot.radiowaves.left.and.right" : "book.closed.fill", live ? RED : CYAN)
      text(r, `${hm(l.start)}–${hm(l.end)}`, Font.mediumMonospacedSystemFont(12), live ? RED : GRAY)
      r.addSpacer(8)
      text(r, l.name + (family === "large" && l.location ? ` · ${l.location}` : ""), Font.semiboldSystemFont(13), WHITE)
      w.addSpacer(3)
    }
    if (upcomingLessons.length > max) text(w, `+ ${upcomingLessons.length - max} autre${upcomingLessons.length - max > 1 ? "s" : ""}`, Font.systemFont(11), DIM)
  } else {
    text(w, "📚 Pas de cours " + (now.getHours() >= 18 ? "ce soir ni demain" : "aujourd'hui"), Font.semiboldSystemFont(13), WHITE)
  }
  w.addSpacer(family === "large" ? 10 : 6)

  // shift
  if (shift) {
    const r = row(w, "fork.knife", YELLOW)
    const working = shift.start <= now
    text(r, working ? `En service jusqu'à ${hm(shift.end)}` : `Shift ${dayName(shift.start)} ${hm(shift.start)} → ${hm(shift.end)}`, Font.semiboldSystemFont(13), WHITE)
    if (family === "large" && shift.pauses && shift.pauses.length) {
      w.addSpacer(2)
      text(w, "      pauses " + shift.pauses.map(p => `${hm(new Date(p.start))}–${hm(new Date(p.end))}`).join(", "), Font.systemFont(11), GRAY)
    }
    w.addSpacer(family === "large" ? 10 : 6)
  }

  // prochain CC
  if (exam && examDays !== null) {
    const col = examColor()
    const r = row(w, "checklist", col)
    text(r, `${exam.title} · ${examDays <= 0 ? "aujourd'hui" : (examDays === 1 ? "demain" : "J-" + examDays)}`, Font.semiboldSystemFont(13), WHITE)
    w.addSpacer(4)
    const b = w.addStack(); b.centerAlignContent()
    b.addSpacer(19)
    const img = b.addImage(bar(exam.total ? exam.done / exam.total : 0, col, family === "large" ? 200 : 140))
    img.imageSize = new Size(family === "large" ? 200 : 140, 6)
    b.addSpacer(8)
    text(b, `${exam.done}/${exam.total}${exam.urgent ? " · en retard" : ""}`, Font.mediumSystemFont(11), exam.urgent ? RED : GRAY)
    if (family === "large" && exam.nextTask) {
      w.addSpacer(3)
      text(w, "      Ensuite : " + exam.nextTask, Font.systemFont(11), GRAY)
    }
  }
  w.addSpacer()
}

Script.setWidget(w)
if (config.runsInApp) await w.presentLarge()
Script.complete()
"""##
}
