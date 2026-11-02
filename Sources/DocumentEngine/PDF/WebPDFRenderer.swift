import AppKit
import ConversionCore
import Foundation
import WebKit

/// Lays out HTML with WebKit and prints it to a paginated PDF, off screen.
/// Remote requests are blocked: conversion never touches the network.
@MainActor
public final class WebPDFRenderer: NSObject {
    public static func render(html: String, baseURL: URL? = nil, paper: PaperSize = .a4, to output: URL) async throws {
        let renderer = WebPDFRenderer(paper: paper)
        try await renderer.load { $0.loadHTMLString(html, baseURL: baseURL) }
        try await renderer.printPDF(to: output)
    }

    /// Prints a local HTML file, with access to the resources in its folder.
    public static func render(file: URL, paper: PaperSize = .a4, to output: URL) async throws {
        let renderer = WebPDFRenderer(paper: paper)
        try await renderer.load { $0.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()) }
        try await renderer.printPDF(to: output)
    }

    /// Prints a slide deck as the system previews it, one slide to a page of the slide's own
    /// shape. `slideSize` is the size of a slide in the preview's CSS pixels.
    public static func render(slides file: URL, slideSize: CGSize, to output: URL) async throws {
        let page = NSSize(width: slideSize.width / printLayoutScale, height: slideSize.height / printLayoutScale)
        let renderer = WebPDFRenderer(pageSize: page, margin: 0)
        try await renderer.load { $0.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()) }
        await renderer.run(slideStyle)
        try await renderer.printPDF(to: output)
    }

    /// The preview sets slides apart with gaps and shadows for the screen. On paper each one fills its page.
    private static let slideStyle = """
        const style = document.createElement('style');
        style.textContent = 'html, body { margin: 0 !important; padding: 0 !important; background: #fff !important; }'
          + ' div.slide { margin: 0 !important; box-shadow: none !important; break-after: page; }'
          + ' div.loading-slide { display: none !important; }';
        document.head.appendChild(style);
        true;
        """

    private let margin: CGFloat
    private let pageSize: NSSize

    private convenience init(paper: PaperSize) {
        self.init(pageSize: NSSize(width: paper.points.width, height: paper.points.height), margin: 56)
    }

    private init(pageSize: NSSize, margin: CGFloat) {
        self.pageSize = pageSize
        self.margin = margin
        super.init()
    }

    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadContinuation: CheckedContinuation<Void, any Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    private func load(_ start: (WKWebView) -> Void) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Table headers, code blocks and highlights have their fills on paper too.
        configuration.preferences.shouldPrintBackgrounds = true
        if let rules = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "block-remote",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) {
            configuration.userContentController.add(rules)
        }
        let contentWidth = pageSize.width - margin * 2
        let frame = NSRect(x: 0, y: 0, width: contentWidth, height: pageSize.height)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
        view.mediaType = "print"
        webView = view
        // Printing needs a view in a window, which never has to be shown.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        window.isReleasedWhenClosed = false
        self.window = window

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            start(view)
        }
    }

    /// WebKit lays a page out this much larger than the paper and scales it down.
    private static let printLayoutScale: CGFloat = 1.25

    /// WebKit does not repeat a table's header on printed pages and can cut a tall row in two,
    /// and it lets a heading end a page apart from its table. So a heading is tied to the table
    /// below it, and a table too long for one page becomes one table per page, each with the
    /// header and the same column widths. A table that does not fit where it is expected moves
    /// whole to the next page, so a wrong guess about the space left only costs white space.
    private static let tableSplitter = """
        (function (pageWidth, pageHeight) {
          const usable = pageHeight * 0.97;
          const top = (element) => element.getBoundingClientRect().top;
          const height = (element) => element.getBoundingClientRect().height;
          document.body.style.width = pageWidth + 'px';
          let origin = 0;
          for (const wrapper of document.querySelectorAll('.table-scroll, .page-break')) {
            if (wrapper.classList.contains('page-break')) { origin = top(wrapper); continue; }
            if (wrapper.parentElement.closest('.table-scroll')) continue;

            let block = wrapper;
            let heading = wrapper.previousElementSibling;
            if (heading && /^H[1-6]$/.test(heading.tagName)) {
              block = document.createElement('div');
              block.style.breakInside = 'avoid';
              wrapper.before(block);
              const headings = [];
              while (heading && /^H[1-6]$/.test(heading.tagName)) {
                headings.unshift(heading);
                heading = heading.previousElementSibling;
              }
              block.append(...headings, wrapper);
            }

            const used = (top(block) - origin) % pageHeight;
            if (height(block) <= usable) {
              if (used + height(block) > pageHeight) origin = top(block);
              continue;
            }
            const table = wrapper.querySelector('table');
            const head = table.tHead;
            const body = table.tBodies[0];
            if (!body) continue;

            // Any row without spans shows the column widths. The fullest one shows all of them.
            const plainRows = [...table.rows].filter((row) => [...row.cells].every((cell) => cell.colSpan === 1 && cell.rowSpan === 1));
            if (!plainRows.length) continue;
            const fullest = plainRows.reduce((best, row) => (row.cells.length > best.cells.length ? row : best));
            const columns = document.createElement('colgroup');
            for (const cell of fullest.cells) {
              const column = document.createElement('col');
              column.style.width = cell.getBoundingClientRect().width + 'px';
              columns.append(column);
            }

            // Rows joined by a row span stay on one page.
            const groups = [];
            let spanEnd = -1;
            [...body.rows].forEach((row, index) => {
              if (index > spanEnd) groups.push([]);
              groups[groups.length - 1].push(row);
              for (const cell of row.cells) spanEnd = Math.max(spanEnd, index + cell.rowSpan - 1);
            });

            const headHeight = head ? height(head) : 0;
            // Above the first rows: the heading tied to the table, its caption and its header.
            const firstHead = top(body) - top(block);
            let room = usable - used - firstHead;
            let current = [];
            const pages = [current];
            for (const group of groups) {
              const needed = group.reduce((sum, row) => sum + height(row), 0);
              if (needed > room) {
                if (current.length) {
                  current = [];
                  pages.push(current);
                  room = usable - headHeight;
                } else {
                  // The first part moves to a new page with its heading, so it has to fit
                  // there with the heading. Some WebKit versions split a taller block.
                  room = usable - firstHead;
                }
              }
              current.push(...group);
              room -= needed;
            }

            table.style.tableLayout = 'fixed';
            table.insertBefore(columns, head || body);
            let previous = block;
            for (const rows of pages.slice(1)) {
              const nextBody = body.cloneNode(false);
              nextBody.append(...rows);
              const nextTable = table.cloneNode(false);
              nextTable.append(columns.cloneNode(true));
              if (head) nextTable.append(head.cloneNode(true));
              nextTable.append(nextBody);
              const nextWrapper = wrapper.cloneNode(false);
              nextWrapper.style.breakBefore = 'page';
              nextWrapper.style.marginTop = '0';
              nextWrapper.append(nextTable);
              previous.after(nextWrapper);
              previous = nextWrapper;
            }
            origin = top(previous);
          }
          document.body.style.width = '';
          return true;
        })
        """

    private func repeatTableHeaders() async {
        let width = (pageSize.width - margin * 2) * Self.printLayoutScale
        let height = (pageSize.height - margin * 2) * Self.printLayoutScale
        await run("\(Self.tableSplitter)(\(width), \(height))")
    }

    private func run(_ script: String) async {
        guard let webView else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(script) { _, _ in
                continuation.resume()
            }
        }
    }

    private func printPDF(to output: URL) async throws {
        await repeatTableHeaders()
        guard let webView, let window else { return }
        let info = NSPrintInfo()
        info.paperSize = pageSize
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds

        let succeeded = await withCheckedContinuation { continuation in
            printContinuation = continuation
            operation.runModal(
                for: window,
                delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
        window.close()
        self.webView = nil
        self.window = nil
        guard succeeded, FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError("The PDF could not be created.")
        }
        // Content that ends just past a page boundary, such as the page box of a Word preview,
        // leaves an empty page behind.
        try PDFTools.removeTrailingBlankPages(of: output)
    }

    /// AppKit calls this on a thread of its own when the job runs in the background.
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            printContinuation?.resume(returning: success)
            printContinuation = nil
        }
    }
}

extension WebPDFRenderer: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadContinuation?.resume(throwing: ConversionError("The document could not be laid out."))
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loadContinuation?.resume(throwing: ConversionError("The document could not be laid out."))
        loadContinuation = nil
    }
}
