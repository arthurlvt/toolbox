import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import Darwin

/// État du Mac : batterie, processeur, mémoire, disque, température… (tout est lu localement).
final class MacStatusStore: ObservableObject {
    static let shared = MacStatusStore()

    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        var plugged: Bool
        var charged: Bool
        var minutesLeft: Int?        // jusqu'à vide (sur batterie) ou jusqu'à plein (en charge)
    }

    struct Health: Equatable {
        var percent: Int?            // capacité maximale / capacité d'origine
        var cycles: Int?
        var temperature: Double?     // °C
    }

    @Published var battery: Battery?
    @Published var health = Health()
    @Published var cpu: Double = 0           // 0…1
    @Published var memoryUsed: Double = 0    // octets
    @Published var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var diskFree: Double = 0
    @Published var diskTotal: Double = 0
    @Published var bootDate: Date?
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var started = false
    private var timer: Timer?
    private var lastTicks: (busy: Double, total: Double)?
    private var warned: Set<Int> = []

    func start() {
        guard !started else { return }
        started = true
        refreshAll()
        // veille : dernier envoi avant de dormir, nouvel envoi au réveil
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.refreshBattery()
            PhoneWidget.sleepingSince = Date()
            PhoneWidget.exportMac(self, force: true, sync: true)
            DayExport.export(force: true)
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            PhoneWidget.sleepingSince = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self = self else { return }
                self.refreshAll()
                PhoneWidget.exportMac(self, force: true)
                HeadphoneStore.shared.refresh()
            }
        }
        // la batterie prévient elle-même quand elle change
        if let src = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MacStatusStore.shared.refreshBattery() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshAll() }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermal = ProcessInfo.processInfo.thermalState
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    func refreshAll() {
        refreshBattery()
        refreshHealth()
        refreshCPU()
        refreshMemory()
        refreshDisk()
        if bootDate == nil { bootDate = Self.boot() }
        thermal = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        PhoneWidget.exportMac(self)
    }

    // MARK: Batterie

    func refreshBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { battery = nil; return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d["Type"] as? String) == "InternalBattery" || d["Current Capacity"] != nil else { continue }
            let cur = d["Current Capacity"] as? Int ?? 0
            let capacity = d["Max Capacity"] as? Int ?? 100
            let charging = d["Is Charging"] as? Bool ?? false
            let plugged = (d["Power Source State"] as? String) == "AC Power"
            let charged = d["Is Charged"] as? Bool ?? false
            let raw = charging ? d["Time to Full Charge"] as? Int : (plugged ? nil : d["Time to Empty"] as? Int)
            let b = Battery(percent: capacity > 0 ? Int((Double(cur) / Double(capacity) * 100).rounded()) : cur,
                            charging: charging, plugged: plugged, charged: charged,
                            minutesLeft: (raw ?? -1) > 0 ? raw : nil)
            if b != battery {
                let changed = b.percent != battery?.percent || b.plugged != battery?.plugged
                battery = b
                if changed { PhoneWidget.exportMac(self) }
            }
            warnIfLow(b)
            return
        }
        battery = nil   // Mac de bureau
    }

    private func warnIfLow(_ b: Battery) {
        if b.plugged {
            if !warned.isEmpty { BatteryReminder.clear() }
            warned = []
            return
        }
        let threshold = BatteryReminder.threshold
        let levels = Array(Set([threshold, 10, 5])).sorted(by: >)
        for level in levels where b.percent <= level && !warned.contains(level) {
            // on marque aussi les seuils au-dessus (démarrage déjà bas : une seule alerte)
            for l in levels where l >= level { warned.insert(l) }
            ToastCenter.shared.show(level <= 5 ? "Batterie à \(b.percent) % : branche ton Mac tout de suite 🔌"
                                                : "Batterie à \(b.percent) % : pense au chargeur 🔋", seconds: 6)
            if level <= threshold { BatteryReminder.post(b.percent, minutesLeft: b.minutesLeft) }
            break
        }
    }

    private func refreshHealth() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        var h = Health()
        h.cycles = prop("CycleCount") as? Int
        let design = prop("DesignCapacity") as? Int
        let maxCap = (prop("AppleRawMaxCapacity") as? Int) ?? (prop("NominalChargeCapacity") as? Int)
        if let d = design, d > 0, let m = maxCap, m > 0 { h.percent = min(100, Int((Double(m) / Double(d) * 100).rounded())) }
        if let t = prop("Temperature") as? Int, t > 0 { h.temperature = Double(t) / 100 }
        if h != health { health = h }
    }

    // MARK: Processeur, mémoire, disque

    private func refreshCPU() {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size) }
        }
        guard r == KERN_SUCCESS else { return }
        let user = Double(info.cpu_ticks.0), system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        if let last = lastTicks, total > last.total {
            cpu = min(1, max(0, (busy - last.busy) / (total - last.total)))
        }
        lastTicks = (busy, total)
    }

    private func refreshMemory() {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        // comme le Moniteur d'activité : mémoire des apps + mémoire résidente + compressée
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        memoryUsed = max(0, (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page)
    }

    private func refreshDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
        diskTotal = Double(v.volumeTotalCapacity ?? 0)
    }

    static func boot() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec))
    }

    // MARK: Textes

    static func bytes(_ b: Double) -> String {
        let go = b / 1_000_000_000
        return go >= 100 ? "\(Int(go.rounded())) Go" : MathFormat.fr((go * 10).rounded() / 10) + " Go"
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m) min" : "\(h) h \(String(format: "%02d", m))"
    }

    var batteryLine: String {
        guard let b = battery else { return "Branché sur secteur" }
        if b.charged || (b.plugged && b.percent >= 100) { return "Branché · chargé" }
        if b.charging { return b.minutesLeft.map { "En charge · plein dans \(Self.duration($0))" } ?? "En charge…" }
        if b.plugged { return "Branché · charge en pause" }
        return b.minutesLeft.map { "Sur batterie · \(Self.duration($0)) restantes" } ?? "Sur batterie · calcul…"
    }

    var uptime: String {
        guard let d = bootDate else { return "—" }
        let m = Int(Date().timeIntervalSince(d) / 60)
        if m < 60 { return "\(m) min" }
        if m < 48 * 60 { return "\(m / 60) h" }
        return "\(m / 1440) jours"
    }

    var thermalText: String? {
        switch thermal {
        case .serious: return "Le Mac chauffe 🔥"
        case .critical: return "Le Mac surchauffe : ferme des apps 🔥"
        default: return nil
        }
    }
}

