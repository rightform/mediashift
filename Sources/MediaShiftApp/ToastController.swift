import AppKit
import ConversionKit
import SwiftUI

/// A small note where the file was dropped: progress, then the result. Feedback stays where
/// the person is looking, needs no permission and asks for nothing. Clicking reveals the result.
@MainActor
final class ToastController {
    private let jobs: [ConversionJob]
    private let location: NSPoint
    private let onClose: () -> Void
    private var panel: NSPanel?
    private var watcher: Task<Void, Never>?

    init(jobs: [ConversionJob], location: NSPoint, onClose: @escaping () -> Void) {
        self.jobs = jobs
        self.location = location
        self.onClose = onClose
    }

    func show() {
        let size = NSSize(width: 320, height: 66)
        var origin = NSPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
            origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: ToastView(jobs: jobs) { [weak self] in self?.reveal() })
        panel.orderFrontRegardless()
        self.panel = panel

        // Stays while work runs, then lingers long enough to read and click.
        watcher = Task { [weak self, jobs] in
            while jobs.contains(where: \.isActive) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            let failed = jobs.contains { if case .failed = $0.state { true } else { false } }
            try? await Task.sleep(for: failed ? .seconds(8) : .seconds(4))
            if !Task.isCancelled { self?.close() }
        }
    }

    #if DEBUG
    var previewWindow: NSWindow? {
        panel
    }
    #endif

    func close() {
        watcher?.cancel()
        panel?.close()
        panel = nil
        onClose()
    }

    private func reveal() {
        let outputs = jobs.compactMap { job -> URL? in
            if case .finished(let output, _) = job.state { return output }
            return nil
        }
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        close()
    }
}

private struct ToastView: View {
    let jobs: [ConversionJob]
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Fixed strength, as on the wheel: this too floats over an unknown desktop.
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private var isRunning: Bool {
        jobs.contains(where: \.isActive)
    }

    private var failures: [String] {
        jobs.compactMap { if case .failed(let message) = $0.state { message } else { nil } }
    }

    private var finished: [(output: URL, note: String?)] {
        jobs.compactMap { if case .finished(let output, let note) = $0.state { (output, note) } else { nil } }
    }

    private var progress: Double {
        let total = jobs.reduce(0.0) { sum, job in
            switch job.state {
            case .running(let progress): sum + progress
            case .waiting: sum
            default: sum + 1
            }
        }
        return total / Double(max(jobs.count, 1))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isRunning {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
        } else if !failures.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        }
    }

    private var title: String {
        if isRunning, let job = jobs.first {
            return jobs.count == 1 ? job.input.lastPathComponent : "\(jobs.count) files"
        }
        if !failures.isEmpty, finished.isEmpty {
            return jobs.count == 1 ? jobs[0].input.lastPathComponent : "\(failures.count) files failed"
        }
        if finished.count == 1, jobs.count == 1 {
            return finished[0].output.lastPathComponent
        }
        return "\(finished.count) of \(jobs.count) files done"
    }

    private var subtitle: String {
        if isRunning, let action = jobs.first?.action { return action.progressTitle }
        if let failure = failures.first { return jobs.count == 1 ? failure : "Details are in the menu bar list" }
        if let note = finished.first?.note { return note }
        return "Click to show in Finder"
    }
}

extension ConversionAction {
    /// The same action, named as work in progress.
    var progressTitle: String {
        switch self {
        case .convert(let format): "Converting to \(format.label)"
        case .compress: "Compressing"
        case .stripMetadata: "Removing metadata"
        }
    }
}
