import AppKit
import ConversionKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class PopoverModel {
    /// Files waiting for a choice of action. Empty shows the job list.
    var pendingFiles: [URL] = []
    var isDropTargeted = false
    var hoveredJob: ConversionJob.ID?
}

/// The keyboard-friendly way to do everything the wheel does, and the list of what happened.
struct PopoverView: View {
    let queue: JobQueue
    let settings: AppSettings
    @Bindable var model: PopoverModel
    let openSettings: () -> Void
    let chooseFiles: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.pendingFiles.isEmpty {
                jobList
            } else {
                ActionChooser(urls: model.pendingFiles) { action in
                    queue.add(model.pendingFiles, action: action)
                    model.pendingFiles = []
                } cancel: {
                    model.pendingFiles = []
                }
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            loadURLs(from: providers)
            return true
        }
    }

    @ViewBuilder
    private var jobList: some View {
        if queue.jobs.isEmpty {
            VStack(spacing: 8) {
                Image(nsImage: StatusIcon.idle)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(model.isDropTargeted ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(settings.wheelEnabled ? "Hold \(settings.modifier.title) While Dragging a File" : "Drop Files Here")
                    .font(.system(size: 13, weight: .semibold))
                Text(settings.wheelEnabled ? "Formats appear around the pointer. Or drop files here." : "Or choose files, then pick what to do with them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(model.isDropTargeted ? Color.accentColor.opacity(0.1) : .clear)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.jobs) { job in
                        JobRow(job: job, queue: queue, model: model)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 340)
            .background(model.isDropTargeted ? Color.accentColor.opacity(0.1) : .clear)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Choose Files…", action: chooseFiles)
                .keyboardShortcut("o", modifiers: .command)
            Spacer()
            if queue.jobs.contains(where: { !$0.isActive }) {
                Button("Clear") { queue.clearFinished() }
                    .buttonStyle(.borderless)
            }
            Menu {
                Button("Settings…", action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("About \(AppIdentity.name)") {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Button("Quit \(AppIdentity.name)") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
    }

    private func loadURLs(from providers: [NSItemProvider]) {
        let lock = URLCollector()
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = lock.urls
            MainActor.assumeIsolated {
                if !urls.isEmpty { model.pendingFiles = urls }
            }
        }
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    func append(_ url: URL) {
        lock.withLock { stored.append(url) }
    }

    var urls: [URL] {
        lock.withLock { stored }
    }
}

/// Everything the wheel offers, as ordinary buttons.
private struct ActionChooser: View {
    let urls: [URL]
    let choose: (ConversionAction) -> Void
    let cancel: () -> Void

    /// Three to a row leaves every label the room it needs, the longest included.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var actions: [ConversionAction] {
        ConversionCatalog.actions(for: urls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FileIconView(urls: urls)
                    .frame(width: 28, height: 28)
                Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            if actions.isEmpty {
                Text(urls.count == 1 ? "This file type is not supported." : "These files have no action in common. Try them in smaller groups.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(actions, id: \.self) { action in
                        Button {
                            choose(action)
                        } label: {
                            Text(action.chipLabel)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .accessibilityLabel(action.title)
                        .help(action.title)
                    }
                }
            }
        }
        .padding(14)
    }
}

private struct JobRow: View {
    let job: ConversionJob
    let queue: JobQueue
    let model: PopoverModel

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(urls: [job.input])
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.input.lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 4)
            trailingButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(model.hoveredJob == job.id ? Color.primary.opacity(0.06) : .clear)
        .onHover { isInside in
            if isInside {
                model.hoveredJob = job.id
            } else if model.hoveredJob == job.id {
                model.hoveredJob = nil
            }
        }
        .onTapGesture(count: 2) { reveal() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detail: some View {
        switch job.state {
        case .waiting:
            Text("Waiting")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .running(let progress):
            ProgressView(value: progress)
                .controlSize(.small)
                .accessibilityLabel(job.action.progressTitle)
        case .finished(let output, let note):
            Text(note ?? output.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(note == nil ? 1 : 2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(note ?? output.path)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .help(message)
        case .cancelled:
            Text("Cancelled")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch job.state {
        case .waiting, .running:
            iconButton("xmark.circle", label: "Cancel") { queue.cancel(job) }
        case .finished:
            iconButton("magnifyingglass.circle", label: "Show in Finder", action: reveal)
        case .failed, .cancelled:
            iconButton("arrow.clockwise.circle", label: "Try Again") { queue.retry(job) }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func reveal() {
        if case .finished(let output, _) = job.state {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
    }
}
