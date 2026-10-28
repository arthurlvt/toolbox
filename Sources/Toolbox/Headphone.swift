import Foundation
import SwiftUI
import IOBluetooth
import EventKit

/// Batterie d'un casque / d'écouteurs Nothing (ou CMF), lue sur leur canal Bluetooth privé (RFCOMM),
/// comme le fait l'app Nothing X. Protocole documenté par le projet libre BudsLink.
/// Le canal est ouvert juste le temps de la lecture, pour ne pas gêner l'app Nothing X du téléphone.
final class HeadphoneStore: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    static let shared = HeadphoneStore()

    struct Reading: Codable, Equatable {
        var name: String
        var percent: Int
        var charging: Bool
        var date: Date
        var left: Int?
        var right: Int?
        var box: Int?
    }

    @Published var last: Reading? { didSet { save() } }
    @Published var connected = false
    @Published var reading = false

    static let serviceBytes: [UInt8] = [0xae, 0xac, 0x4a, 0x03, 0xdf, 0xf5, 0x49, 0x8f, 0x84, 0x3a, 0x34, 0x48, 0x7c, 0xf1, 0x33, 0xeb]

    private var started = false
    private var timer: Timer?
    private var connectNote: IOBluetoothUserNotification?
    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var buffer: [UInt8] = []
    private var attempts = 0
    private var seq: UInt8 = 0
    private var timeout: DispatchWorkItem?
    private var warned = false

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "headphone.last"),
           let r = try? JSONDecoder().decode(Reading.self, from: data) { last = r }
    }

    private func save() {
        if let r = last, let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: "headphone.last") }
    }

    func start() {
        guard !started else { return }
        started = true
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.isNothing(device) else { return }
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.refresh() }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { self.connected = false }
    }

    static func isNothing(_ d: IOBluetoothDevice) -> Bool {
        let n = (d.name ?? "").lowercased()
        return n.contains("nothing") || n.hasPrefix("cmf ") || n.contains("ear (")
    }

    private func connectedDevice() -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first { Self.isNothing($0) && $0.isConnected() }
    }

    // MARK: Réglages (lus sur le casque)

    @Published var anc: UInt8?              // 0x05 off, 0x07 transparence, 0x03/02/01/04 réduction faible/moyenne/forte/adaptative
    @Published var eq: UInt8?               // 0x00 équilibré, 0x01 voix, 0x02 aigus, 0x03 basses, 0x05/06 perso
    @Published var bassOn: Bool?
    @Published var bassLevel = 3            // 1…5
    @Published var lowLatency: Bool?
    @Published var firmware: String?
    @Published var ringing = false
    @Published var error: String?

    static let ancOff: UInt8 = 0x05, ancTransparency: UInt8 = 0x07
    static let ancLevels: [(UInt8, String)] = [(0x03, "Faible"), (0x02, "Moyenne"), (0x01, "Forte"), (0x04, "Adaptative")]
    static let eqPresets: [(UInt8, String)] = [(0x00, "Équilibré"), (0x01, "Voix"), (0x02, "Aigus"), (0x03, "Basses")]

    var ancIsReduction: Bool { anc.map { [0x01, 0x02, 0x03, 0x04].contains($0) } ?? false }
    var ancLabel: String {
        guard let a = anc else { return "—" }
        if a == Self.ancOff { return "réduction de bruit désactivée" }
        if a == Self.ancTransparency { return "transparence" }
        return "réduction " + (Self.ancLevels.first { $0.0 == a }?.1.lowercased() ?? "")
    }

    // MARK: Échanges avec le casque
    // Une « séance » = ouvrir le canal, envoyer quelques paquets, écouter les réponses, refermer.

    private var outgoing: [(UInt16, [UInt8])] = []
    private var queued: [(UInt16, [UInt8])] = []
    private static let readAll: [(UInt16, [UInt8])] = [(0xC007, []), (0xC01E, []), (0xC01F, []), (0xC050, []), (0xC04E, []), (0xC041, []), (0xC042, [])]

    /// Relit la batterie et tous les réglages.
    func refresh() { run(Self.readAll) }

    func setANC(_ code: UInt8) { anc = code; run([(0xF00F, [0x01, code, 0x00]), (0xC01E, [])]) }
    func setEQ(_ code: UInt8) { eq = code; run([(0xF010, [code, 0x00]), (0xC01F, [])]) }
    func setBass(on: Bool, level: Int) {
        let l = UInt8(max(1, min(5, level)))
        bassOn = on; bassLevel = Int(l)
        run([(0xF051, [on ? 0x01 : 0x00, l * 2]), (0xC04E, [])])
    }
    func setLowLatency(_ on: Bool) { lowLatency = on; run([(0xF040, [on ? 0x01 : 0x02, 0x00]), (0xC041, [])]) }
    func ring(_ on: Bool) {
        ringing = on
        run([(0xF002, [0x06, on ? 0x01 : 0x00])])
        if on { DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in if self?.ringing == true { self?.ring(false) } } }
    }

    /// Passe à la réduction de bruit / transparence / désactivée (pour ⌘K et la barre des menus).
    func cycleANC() {
        if ancIsReduction { setANC(Self.ancTransparency) }
        else if anc == Self.ancTransparency { setANC(Self.ancOff) }
        else { setANC(0x04) }
    }

    private func run(_ packets: [(UInt16, [UInt8])]) {
        if reading { queued += packets; return }
        guard let dev = connectedDevice() else {
            connected = false
            if packets.contains(where: { $0.0 >= 0xF000 }) { error = "Casque non connecté au Mac" }
            return
        }
        connected = true
        error = nil
        reading = true
        device = dev
        attempts = 0
        buffer = []
        outgoing = packets
        openChannel()
        let t = DispatchWorkItem { [weak self] in self?.finish(timedOut: true) }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: t)
    }

    private func channelID(_ dev: IOBluetoothDevice) -> BluetoothRFCOMMChannelID {
        let uuid: IOBluetoothSDPUUID = IOBluetoothSDPUUID(bytes: Self.serviceBytes, length: 16)
        for case let rec as IOBluetoothSDPServiceRecord in dev.services ?? [] {
            var ch: BluetoothRFCOMMChannelID = 0
            if rec.matchesUUIDArray([uuid]), rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess { return ch }
        }
        return 15
    }

    private func openChannel() {
        guard let dev = device else { finish(); return }
        attempts += 1
        var ch: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelAsync(&ch, withChannelID: channelID(dev), delegate: self)
        if r == kIOReturnSuccess { channel = ch } else { retry() }
    }

    /// Le premier essai échoue souvent : on recommence jusqu'à 4 fois.
    private func retry() {
        channel = nil
        guard attempts < 4 else { error = "Le casque ne répond pas (Nothing X ouvert sur le téléphone ?)"; finish(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openChannel() }
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess, let ch = rfcommChannel else { retry(); return }
        channel = ch
        sendNext()
    }

    /// Un paquet toutes les 0,25 s, puis 1,5 s d'écoute avant de refermer.
    private func sendNext() {
        guard reading, let ch = channel else { return }
        guard !outgoing.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
            return
        }
        let (type, payload) = outgoing.removeFirst()
        var p = packet(type, payload)
        _ = ch.writeSync(&p, length: UInt16(p.count))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.sendNext() }
    }

    private func packet(_ type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        seq = seq >= 250 ? 1 : seq + 1
        var p: [UInt8] = [0x55, 0x60, 0x01, UInt8(type & 0xFF), UInt8(type >> 8), UInt8(payload.count), 0x00, seq] + payload
        let c = Self.crc16(p)
        p += [UInt8(c & 0xFF), UInt8(c >> 8)]
        return p
    }

    static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let ptr = dataPointer else { return }
        buffer += Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: dataLength))
        parse()
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        if reading { channel = nil }
    }

    private func parse() {
        while let i = buffer.firstIndex(of: 0x55), buffer.count - i >= 8 {
            let len = Int(buffer[i + 5])
            let hasCrc = (buffer[i + 1] & 0x20) != 0
            let total = 8 + len + (hasCrc ? 2 : 0)
            guard buffer.count - i >= total else { return }
            let type = UInt16(buffer[i + 3]) | UInt16(buffer[i + 4]) << 8
            let p = Array(buffer[(i + 8)..<(i + 8 + len)])
            buffer.removeFirst(i + total)
            handle(type, p)
        }
        if buffer.count > 2000 { buffer = [] }
    }

    private func handle(_ type: UInt16, _ p: [UInt8]) {
        switch type {
        case 0xE001, 0x4007: handleBattery(p)
        case 0xE003, 0x401E, 0x6003: if p.count > 1 { anc = p[1] }
        case 0x401F, 0x4050: if let e = p.first { eq = e }
        case 0x404E, 0x7051: if p.count > 1 { bassOn = p[0] == 1; if p[1] > 0 { bassLevel = Int(p[1] / 2) } }
        case 0x4041: if let v = p.first { lowLatency = v == 1 }
        case 0x7040: if p.count > 1, let v = p.first { lowLatency = v == 1 }
        case 0x4042: firmware = String(bytes: p, encoding: .utf8)
        default: break
        }
    }

    private func handleBattery(_ payload: [UInt8]) {
        guard let count = payload.first else { return }
        var single: (Int, Bool)?, left: (Int, Bool)?, right: (Int, Bool)?, box: (Int, Bool)?
        for k in 0..<Int(count) where 2 + k * 2 < payload.count {
            let id = payload[1 + k * 2], v = payload[2 + k * 2]
            let reading = (Int(v & 0x7F), (v & 0x80) != 0)
            switch id {
            case 0x06: single = reading
            case 0x02: left = reading
            case 0x03: right = reading
            case 0x04: box = reading
            default: break
            }
        }
        let main = single ?? [left, right].compactMap { $0 }.min { $0.0 < $1.0 }
        guard let m = main else { return }
        let r = Reading(name: device?.name ?? "Casque", percent: m.0, charging: m.1 || (left?.1 ?? false) || (right?.1 ?? false),
                        date: Date(), left: left?.0, right: right?.0, box: box?.0)
        last = r
        warnIfLow(r)
        PhoneWidget.exportMac(MacStatusStore.shared)
    }

    private func finish(timedOut: Bool = false) {
        timeout?.cancel()
        timeout = nil
        if let ch = channel { _ = ch.setDelegate(nil); _ = ch.close() }
        channel = nil
        outgoing = []
        reading = false
        if timedOut, error == nil { error = "Le casque n'a pas répondu à temps" }
        // commandes arrivées pendant la séance : une seconde de pause (le casque doit refermer le canal)
        if !queued.isEmpty {
            let next = queued
            queued = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.run(next) }
        }
    }

    // MARK: Alerte

    private func warnIfLow(_ r: Reading) {
        if r.charging || r.percent > 30 {
            if warned { HeadphoneReminder.clear() }
            warned = false
            return
        }
        guard r.percent <= BatteryReminder.threshold, !warned else { return }
        warned = true
        ToastCenter.shared.show("🎧 \(r.name) à \(r.percent) % : pense à le recharger", seconds: 6)
        HeadphoneReminder.post(r)
    }

    // MARK: Textes

    var ageText: String? {
        guard let r = last else { return nil }
        if connected && Date().timeIntervalSince(r.date) < 600 { return nil }
        let m = Int(Date().timeIntervalSince(r.date) / 60)
        if m < 60 { return "il y a \(max(1, m)) min" }
        if m < 48 * 60 { return "il y a \(m / 60) h" }
        return "il y a \(m / 1440) j"
    }
}

