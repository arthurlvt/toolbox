import Foundation
import AppKit
import PDFCore

/// Petit pont vers l'app Notes d'Apple, par AppleScript (osascript).
/// À appeler hors du thread principal : Notes peut mettre une seconde à répondre.
enum AppleNotes {
    struct Summary: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Content {
        let name: String
        let html: String
    }

    static let separator = "\u{1F}"   // séparateur d'unités ASCII, absent des titres

    /// Exécute un script ; les arguments arrivent dans `argv` (pas d'échappement à gérer).
    @discardableResult
    static func run(_ script: String, _ args: [String] = []) throws -> String {
        let out = try Shell.run("/usr/bin/osascript", ["-e", script] + args)
        guard out.status == 0 else {
            let t = out.text
            if t.contains("-1743") || t.contains("Not authorized") || t.contains("pas autorisé") {
                throw PDFToolError.commandFailed("Toolbox n'a pas le droit de piloter Notes. Autorise-le dans Réglages Système → Confidentialité et sécurité → Automatisation → Toolbox → Notes.")
            }
            if t.contains("-1728") || t.contains("Can’t get note") || t.contains("Impossible d’obtenir") {
                throw PDFToolError.commandFailed("note introuvable (supprimée ?)")
            }
            throw PDFToolError.commandFailed("Notes : " + String(t.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))
        }
        return out.text.trimmingCharacters(in: .newlines)
    }

    /// Les notes les plus récentes (Notes les renvoie de la plus récemment modifiée à la plus ancienne).
    static func recent(limit: Int = 40) throws -> [Summary] {
        let script = """
        on run argv
            set sep to item 1 of argv
            tell application "Notes"
                set theIds to id of every note
                set theNames to name of every note
            end tell
            set n to count of theIds
            if n > \(limit) then set n to \(limit)
            set out to ""
            repeat with i from 1 to n
                set out to out & (item i of theIds) & sep & (item i of theNames) & linefeed
            end repeat
            return out
        end run
        """
        return try run(script, [separator]).split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            return Summary(id: parts[0], name: parts[1].isEmpty ? "(sans titre)" : parts[1])
        }
    }

    static func read(id: String) throws -> Content {
        let script = """
        on run argv
            tell application "Notes"
                set n to note id (item 1 of argv)
                return (name of n) & (item 2 of argv) & (body of n)
            end tell
        end run
        """
        let out = try run(script, [id, separator])
        let parts = out.components(separatedBy: separator)
        return Content(name: parts.first ?? "", html: parts.dropFirst().joined(separator: separator))
    }

    /// Crée une note (dossier par défaut) ; la première ligne devient son titre. Renvoie son identifiant.
    static func create(_ text: String) throws -> String {
        let script = """
        on run argv
            tell application "Notes"
                try
                    set n to make new note at default folder of default account with properties {body:(item 1 of argv)}
                on error
                    set n to make new note at folder 1 of default account with properties {body:(item 1 of argv)}
                end try
                return id of n
            end tell
        end run
        """
        return try run(script, [html(text, titleFirstLine: true)])
    }

    /// Ajoute du texte à la fin d'une note.
    static func append(_ text: String, to id: String) throws {
        let script = """
        on run argv
            tell application "Notes"
                set n to note id (item 1 of argv)
                set body of n to (body of n) & (item 2 of argv)
            end tell
        end run
        """
        try run(script, [id, html(text, titleFirstLine: false)])
    }

    static func show(id: String) {
        let script = """
        on run argv
            tell application "Notes"
                show note id (item 1 of argv)
                activate
            end tell
        end run
        """
        DispatchQueue.global(qos: .userInitiated).async { _ = try? run(script, [id]) }
    }

    static func openApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
    }

    // MARK: HTML ↔ texte

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func html(_ text: String, titleFirstLine: Bool) -> String {
        let lines = text.components(separatedBy: .newlines)
        return lines.enumerated().map { i, line in
            let content = line.isEmpty ? "<br>" : escape(line)
            return (i == 0 && titleFirstLine) ? "<div><h1>\(content)</h1></div>" : "<div>\(content)</div>"
        }.joined()
    }

    /// Texte simple à partir du HTML de Notes (listes et cases à cocher comprises).
    static func plainText(_ html: String) -> String {
        var s = html
        let rules: [(String, String)] = [
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(div|p|h[1-6]|li|tr)>"#, "\n"),
            (#"(?i)<li[^>]*>"#, "• "),
            (#"<[^>]+>"#, ""),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&amp;": "&"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
