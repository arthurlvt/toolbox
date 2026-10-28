import Foundation

/// Lance des outils externes (Ghostscript, latexmk, pdflatex…).
/// Une appli lancée depuis le Finder n'hérite pas du PATH du terminal :
/// on ajoute donc les emplacements Homebrew et MacTeX à la main.
public enum Shell {
    public static let extraPaths = [
        "/Library/TeX/texbin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        var paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in extraPaths where !paths.contains(p) { paths.append(p) }
        env["PATH"] = paths.joined(separator: ":")
        return env
    }

    public static func which(_ name: String) -> String? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let full = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    public struct Output {
        public let status: Int32
        public let text: String
    }

    private final class Buffer {
        var data = Data()
        let lock = NSLock()
    }

    /// Exécute une commande de façon synchrone (à appeler hors du thread principal).
    /// `onOutput` reçoit la sortie au fil de l'eau.
    @discardableResult
    public static func run(_ executable: String,
                           _ arguments: [String],
                           in directory: URL? = nil,
                           extraEnvironment: [String: String] = [:],
                           onOutput: ((String) -> Void)? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = environment
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env
        if let directory = directory { process.currentDirectoryURL = directory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice // LaTeX ne doit jamais attendre une saisie

        let buffer = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.lock.lock()
            buffer.data.append(chunk)
            buffer.lock.unlock()
            onOutput?(String(decoding: chunk, as: UTF8.self))
        }

        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        buffer.lock.lock()
        if !rest.isEmpty {
            buffer.data.append(rest)
            onOutput?(String(decoding: rest, as: UTF8.self))
        }
        let all = buffer.data
        buffer.lock.unlock()

        return Output(status: process.terminationStatus, text: String(decoding: all, as: UTF8.self))
    }
}