/// Rappel « Recharge ton casque » (même principe que celui du Mac, liste Rappels → iPhone).
enum HeadphoneReminder {
    private static var lastID: String? {
        get { UserDefaults.standard.string(forKey: "headphone.reminder.id") }
        set { UserDefaults.standard.set(newValue, forKey: "headphone.reminder.id") }
    }

    static func post(_ r: HeadphoneStore.Reading) {
        guard BatteryReminder.enabled, BatteryReminder.hasAccess else { return }
        let store = BatteryReminder.store
        clear()
        guard let list = store.defaultCalendarForNewReminders()
                ?? store.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) else { return }
        let rem = EKReminder(eventStore: store)
        rem.title = "🎧 Recharge ton casque (\(r.percent) %)"
        rem.notes = "\(r.name). Envoyé par Toolbox, disparaît tout seul quand le casque charge."
        rem.calendar = list
        let when = Date().addingTimeInterval(120)
        rem.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
        rem.addAlarm(EKAlarm(absoluteDate: when))
        if (try? store.save(rem, commit: true)) != nil { lastID = rem.calendarItemIdentifier }
    }

    static func clear() {
        guard let id = lastID else { return }
        lastID = nil
        let store = BatteryReminder.store
        guard BatteryReminder.hasAccess, let rem = store.calendarItem(withIdentifier: id) as? EKReminder, !rem.isCompleted else { return }
        rem.isCompleted = true
        try? store.save(rem, commit: true)
    }
}

