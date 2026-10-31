import AppKit
import ConversionCore
import Foundation
import WebKit

/// Lays out HTML with WebKit and prints it to a paginated A4 PDF, off screen.
/// Remote requests are blocked: conversion never touches the network.
@MainActor
public final class WebPDFRenderer: NSObject {
    public static func render(html: String, baseURL: URL? = nil, to output: URL) async throws {
        let renderer = WebPDFRenderer()
        try await renderer.load { $0.loadHTMLString(html, baseURL: baseURL) }
        try await renderer.printPDF(to: output)
    }

    /// Prints a local HTML file, with access to the resources in its folder.
    public static func render(file: URL, to output: URL) async throws {
        let renderer = WebPDFRenderer()
        try await renderer.load { $0.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()) }
        try await renderer.printPDF(to: output)
    }

    private static let pageSize = NSSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 56

    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadContinuation: CheckedContinuation<Void, any Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    private func load(_ start: (WKWebView) -> Void) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let rules = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "block-remote",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) {
            configuration.userContentController.add(rules)
        }
        let contentWidth = Self.pageSize.width - Self.margin * 2
        let frame = NSRect(x: 0, y: 0, width: contentWidth, height: Self.pageSize.height)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
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

    private func printPDF(to output: URL) async throws {
        guard let webView, let window else { return }
        let info = NSPrintInfo()
        info.paperSize = Self.pageSize
        info.topMargin = Self.margin
        info.bottomMargin = Self.margin
        info.leftMargin = Self.margin
        info.rightMargin = Self.margin
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
