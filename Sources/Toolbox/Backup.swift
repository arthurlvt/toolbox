import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFCore

// MARK: - Sauvegarde du profil
//
// Une sauvegarde = un dossier avec :
//   • Réglages.plist : toutes les préférences de l'app (profil, calendriers choisis, accueil, planning, révisions…)
//   • les fichiers de données d'Application Support/Toolbox (notes, planning, révisions, signatures…)
// Faite toute seule à chaque nouvelle version de l'app, et à la demande. Exportable en .zip (autre Mac, Nextcloud…).

final class BackupStore: ObservableObject {
    static let shared = BackupStore()

    struct Item: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let date: Date
        let reason: String
        let size: Int64
    }

    @Published private(set) var items: [Item] = []
    @Published var status: StatusMessage?

    static let bundleID = Bundle.main.bundleIdentifier ?? "fr.arthur.toolbox"
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox", isDirectory: true)
    }
    static var folder: URL { dataFolder.appendingPathComponent("Sauvegardes", isDirectory: true) }

    /// Ce qu'on ne copie pas : les sauvegardes elles-mêmes, l'historique LaTeX (lourd) et l'index des cours (se refait seul).
    static let skipped: Set<String> = ["Sauvegardes", "Profils", "profil-actif.txt", "Historique", "IndexCours.json", ".DS_Store"]
    /// Clés propres à ce Mac, jamais remplacées par une sauvegarde ou un profil.
    static let machineKeys = ["build.sourceDir", "backup.lastBuild"]
    static let keepAutomatic = 8

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    // MARK: Liste

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        items = dirs.compactMap { u -> Item? in
            guard fm.fileExists(atPath: u.appendingPathComponent("Réglages.plist").path) else { return nil }
            let info = (try? String(contentsOf: u.appendingPathComponent("info.txt"), encoding: .utf8)) ?? ""
            let date = Self.stamp.date(from: String(u.lastPathComponent.prefix(19)))
                ?? ((try? fm.attributesOfItem(atPath: u.path)[.creationDate]) as? Date) ?? .distantPast
            return Item(url: u, date: date, reason: info.isEmpty ? "manuelle" : info, size: Self.size(of: u))
        }
        .sorted { $0.date > $1.date }
    }

    static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    // MARK: Créer

    @discardableResult
    static func create(reason: String) throws -> URL {
        let dir = folder.appendingPathComponent(stamp.string(from: Date()) + " – " + reason, isDirectory: true)
        try write(to: dir)
        try? reason.write(to: dir.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        prune()
        return dir
    }

    /// Écrit l'état actuel (réglages + données) dans `dir`.
    static func write(to dir: URL) throws {
        let fm = FileManager.default
        UserDefaults.standard.synchronize()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // réglages
        let prefs = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        let data = try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
        try data.write(to: dir.appendingPathComponent("Réglages.plist"))
        // fichiers de données
        let files = (try? fm.contentsOfDirectory(at: dataFolder, includingPropertiesForKeys: nil)) ?? []
        let dataDir = dir.appendingPathComponent("Données", isDirectory: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        for f in files where !skipped.contains(f.lastPathComponent) {
            try? fm.copyItem(at: f, to: dataDir.appendingPathComponent(f.lastPathComponent))
        }
    }

    /// On garde les `keepAutomatic` dernières sauvegardes automatiques ; les manuelles ne sont jamais effacées.
    private static func prune() {
        let fm = FileManager.default
        let autos = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ((try? String(contentsOf: $0.appendingPathComponent("info.txt"), encoding: .utf8)) ?? "").hasPrefix("auto") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in autos.dropFirst(keepAutomatic) { try? fm.trashItem(at: old, resultingItemURL: nil) }
    }

    /// Au lancement : une sauvegarde automatique si l'app a changé depuis la dernière fois (mise à jour, recompilation).
    static func autoBackupIfNeeded() {
        var mod = Date()
        if let p = Bundle.main.executableURL?.path, let attrs = try? FileManager.default.attributesOfItem(atPath: p),
           let m = attrs[.modificationDate] as? Date { mod = m }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = "\(version)-\(Int(mod.timeIntervalSince1970))"
        let d = UserDefaults.standard
        guard d.string(forKey: "backup.lastBuild") != build else { return }
        // Première installation : rien à sauvegarder.
        let hasData = d.bool(forKey: "onboarding.done") || FileManager.default.fileExists(atPath: dataFolder.path)
        if hasData {
            DispatchQueue.global(qos: .utility).async {
                _ = try? BackupStore.create(reason: "auto (nouvelle version \(version))")
                DispatchQueue.main.async { BackupStore.shared.reload() }
            }
        }
        d.set(build, forKey: "backup.lastBuild")
    }

    func backupNow() {
        do {
            let u = try Self.create(reason: "manuelle")
            reload()
            status = .ok("Profil sauvegardé.", files: [u])
        } catch {
            status = .err(error)
        }
    }

    // MARK: Restaurer

    func restore(_ item: Item) {
        guard confirmDestructive("Restaurer la sauvegarde du \(Self.display(item.date)) ?",
                                 "Tes réglages et données actuels seront remplacés (une sauvegarde de l'état actuel est faite avant). Toolbox va redémarrer.",
                                 button: "Restaurer") else { return }
        do {
            try Self.restore(from: item.url)
            Self.relaunch()
        } catch {
            status = .err(error)
        }
    }

    static func restore(from dir: URL, safetyCopy: Bool = true) throws {
        let fm = FileManager.default
        let plist = dir.appendingPathComponent("Réglages.plist")
        guard let data = try? Data(contentsOf: plist),
              let prefs = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "Toolbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ce dossier n'est pas une sauvegarde de Toolbox."])
        }
        if safetyCopy { try create(reason: "auto (avant restauration)") }
        // le dossier du code et la dernière version vue restent ceux de ce Mac
        var merged = prefs
        for key in machineKeys {
            if let v = UserDefaults.standard.object(forKey: key) { merged[key] = v } else { merged.removeValue(forKey: key) }
        }
        UserDefaults.standard.setPersistentDomain(merged, forName: bundleID)
        UserDefaults.standard.synchronize()
        let src = dir.appendingPathComponent("Données", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
        try fm.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        clearData()
        for f in files {
            let dest = dataFolder.appendingPathComponent(f.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.copyItem(at: f, to: dest)
        }
    }

    /// Retire les données du profil courant (pas les sauvegardes, profils, historique LaTeX ni l'index).
    static func clearData() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dataFolder, includingPropertiesForKeys: nil)) ?? []
        where !skipped.contains(f.lastPathComponent) {
            try? fm.removeItem(at: f)
        }
    }

    // MARK: Profils

    static var profilesFolder: URL { dataFolder.appendingPathComponent("Profils", isDirectory: true) }
    private static var activeFile: URL { dataFolder.appendingPathComponent("profil-actif.txt") }

    static var activeProfile: String {
        let s = (try? String(contentsOf: activeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "Principal" : s
    }

    private static func setActive(_ name: String) {
        try? FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        try? name.write(to: activeFile, atomically: true, encoding: .utf8)
    }

    /// Profils connus (le profil actif en premier).
    static var profiles: [String] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: profilesFolder, includingPropertiesForKeys: nil)) ?? []
        let names = dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Réglages.plist").path) }
            .map { $0.lastPathComponent }
            .filter { $0 != activeProfile }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [activeProfile] + names
    }

    private static func profileDir(_ name: String) -> URL { profilesFolder.appendingPathComponent(name, isDirectory: true) }

    /// Enregistre l'état actuel dans le dossier du profil actif (remplacé).
    static func saveActiveProfile() throws {
        let dir = profileDir(activeProfile)
        let tmp = profilesFolder.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        try write(to: tmp)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        try FileManager.default.moveItem(at: tmp, to: dir)
    }

    func switchTo(_ name: String) {
        guard name != Self.activeProfile else { return }
        guard confirmDestructive("Passer au profil « \(name) » ?",
                                 "Le profil « \(Self.activeProfile) » est enregistré tel quel, puis Toolbox redémarre avec « \(name) ».",
                                 button: "Changer") else { return }
        do {
            try Self.saveActiveProfile()
            try Self.restore(from: Self.profileDir(name), safetyCopy: false)
            Self.setActive(name)
            Self.relaunch()
        } catch {
            status = .err(error)
        }
    }

    /// Nouveau profil : vide (configuration de bienvenue au redémarrage) ou copie du profil actuel.
    func newProfile() {
        let alert = NSAlert()
        alert.messageText = "Nouveau profil"
        alert.informativeText = "Chaque profil a ses propres réglages, calendriers, accueil, notes, planning et révisions."
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        field.placeholderString = "Nom du profil"
        let copy = NSButton(checkboxWithTitle: "Partir de mon profil actuel (sinon : vide)", target: nil, action: nil)
        copy.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        box.addSubview(field)
        box.addSubview(copy)
        alert.accessoryView = box
        alert.addButton(withTitle: "Créer")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, !name.hasPrefix(".") else { status = .err("Donne un nom au profil."); return }
        guard !Self.profiles.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            status = .err("Le profil « \(name) » existe déjà.")
            return
        }
        do {
            try Self.saveActiveProfile()
            if copy.state == .on {
                Self.setActive(name)
                try Self.saveActiveProfile()
                status = .ok("Profil « \(name) » créé à partir du profil actuel : c'est maintenant le profil actif.")
                objectWillChange.send()
            } else {
                // profil vide : réglages et données remis à zéro, la configuration de bienvenue se relance
                var keep: [String: Any] = [:]
                for k in Self.machineKeys { if let v = UserDefaults.standard.object(forKey: k) { keep[k] = v } }
                UserDefaults.standard.setPersistentDomain(keep, forName: Self.bundleID)
                UserDefaults.standard.synchronize()
                Self.clearData()
                Self.setActive(name)
                Self.relaunch()
            }
        } catch {
            status = .err(error)
        }
    }

    func deleteProfile(_ name: String) {
        guard name != Self.activeProfile else { return }
        guard confirmDestructive("Supprimer le profil « \(name) » ?", "Il est mis à la corbeille (récupérable).", button: "Supprimer") else { return }
        try? FileManager.default.trashItem(at: Self.profileDir(name), resultingItemURL: nil)
        objectWillChange.send()
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Exporter / importer (.zip)

    func export(_ item: Item) {
        let name = "Toolbox – profil " + String(Self.stamp.string(from: item.date).prefix(10)) + ".zip"
        guard let out = Panels.save(suggested: name, type: .zip) else { return }
        runInBackground({ () -> Void in
            if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
            let r = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", item.url.path, out.path])
            if r.status != 0 { throw NSError(domain: "Toolbox", code: 2, userInfo: [NSLocalizedDescriptionKey: "Échec de la création du .zip."]) }
        }) { [weak self] r in
            switch r {
            case .success: self?.status = .ok("Sauvegarde exportée : \(out.lastPathComponent)", files: [out])
            case .failure(let e): self?.status = .err(e)
            }
        }
    }

    /// Importe un .zip exporté (ou un dossier de sauvegarde) puis le restaure.
    func importBackup() {
        guard let u = Panels.open([.zip]).first else { return }
        let fm = FileManager.default
        var dir = u
        if u.pathExtension.lowercased() == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("toolbox-import-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                _ = try Shell.run("/usr/bin/ditto", ["-x", "-k", u.path, tmp.path])
            } catch {
                status = .err(error)
                return
            }
            let inside = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
            dir = inside.first { fm.fileExists(atPath: $0.appendingPathComponent("Réglages.plist").path) } ?? tmp
        }
        guard fm.fileExists(atPath: dir.appendingPathComponent("Réglages.plist").path) else {
            status = .err("Ce fichier n'est pas une sauvegarde de Toolbox.")
            return
        }
        guard confirmDestructive("Restaurer ce profil ?",
                                 "Tes réglages et données actuels seront remplacés (une sauvegarde de l'état actuel est faite avant). Toolbox va redémarrer.",
                                 button: "Restaurer") else { return }
        do {
            try Self.restore(from: dir)
            Self.relaunch()
        } catch {
            status = .err(error)
        }
    }

    static func display(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM yyyy 'à' HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Réglages → Général

struct BackupSettings: View {
    @ObservedObject var b = BackupStore.shared

    var body: some View {
        Section("Profils") {
            ForEach(BackupStore.profiles, id: \.self) { name in
                HStack {
                    Image(systemName: name == BackupStore.activeProfile ? "person.crop.circle.fill" : "person.crop.circle")
                        .foregroundStyle(name == BackupStore.activeProfile ? Color.accentColor : Color.secondary)
                    Text(name).fontWeight(name == BackupStore.activeProfile ? .semibold : .regular)
                    if name == BackupStore.activeProfile {
                        Text("actif").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if name != BackupStore.activeProfile {
                        Button("Utiliser") { b.switchTo(name) }.font(.caption)
                        Button { b.deleteProfile(name) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Supprimer ce profil")
                    }
                }
            }
            Button("Nouveau profil…") { b.newProfile() }
        }
        Section("Sauvegarde du profil") {
            Text("Réglages, calendriers choisis, accueil, notes, planning, révisions, signatures… Une sauvegarde est faite toute seule à chaque nouvelle version de Toolbox (les \(BackupStore.keepAutomatic) dernières sont gardées). Les autorisations macOS (Calendrier, Rappels…) ne se sauvegardent pas : pour qu'elles restent après une mise à jour, lance ./setup-signing.sh une fois.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Sauvegarder maintenant") { b.backupNow() }
                Button("Importer…") { b.importBackup() }
                    .help("Restaurer un profil exporté (.zip), par exemple depuis un autre Mac")
                Spacer()
                Button("Ouvrir le dossier") {
                    try? FileManager.default.createDirectory(at: BackupStore.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(BackupStore.folder)
                }
                .buttonStyle(.borderless)
            }
            ForEach(b.items.prefix(6)) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(BackupStore.display(item.date)).font(.callout)
                        Text(item.reason + " · " + ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Exporter…") { b.export(item) }.buttonStyle(.borderless).font(.caption)
                    Button("Restaurer") { b.restore(item) }.font(.caption)
                }
            }
            if let s = b.status { StatusBanner(message: s) }
        }
        .onAppear { b.reload() }
    }
}