// MARK: - Ligne dans le widget « Mon Mac »

struct HeadphoneRow: View {
    @ObservedObject var h = HeadphoneStore.shared
    @StateObject private var showPanel = HoverFlag()

    var body: some View {
        if let r = h.last {
            HStack(spacing: 10) {
                Image(systemName: "headphones").font(.title3).foregroundStyle(Color.cyan).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(detail(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                BatteryGauge(percent: r.percent, charging: r.charging).frame(width: 34, height: 16)
                Text("\(r.percent) %").font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(BatteryGauge.color(r.percent, plugged: r.charging))
                Button { h.refresh() } label: {
                    Image(systemName: "arrow.clockwise").rotationEffect(.degrees(h.reading ? 360 : 0))
                        .animation(h.reading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: h.reading)
                }
                .buttonStyle(.borderless).disabled(h.reading || !h.connected)
                .help(h.connected ? "Relire la batterie du casque" : "Casque non connecté au Mac")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .opacity(h.connected ? 1 : 0.7)
            .contentShape(Rectangle())
            .onTapGesture { showPanel.on = true; if h.connected { h.refresh() } }
            .help("Réglages du casque")
            .popover(isPresented: Binding(get: { showPanel.on }, set: { showPanel.on = $0 }), arrowEdge: .bottom) {
                HeadphonePanel().padding(16).frame(width: 340)
            }
        }
    }

    private func detail(_ r: HeadphoneStore.Reading) -> String {
        var parts: [String] = []
        if let l = r.left, let rr = r.right { parts.append("G \(l) % · D \(rr) %") }
        if let b = r.box { parts.append("boîtier \(b) %") }
        if r.charging { parts.append("en charge") }
        if h.connected, h.anc != nil { parts.append(h.ancLabel) }
        if let age = h.ageText { parts.append(h.connected ? age : "déconnecté · \(age)") }
        else if !h.connected { parts.append("déconnecté") }
        return parts.isEmpty ? "connecté" : parts.joined(separator: " · ")
    }
}


// MARK: - Panneau de contrôle du casque

struct HeadphonePanel: View {
    @ObservedObject var h = HeadphoneStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "headphones").font(.title2).foregroundStyle(Color.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.last?.name ?? "Casque").font(.headline)
                    Text(h.connected ? (h.firmware.map { "Firmware \($0)" } ?? "Connecté") : "Non connecté au Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if h.reading { ProgressView().controlSize(.small) }
                if let r = h.last {
                    BatteryGauge(percent: r.percent, charging: r.charging).frame(width: 34, height: 16)
                    Text("\(r.percent) %").font(.callout.weight(.bold).monospacedDigit())
                }
            }

            if !h.connected {
                Text("Connecte le casque au Mac (menu Bluetooth ou Son) pour le régler d'ici.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                section("Réduction de bruit") {
                    Picker("", selection: Binding(get: { h.ancIsReduction ? 0 : (h.anc == HeadphoneStore.ancTransparency ? 1 : 2) },
                                                  set: { v in h.setANC(v == 0 ? 0x04 : (v == 1 ? HeadphoneStore.ancTransparency : HeadphoneStore.ancOff)) })) {
                        Text("Réduction").tag(0)
                        Text("Transparence").tag(1)
                        Text("Désactivée").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    if h.ancIsReduction {
                        Picker("", selection: Binding(get: { h.anc ?? 0x04 }, set: { h.setANC($0) })) {
                            ForEach(HeadphoneStore.ancLevels, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                section("Égaliseur") {
                    Picker("", selection: Binding(get: { h.eq ?? 0x00 }, set: { h.setEQ($0) })) {
                        ForEach(HeadphoneStore.eqPresets, id: \.0) { Text($0.1).tag($0.0) }
                        if let e = h.eq, e >= 0x05 { Text("Perso").tag(e) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                section("Renfort des basses") {
                    HStack {
                        Toggle("", isOn: Binding(get: { h.bassOn ?? false }, set: { h.setBass(on: $0, level: h.bassLevel) }))
                            .toggleStyle(.switch).labelsHidden()
                        Picker("", selection: Binding(get: { h.bassLevel }, set: { h.setBass(on: true, level: $0) })) {
                            ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .disabled(h.bassOn != true)
                    }
                }
                Toggle(isOn: Binding(get: { h.lowLatency ?? false }, set: { h.setLowLatency($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Faible latence")
                        Text("Pour les jeux et les vidéos").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                HStack {
                    Button {
                        h.ring(!h.ringing)
                    } label: {
                        Label(h.ringing ? "Arrêter la sonnerie" : "Faire sonner le casque", systemImage: h.ringing ? "speaker.slash.fill" : "speaker.wave.3.fill")
                    }
                    .tint(h.ringing ? .red : nil)
                    Spacer()
                    Button { h.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Relire les réglages").disabled(h.reading)
                }
            }
            if let e = h.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.orange)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Ligne compacte dans la barre des menus : batterie + mode de réduction de bruit en un clic.
struct MenuHeadphoneStrip: View {
    @ObservedObject var h = HeadphoneStore.shared

    var body: some View {
        if h.connected, let r = h.last {
            HStack(spacing: 8) {
                Image(systemName: "headphones").foregroundStyle(Color.cyan)
                Text("\(r.percent) %").font(.callout.monospacedDigit())
                Spacer()
                ForEach([(UInt8(0x04), "Réduction", "ear.fill"), (HeadphoneStore.ancTransparency, "Transparence", "ear.and.waveform"),
                         (HeadphoneStore.ancOff, "Désactivée", "ear.badge.xmark")], id: \.0) { item in
                    let active = item.0 == 0x04 ? h.ancIsReduction : h.anc == item.0
                    Button { h.setANC(item.0) } label: {
                        Image(systemName: item.2).frame(width: 22, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .help(item.1)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
