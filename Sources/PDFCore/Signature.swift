import Foundation
import PDFKit
import CoreGraphics

/// Une signature posée sur une page : rectangle en points, origine en HAUT à gauche de la page
/// telle qu'elle s'affiche (rotation comprise).
public struct SignaturePlacement {
    public let page: Int          // 0…
    public let rect: CGRect

    public init(page: Int, rect: CGRect) {
        self.page = page
        self.rect = rect
    }
}

public enum Signature {
    /// Écrit une copie du PDF avec l'image de signature posée aux endroits indiqués.
    /// Le texte des pages reste du texte (les pages sont recopiées en vectoriel).
    public static func apply(_ input: URL, image: CGImage, placements: [SignaturePlacement], to output: URL) throws {
        let doc = try PDFOps.open(input)
        let byPage = Dictionary(grouping: placements, by: { $0.page })
        var info: [String: String] = [:]
        if let attrs = doc.documentAttributes {
            if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { info["title"] = t }
            if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { info["author"] = a }
        }
        try PageDrawing.rewrite(to: output, info: info) { writer in
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let size = PageDrawing.displaySize(page)
                writer.page(size: size) { ctx in
                    PageDrawing.drawUpright(page, in: ctx)
                    for p in byPage[i] ?? [] {
                        // haut-gauche (affichage) → bas-gauche (PDF)
                        let r = CGRect(x: p.rect.minX, y: size.height - p.rect.maxY, width: p.rect.width, height: p.rect.height)
                        ctx.interpolationQuality = .high
                        ctx.draw(image, in: r)
                    }
                }
            }
        }
    }
}
