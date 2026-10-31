import ConversionCore
import Foundation

/// Apple Pages documents, read and written without Pages.
public enum PagesFormat {
    /// Modern .pages (ZIP with Index/*.iwa, also directory packages). Paragraphs from the body text storage, headings when the paragraph style name says so (Title, Heading...), lists when feasible, images from Data/, table cell text when feasible. Falls back to whatever text can be recovered; throws ConversionError only if nothing can be read.
    public static func read(_ url: URL) throws -> RichDocument {
        try PagesReader(url: url).read()
    }

    /// Editable .pages generated WITHOUT Pages.app, from a bundled blank template, by patching the IWA body text storage. Paragraph breaks kept, headings mapped to template heading styles when feasible, otherwise plain paragraphs. Images and tables may be flattened to text in v1 (document that).
    ///
    /// In this version a table becomes one tab separated paragraph per row and an image
    /// becomes its description, if it has one. Lists, page breaks, bold, italic, underline and
    /// strikethrough are kept (one effect per run, bold first); colours, fonts, alignment and
    /// links are not. The output is checked through the Quick Look engine, not in Pages itself.
    public static func write(_ document: RichDocument, to url: URL) throws {
        try PagesWriter(document).write(to: url)
    }
}
