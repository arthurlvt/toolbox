import Foundation
import PDFKit

public enum CompressionLevel: String, CaseIterable, Identifiable {
    case strong, balanced, light

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strong: return "Forte — écran (72 dpi)"
        case .balanced: return "Équilibrée — lecture (150 dpi)"
        case .light: return "Légère — impression (300 dpi)"
        }
    }

    var ghostscriptPreset: String {
        switch self {
        case .strong: return "/screen"
        case .balanced: return "/ebook"
        case .light: return "/printer"
        }
    }
}

public struct CompressionResult {
    public let input: URL
    public let output: URL
    public let before: Int64
    public let after: Int64
    public let method: String
    /// Vrai si la compression n'a rien gagné : la sortie est alors une copie de l'original.
    public let keptOriginal: Bool

    public var savedPercent: Int {
        guard before > 0 else { return 0 }
        return Int((Double(before - after) / Double(before) * 100).rounded())
    }

    public var summary: String {
        if keptOriginal { return "déjà optimisé (\(FileUtils.formatBytes(before)))" }
        return "\(FileUtils.formatBytes(before)) → \(FileUtils.formatBytes(after)) (−\(savedPercent) %)"
    }
}

/// Compression : Ghostscript s'il est installé (bien meilleur résultat),
/// sinon PDFKit (recompression JPEG des images).
public enum Compressor {
    public static var ghostscriptPath: String? { Shell.which("gs") }

    public static func compress(_ input: URL, level: CompressionLevel, to output: URL) throws -> CompressionResult {
        let before = FileUtils.size(input)
        let tmp = FileUtils.temporarySibling(of: output)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let method: String
        if let gs = ghostscriptPath {
            let r = try Shell.run(gs, [
                "-sDEVICE=pdfwrite",
                "-dCompatibilityLevel=1.5",
                "-dPDFSETTINGS=\(level.ghostscriptPreset)",
                "-dDetectDuplicateImages=true",
                "-dCompressFonts=true",
                "-dNOPAUSE", "-dQUIET", "-dBATCH", "-dSAFER",
                "-sOutputFile=\(tmp.path)",
                input.path,
            ])
            guard r.status == 0 else { throw PDFToolError.commandFailed(r.text) }
            method = "Ghostscript"
        } else {
            let doc = try PDFOps.open(input)
            var options: [PDFDocumentWriteOption: Any] = [:]
            if #available(macOS 14.0, *) {
                options[.saveImagesAsJPEGOption] = true
                if level != .light { options[.optimizeImagesForScreenOption] = true }
            }
            guard doc.write(to: tmp, withOptions: options) else { throw PDFToolError.cannotWrite(output) }
            method = "PDFKit"
        }

        let after = FileUtils.size(tmp)
        let keep = after == 0 || after >= before
        if keep {
            if input.standardizedFileURL != output.standardizedFileURL {
                let copy = FileUtils.temporarySibling(of: output)
                try FileManager.default.copyItem(at: input, to: copy)
                try FileUtils.replace(output, with: copy)
            }
        } else {
            try FileUtils.replace(output, with: tmp)
        }
        return CompressionResult(input: input, output: output, before: before,
                                 after: keep ? before : after, method: method, keptOriginal: keep)
    }
}
