import ConversionCore
import Darwin
import Foundation
import PDFKit

/// Renders Office and iWork files with macOS's own Quick Look engine, which needs neither
/// Office nor iWork. It runs `qlmanage -p -o`, whose dump folder holds `Preview.html` and
/// attachments. Pages gives one PDF per page and Numbers one per sheet, joined here into a
/// single PDF. XLSX, DOCX and PPTX give HTML, with one HTML page per sheet for a workbook,
/// stacked here into one page.
public enum SystemPreview {
    public enum Rendering: Sendable {
        case pdf(URL)
        case html(index: URL)
    }

    /// Renders with macOS's own Quick Look engine by running `/usr/bin/qlmanage -p -o <tempdir> <file>`. Throws ConversionError if no usable output or after a 60 second timeout. Must not show any window. Caller removes `folder`.
    public static func render(_ url: URL) async throws -> (rendering: Rendering, folder: URL) {
        try await render(url, timeout: 60)
    }

    static func render(_ url: URL, timeout: TimeInterval) async throws -> (rendering: Rendering, folder: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError("The file could not be found.")
        }
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemPreview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await QuickLookProcess.run(file: url, outputFolder: folder, timeout: timeout)
            return (try rendering(in: folder), folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Finds the usable output in a dump folder. A PDF attachment alone proves nothing, since an
    /// Office page can embed one as a picture. The PDFs are the document only when the pages
    /// around them hold no text of their own.
    static func rendering(in folder: URL) throws -> Rendering {
        let failure = ConversionError("macOS could not preview this file.")
        guard let name = try? FileManager.default.contentsOfDirectory(atPath: folder.path).first(where: { $0.hasSuffix(".qlpreview") }) else {
            throw failure
        }
        let dump = folder.appendingPathComponent(name)
        let index = dump.appendingPathComponent("Preview.html")
        guard let html = try? String(contentsOf: index, encoding: .utf8) else { throw failure }

        // A Numbers document or a workbook has one HTML page per sheet behind the main page.
        let sheets = html.matches(of: /Attachment[0-9]+\.html/).map { String($0.output) }.uniqued()
        let pages = sheets.isEmpty ? [html] : sheets.compactMap { try? String(contentsOf: dump.appendingPathComponent($0), encoding: .utf8) }

        if pages.allSatisfy({ bodyText($0).isEmpty }) {
            let pdfs = pagePDFs(in: dump, mentionedIn: pages)
            if !pdfs.isEmpty { return .pdf(try joined(pdfs, in: folder)) }
        }
        if let stacked = try stackedSheets(from: html, in: dump) {
            return .html(index: stacked)
        }
        guard !bodyText(html).isEmpty || html.contains(/(?i)<(img|svg|canvas|object|embed)\b/) else { throw failure }
        return .html(index: index)
    }

    /// A workbook with several sheets previews as tabs over an iframe, and anything printing
    /// that page would only get the first sheet. This stacks all sheets in one `Document.html`
    /// next to the original. Each sheet's styles reuse the same class names, hence the scopes.
    private static func stackedSheets(from html: String, in dump: URL) throws -> URL? {
        let tabs = html.matches(of: /<div class="TabHeader">(.*?)<\/div>\s*<a href="(Attachment[0-9]+\.html)">/)
        guard !tabs.isEmpty else { return nil }

        var links: [String] = []
        var styles = ""
        var body = ""
        for (index, tab) in tabs.enumerated() {
            let sheet = try String(contentsOf: dump.appendingPathComponent(String(tab.output.2)), encoding: .utf8)
            for link in sheet.matches(of: /<link [^>]*>/) where !links.contains(String(link.output)) {
                links.append(String(link.output))
            }
            for style in sheet.matches(of: /(?s)<style[^>]*>(.*?)<\/style>/) {
                styles += "@scope (#sheet\(index)) {\n\(style.output.1)}\n"
            }
            let content = sheet.firstMatch(of: /(?s)<body[^>]*>(.*)<\/body>/)?.output.1 ?? ""
            body += "<section id=\"sheet\(index)\"><h2>\(tab.output.1)</h2>\(content)</section>\n"
        }
        let document = """
            <!DOCTYPE html><html><head><meta charset="utf-8">\(links.joined())<style>\(styles)</style></head><body>
            \(body)</body></html>
            """
        let url = dump.appendingPathComponent("Document.html")
        try document.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The page PDFs in display order. Attachment numbers do not follow the page order, so the
    /// order comes from the HTML. Any PDF nothing mentions comes last, by number.
    private static func pagePDFs(in dump: URL, mentionedIn pages: [String]) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dump.path)) ?? []
        let attachments = Set(names.filter { $0.hasPrefix("Attachment") && $0.hasSuffix(".pdf") })
        let mentioned = pages.flatMap { $0.matches(of: /Attachment[0-9]+\.pdf/).map { String($0.output) } }.uniqued()
        let ordered = mentioned.filter(attachments.contains) + attachments.subtracting(mentioned).sorted { first, second in
            first.compare(second, options: .numeric) == .orderedAscending
        }
        return ordered.map { dump.appendingPathComponent($0) }
    }

    private static func joined(_ pages: [URL], in folder: URL) throws -> URL {
        if pages.count == 1 { return pages[0] }
        let output = PDFDocument()
        for page in pages {
            guard let document = PDFDocument(url: page) else { continue }
            for index in 0..<document.pageCount {
                if let copy = document.page(at: index)?.copy() as? PDFPage {
                    output.insert(copy, at: output.pageCount)
                }
            }
        }
        let url = folder.appendingPathComponent("Document.pdf")
        guard output.pageCount > 0, output.write(to: url) else {
            throw ConversionError("macOS could not preview this file.")
        }
        return url
    }

    /// What a page's body says, without its markup. Whitespace only counts as nothing.
    private static func bodyText(_ html: String) -> String {
        guard let body = html.firstMatch(of: /(?is)<body[^>]*>(.*)<\/body>/)?.output.1 else { return "" }
        return body
            .replacing(/(?is)<(script|style)\b.*?<\/\1>/, with: "")
            .replacing(/<[^>]*>/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array where Element: Hashable {
    /// The elements in order, each once.
    fileprivate func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

/// `qlmanage` wrapped for async use, with a timeout and cancellation.
private final class QuickLookProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var timedOut = false

    static func run(file: URL, outputFolder: URL, timeout: TimeInterval) async throws {
        let runner = QuickLookProcess()
        try await runner.run(file: file, outputFolder: outputFolder, timeout: timeout)
    }

    private func run(file: URL, outputFolder: URL, timeout: TimeInterval) async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", "-o", outputFolder.path, file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { [self] _ in
                    lock.lock()
                    let didTimeOut = timedOut
                    lock.unlock()
                    if didTimeOut {
                        continuation.resume(throwing: ConversionError("macOS took too long to preview this file."))
                    } else {
                        continuation.resume()
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ConversionError("macOS could not preview this file."))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    stop(markTimedOut: true)
                }
            }
        } onCancel: {
            stop(markTimedOut: false)
        }
        try Task.checkCancellation()
    }

    private func stop(markTimedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        if markTimedOut { timedOut = true }
        process.terminate()
        // qlmanage can sit in a hung XPC call and ignore SIGTERM.
        let identifier = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { kill(identifier, SIGKILL) }
        }
    }
}