// MARK: - Widget

struct MacStatusWidget: View {
    @ObservedObject var m = MacStatusStore.shared

    var body: some View {
        Card(title: "Mes appareils", icon: "laptopcomputer", tint: .cyan,
             accessory: AnyView(Menu {
                 Button("Réglages de la batterie") {
                     if let u = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(u) }
                 }
                 Button("Moniteur d'activité") {
                     if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                         NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                     }
                 }
                 Button("Actualiser") { m.refreshAll() }
             } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize())) {
            HStack(spacing: 14) {
                if let b = m.battery {
                    BatteryGauge(percent: b.percent, charging: b.charging || b.plugged)
                        .frame(width: 64, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(b.percent) %").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(BatteryGauge.color(b.percent, plugged: b.plugged))
                        Text(m.batteryLine).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "powerplug.fill").font(.title).foregroundStyle(Color.cyan)
                    Text(m.batteryLine).font(.callout)
                }
                Spacer()
            }
            IfProfile(\.hasHeadphone) { HeadphoneRow() }
            IfProfile(\.hasPhone) { PhoneRow() }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                stat("cpu", "Processeur", "\(Int((m.cpu * 100).rounded())) %", m.cpu)
                stat("memorychip", "Mémoire", "\(MacStatusStore.bytes(m.memoryUsed)) / \(MacStatusStore.bytes(m.memoryTotal))",
                     m.memoryTotal > 0 ? m.memoryUsed / m.memoryTotal : 0)
                stat("internaldrive", "Disque", "\(MacStatusStore.bytes(m.diskFree)) libres",
                     m.diskTotal > 0 ? 1 - m.diskFree / m.diskTotal : 0)
                if let h = m.health.percent {
                    stat("heart.fill", "Santé batterie", "\(h) %" + (m.health.cycles.map { " · \($0) cycles" } ?? ""), nil)
                } else {
                    stat("clock", "Allumé depuis", m.uptime, nil)
                }
            }
            HStack(spacing: 10) {
                if m.health.percent != nil { Label("Allumé depuis \(m.uptime)", systemImage: "clock").font(.caption2) }
                if let t = m.health.temperature { Label(MathFormat.fr((t * 10).rounded() / 10) + " °C", systemImage: "thermometer.medium").font(.caption2) }
                if m.lowPower { Label("Économie d'énergie", systemImage: "leaf.fill").font(.caption2).foregroundStyle(Color.yellow) }
                Spacer()
            }
            .foregroundStyle(.secondary)
            if let t = m.thermalText {
                Label(t, systemImage: "thermometer.sun.fill").font(.caption).foregroundStyle(Color.red)
            }
        }
        .onAppear { m.start() }
    }

    private func stat(_ icon: String, _ title: String, _ value: String, _ fill: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            if let f = fill {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(f > 0.85 ? Color.red : (f > 0.65 ? Color.orange : Color.cyan))
                            .frame(width: max(3, g.size.width * min(1, f)))
                    }
                }
                .frame(height: 4)
                .animation(.easeInOut(duration: 0.6), value: f)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

/// Petite pile dessinée, remplie selon le pourcentage, avec un éclair en charge.
struct BatteryGauge: View {
    let percent: Int
    let charging: Bool

    static func color(_ p: Int, plugged: Bool) -> Color {
        if plugged { return .green }
        return p <= 10 ? .red : (p <= 20 ? .orange : .green)
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 5, h = g.size.height
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h * 0.25).stroke(Color.primary.opacity(0.5), lineWidth: 2)
                    .frame(width: w, height: h)
                RoundedRectangle(cornerRadius: h * 0.16)
                    .fill(Self.color(percent, plugged: charging).gradient)
                    .frame(width: max(2, (w - 6) * CGFloat(min(100, max(0, percent))) / 100), height: h - 6)
                    .offset(x: 3)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: percent)
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.5))
                    .frame(width: 3, height: h * 0.4)
                    .offset(x: w + 1)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: h * 0.55, weight: .bold))
                        .foregroundStyle(Color.white).shadow(radius: 1)
                        .frame(width: w, height: h)
                }
            }
        }
    }
}
