import Foundation

/// Dossiers récemment ouverts dans VS Code (lus dans sa base d'état, sans la modifier).
public enum VSCodeRecents {
    /// VS Code Insiders d'abord, puis VS Code classique.
    static var stateDBs: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return ["Code - Insiders", "Code"].map {
            support.appendingPathComponent("\($0)/User/globalStorage/state.vscdb")
        }
    }

    public static func folders(limit: Int = 10) -> [URL] {
        var out: [URL] = []
        for db in stateDBs {
            for u in folders(in: db, limit: limit) where !out.contains(where: { $0.path == u.path }) {
                out.append(u)
            }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    static func folders(in stateDB: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateDB.path) else { return [] }
        // Copie temporaire : VS Code peut avoir la base ouverte.
        let tmp = fm.temporaryDirectory.appendingPathComponent("toolbox-vscode-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("state.vscdb")
        guard (try? fm.copyItem(at: stateDB, to: copy)) != nil else { return [] }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: stateDB.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        guard let db = try? SQLiteDB(path: copy.path),
              let row = try? db.query("SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'").first,
              let value = row["value"], let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return [] }
        var out: [URL] = []
        for e in entries {
            guard let s = e["folderUri"] as? String, s.hasPrefix("file://"), let u = URL(string: s) else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { out.append(u) }
            if out.count == limit { break }
        }
        return out
    }
}
