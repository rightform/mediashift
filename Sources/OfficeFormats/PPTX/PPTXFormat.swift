import ConversionCore
import Foundation

/// PowerPoint presentations.
public enum PPTXFormat {
    /// Per slide in presentation order: title as `.heading(level: 1)`, body as paragraphs and lists (keep nesting and bold/italic/colour when simple), tables, images. `.pageBreak` between slides. Skips master/layout placeholder text.
    public static func read(_ url: URL) throws -> RichDocument {
        try PPTXReader(package: ZipPackage(url: url, formatName: "PPTX")).read()
    }

    /// New slide at each `.pageBreak` and each heading of level 1 or 2. Title placeholder, bullets, tables, images. Splits overflowing body text onto continuation slides. 16:9.
    public static func write(_ document: RichDocument, to url: URL) throws {
        var deck = PPTXDeck(title: document.title, author: document.author)
        for slide in try PPTXPaginator.slides(for: document, media: deck.media) {
            deck.add(slide)
        }
        try ZipWriter.write(deck.parts(), to: url)
    }

    /// One full-bleed image per slide; slide size follows the first image's aspect ratio. Used for PDF to PPTX.
    public static func writeSlides(images: [ImageAsset], to url: URL) throws {
        guard !images.isEmpty else {
            throw ConversionError("There are no images to put on slides.")
        }
        var prepared: [(ImageAsset, PreparedImage)] = []
        for image in images {
            guard let ready = ImageSupport.prepare(image, allowedExtensions: PPTXDeck.embeddableImages) else {
                throw ConversionError("One of the images could not be read.")
            }
            prepared.append((image, ready))
        }

        let aspect = ImageSupport.naturalSize(of: prepared[0].0, prepared[0].1)
        var deck = PPTXDeck(title: nil, author: nil, slideSize: PPTXDeck.slideSize(aspectWidth: aspect.width, aspectHeight: aspect.height))
        for (asset, image) in prepared {
            deck.add(PPTXSlide(items: [.fullBleedImage(asset, image)]))
        }
        try ZipWriter.write(deck.parts(), to: url)
    }
}
