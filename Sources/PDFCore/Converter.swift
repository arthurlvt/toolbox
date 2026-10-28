import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"

    public var id: String { rawValue }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
    public var utType: UTType { self == .png ? .png : .jpeg }
}

public enum PageSize: String, CaseIterable, Identifiable {
    case a4 = "A4 (portrait/paysage auto)"
    case original = "Taille de l'image"

    public var id: String { rawValue }
}

public enum Converter {

    // MARK: Images → PDF

    @discardableResult
    public static func imagesToPDF(_ images: [URL], pageSize: PageSize, to output: URL) throws -> Int {
        guard !images.isEmpty else { throw PDFToolError.noInput }
        let doc = PDFDocument()
        for url in images {
            guard let image = NSImage(contentsOf: url), image.isValid else {
                throw PDFToolError.imageUnreadable(url)
            }
            let page: PDFPage?
            switch pageSize {
            case .original:
                page = PDFPage(image: image)
            case .a4:
                let landscape = image.size.width > image.size.height
                let box = landscape ? CGRect(x: 0, y: 0, width: 842, height: 595)
                                    : CGRect(x: 0, y: 0, width: 595, height: 842)
                page = PDFPage(image: image, options: [
                    .mediaBox: NSValue(rect: box),
                    .compressionQuality: 0.85,
                ])
            }
            guard let p = page else { throw PDFToolError.imageUnreadable(url) }
            doc.insert(p, at: doc.pageCount)
        }
        try PDFOps.save(doc, to: output)
        return doc.pageCount
    }

    // MARK: PDF → images

    public static func pdfToImages(_ input: URL, format: ImageFormat, dpi: Double,
                                   pages text: String? = nil, into folder: URL) throws -> [URL] {
        let doc = try PDFOps.open(input)
        let indices: [Int]
        if let text = text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            indices = try PageRanges.indices(text, pageCount: doc.pageCount)
        } else {
            indices = Array(0..<doc.pageCount)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = input.deletingPathExtension().lastPathComponent
        let width = String(doc.pageCount).count
        var outputs: [URL] = []
        for i in indices {
            guard let page = doc.page(at: i), let image = render(page, dpi: dpi) else { continue }
            let n = String(i + 1)
            let num = String(repeating: "0", count: max(0, width - n.count)) + n
            let url = FileUtils.unique(folder.appendingPathComponent("\(base)_p\(num).\(format.fileExtension)"))
            try write(image, to: url, format: format, dpi: dpi)
            outputs.append(url)
        }
        return outputs
    }

    /// Rend une page en bitmap à la résolution voulue (rotation de la page respectée).
    public static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let scale = CGFloat(dpi / 72)
        let size = PageDrawing.displaySize(page)
        let w = Int((size.width * scale).rounded())
        let h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        PageDrawing.drawUpright(page, in: ctx)
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat, dpi: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw PDFToolError.cannotWrite(url)
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PDFToolError.cannotWrite(url) }
    }

    // MARK: PDF → texte

    @discardableResult
    public static func pdfToText(_ input: URL, to output: URL) throws -> Int {
        let doc = try PDFOps.open(input)
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            parts.append("──── Page \(i + 1) ────\n\(text)")
        }
        let all = parts.joined(separator: "\n\n")
        do {
            try all.write(to: output, atomically: true, encoding: .utf8)
        } catch {
            throw PDFToolError.cannotWrite(output)
        }
        return all.count
    }
}
