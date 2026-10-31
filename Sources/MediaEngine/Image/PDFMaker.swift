import ConversionCore
import CoreGraphics
import Foundation
import ImageIO

/// Puts images into a PDF, one per page, each page as large as its image.
enum PDFMaker {
    /// PDF viewers stop at 200 inches, which is 14400 points.
    private static let longestPageEdge = 14_400.0

    static func make(from inputs: [URL]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConversionError("The PDF could not be created.")
        }
        for input in inputs {
            try Task.checkCancellation()
            let source: ImageSource
            do {
                source = try ImageSource(url: input)
            } catch {
                throw ConversionError("\(input.lastPathComponent) is not an image that can be read.")
            }
            let index = source.primaryIndex
            let image = try ImageRenderer.render(
                source, index: index, applyingOrientation: source.orientation(at: index) != .up, maxPixelSize: nil
            )
            var page = pageBox(for: image, dpi: source.dpi(at: index) ?? 72)
            context.beginPage(mediaBox: &page)
            context.draw(image, in: page)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Page size in points. A 300 dpi scan is a normal sized page, a 72 dpi photo is a big one.
    static func pageBox(for image: CGImage, dpi: Double) -> CGRect {
        var width = Double(image.width) * 72 / dpi
        var height = Double(image.height) * 72 / dpi
        let longest = max(width, height)
        if longest > longestPageEdge {
            let shrink = longestPageEdge / longest
            width *= shrink
            height *= shrink
        }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}
