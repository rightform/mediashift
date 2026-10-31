import AppKit
import ConversionKit
import SwiftUI

/// One toolbar item of the settings window.
enum SettingsPage: String, CaseIterable {
    case general, wheel, output, images, media, documents

    var title: String {
        switch self {
        case .general: "General"
        case .wheel: "Wheel"
        case .output: "Output"
        case .images: "Images"
        case .media: "Video & Audio"
        case .documents: "Documents"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .wheel: "circle.dotted"
        case .output: "square.and.arrow.down"
        case .images: "photo"
        case .media: "film"
        case .documents: "doc.text"
        }
    }
}

@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private var window: NSWindow?
    private var tabs: SettingsTabController?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show(page: SettingsPage? = nil) {
        if window == nil {
            let tabs = SettingsTabController()
            tabs.tabStyle = .toolbar
            // The window follows each page's height, which a cross-fade would only blur.
            tabs.transitionOptions = []
            for page in SettingsPage.allCases {
                let hosting = NSHostingController(rootView: SettingsPageView(page: page, settings: settings))
                hosting.sizingOptions = [.preferredContentSize]
                hosting.title = page.title
                let item = NSTabViewItem(viewController: hosting)
                item.label = page.title
                item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            self.tabs = tabs
            self.window = window
        }
        if let page, let index = SettingsPage.allCases.firstIndex(of: page) {
            tabs?.selectedTabViewItemIndex = index
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    var previewWindow: NSWindow? {
        window
    }
    #endif
}

/// Keeps the window as tall as the page it shows, with its top edge in place. A page taller
/// than the limit or the screen scrolls, the way System Settings does.
private final class SettingsTabController: NSTabViewController {
    private static let tallestContent: CGFloat = 680

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        fitWindow()
    }

    private func fitWindow() {
        guard let window = view.window,
              tabViewItems.indices.contains(selectedTabViewItemIndex),
              let wanted = tabViewItems[selectedTabViewItemIndex].viewController?.preferredContentSize,
              wanted.height > 0 else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let room = (window.screen?.visibleFrame.height ?? .greatestFiniteMagnitude) - chrome
        let height = min(wanted.height, Self.tallestContent, room)
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: wanted.width, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
}

private struct SettingsPageView: View {
    let page: SettingsPage
    @Bindable var settings: AppSettings

    var body: some View {
        ScrollView {
            Form {
                switch page {
                case .general: general
                case .wheel: wheel
                case .output: output
                case .images: images
                case .media: media
                case .documents: documents
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 520)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        Section("Startup") {
            Toggle("Open at login", isOn: Binding(
                get: { settings.launchesAtLogin },
                set: { settings.launchesAtLogin = $0 }
            ))
            if let error = settings.launchAtLoginError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }

        Section("Conversions") {
            LabeledContent("Run at the same time") {
                HStack(spacing: 8) {
                    Text("\(settings.maximumJobs)")
                        .monospacedDigit()
                    Stepper("Run at the same time", value: $settings.maximumJobs, in: 1...8)
                        .labelsHidden()
                }
            }
            note("Video encoding already uses many cores, so a higher number is not always faster.")
        }

        Section("When Finished") {
            Picker("Then", selection: $settings.finishAction) {
                ForEach(FinishAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            Toggle("Play a sound", isOn: $settings.playsSound)
            Toggle("Show progress near the pointer", isOn: $settings.showsToast)
        }

        Section("About") {
            LabeledContent("Privacy", value: "Files stay on this Mac")
            LabeledContent("Version", value: AppIdentity.version)
            LabeledContent("All settings") {
                Button("Restore Defaults…", action: confirmRestore)
            }
        }
    }

    private func confirmRestore() {
        let alert = NSAlert()
        alert.messageText = "Restore all settings to their defaults?"
        alert.informativeText = "Your choices on every page go back to how the app ships. Files are not affected."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { settings.restoreDefaults() }
    }

    // MARK: Wheel

    @ViewBuilder
    private var wheel: some View {
        Section("Gesture") {
            Toggle("Show the wheel while dragging files", isOn: $settings.wheelEnabled)
            Picker("Key", selection: $settings.modifier) {
                ForEach(GestureModifier.allCases) { modifier in
                    Text(modifier.title).tag(modifier)
                }
            }
            .disabled(!settings.wheelEnabled)
            Toggle("Haptic feedback over a target", isOn: $settings.wheelHaptics)
                .disabled(!settings.wheelEnabled)
            note("Press the key at any moment during a drag. A quick tap is enough, and the wheel stays until you let go of the file.")
        }

        Section("On the Wheel") {
            WheelChoices(title: "Documents", actions: formats(of: [.document, .spreadsheet, .presentation]), settings: settings)
            WheelChoices(title: "Images", actions: formats(of: [.image]), settings: settings)
            WheelChoices(title: "Video", actions: formats(of: [.video]), settings: settings)
            WheelChoices(title: "Audio", actions: formats(of: [.audio]), settings: settings)
            WheelChoices(title: "Tools", actions: [.compress, .stripMetadata], settings: settings)
            LabeledContent {
                Button("Show All") { settings.hiddenWheelActions = [] }
                    .disabled(settings.hiddenWheelActions.isEmpty)
            } label: {
                note("What you hide stays available from the menu bar.")
            }
        }
    }

    private func formats(of kinds: [FileKind]) -> [ConversionAction] {
        ConversionCatalog.allTargets.filter { kinds.contains($0.kind) }.map(ConversionAction.convert)
    }

    // MARK: Output

    @ViewBuilder
    private var output: some View {
        Section("Location") {
            LabeledContent("Save to") {
                HStack {
                    Text(settings.outputFolder?.lastPathComponent ?? "Next to the original")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.outputFolder?.path ?? "")
                    Button("Choose…", action: chooseFolder)
                    if settings.outputFolder != nil {
                        Button("Reset") { settings.outputFolder = nil }
                    }
                }
            }
        }

        Section("File Names") {
            TextField("Add to converted files", text: $settings.convertedSuffix, prompt: Text("None"))
            TextField("Add to compressed files", text: $settings.compressedSuffix, prompt: Text("compressed"))
            TextField("Add to cleaned files", text: $settings.cleanedSuffix, prompt: Text("clean"))
            note(namingExample)
        }

        Section("Metadata") {
            Toggle("Remove metadata when converting", isOn: $settings.removesMetadata)
            note("Originals are never changed. A new file gets its own name.")
        }

        Section("Compression") {
            Picker("Strength", selection: $settings.compressionLevel) {
                Text("Light").tag(CompressionLevel.light)
                Text("Balanced").tag(CompressionLevel.balanced)
                Text("Strong").tag(CompressionLevel.strong)
            }
            Toggle("Limit file size", isOn: $settings.usesTargetSize)
            if settings.usesTargetSize {
                LabeledContent("Largest size") {
                    HStack(spacing: 4) {
                        TextField("Size", value: $settings.targetMegabytes, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("MB")
                    }
                }
                note("Applies to images, audio and video.")
            }
        }
    }

    private var namingExample: String {
        let options = settings.conversionOptions
        let converted = "report" + (options.convertedSuffix.map { "-\($0)" } ?? "")
        return "report.docx becomes \(converted).pdf, and photo.jpg becomes photo-\(options.compressedSuffix).jpg."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { settings.outputFolder = panel.url }
    }

    // MARK: Images

    @ViewBuilder
    private var images: some View {
        Section("Quality") {
            Toggle("Set the quality myself", isOn: $settings.usesCustomImageQuality)
            if settings.usesCustomImageQuality {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $settings.imageQualityPercent, in: 30...100, step: 5)
                            .labelsHidden()
                            .frame(width: 200)
                        Text("\(Int(settings.imageQualityPercent))%")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
            note("For JPEG, HEIC, WebP and AVIF. Otherwise each format uses its own recommended value.")
        }

        Section("Size") {
            Picker("Longest side", selection: $settings.imageMaxPixelSize) {
                Text("Original Size").tag(0)
                ForEach([6000, 4000, 3000, 2000, 1600, 1200, 800], id: \.self) { size in
                    Text("\(size) px").tag(size)
                }
            }
            note("Applies when converting. Images are never enlarged.")
        }
    }

    // MARK: Video and audio

    @ViewBuilder
    private var media: some View {
        Section("Video") {
            Picker("Codec", selection: $settings.videoCodec) {
                Text("Keep When Possible").tag(VideoCodecChoice.automatic)
                Text("H.264").tag(VideoCodecChoice.h264)
                Text("HEVC").tag(VideoCodecChoice.hevc)
            }
            Picker("Quality", selection: $settings.videoQuality) {
                Text("Smaller File").tag(VideoQuality.smaller)
                Text("Standard").tag(VideoQuality.standard)
                Text("Higher Quality").tag(VideoQuality.higher)
            }
            Picker("Largest resolution", selection: $settings.maxVideoResolution) {
                Text("Original").tag(0)
                Text("4K (2160p)").tag(2160)
                Text("1440p").tag(1440)
                Text("1080p").tag(1080)
                Text("720p").tag(720)
                Text("480p").tag(480)
            }
            note("For MP4, MOV and MKV. H.264 plays almost everywhere, HEVC makes smaller files. WebM always uses VP9. Keeping the codec copies the video without any loss, so quality only matters when it has to be re-encoded.")
        }

        Section("GIF") {
            Picker("Largest width", selection: $settings.gifWidth) {
                ForEach([320, 480, 720, 1080], id: \.self) { width in
                    Text("\(width) px").tag(width)
                }
            }
            Picker("Frame rate", selection: $settings.gifFrameRate) {
                ForEach([10, 15, 24, 30], id: \.self) { rate in
                    Text("\(rate) fps").tag(rate)
                }
            }
        }

        Section("Audio") {
            Picker("Bitrate", selection: $settings.audioBitrate) {
                Text("Automatic").tag(0)
                ForEach([128, 192, 256, 320], id: \.self) { rate in
                    Text("\(rate) kbps").tag(rate)
                }
            }
            note("For MP3, M4A, Ogg and Opus files. Lossless formats are not affected.")
        }
    }

    // MARK: Documents

    @ViewBuilder
    private var documents: some View {
        Section("PDF") {
            Picker("Page size", selection: $settings.paperSize) {
                Text("A4").tag(PaperSize.a4)
                Text("US Letter").tag(PaperSize.letter)
            }
            note("For text, Markdown, HTML and EPUB. Office and iWork files usually keep their own pages.")
        }

        Section("Pages as Images") {
            Picker("Resolution", selection: $settings.pageImageDPI) {
                ForEach([72.0, 150, 200, 300, 600], id: \.self) { dpi in
                    Text("\(Int(dpi)) dpi").tag(dpi)
                }
            }
            note("Used when a document becomes PNG or JPEG, and when a PDF becomes slides.")
        }

        Section("Scans") {
            Toggle("Recognize text in scanned PDFs", isOn: $settings.recognizesScans)
            note("Runs on this Mac. Turn it off to skip pages without a text layer.")
        }
    }
}

/// One family of actions, as checkboxes for what appears on the wheel.
private struct WheelChoices: View {
    let title: String
    let actions: [ConversionAction]
    let settings: AppSettings

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .leading), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(actions, id: \.self) { action in
                    Toggle(action.chipLabel, isOn: Binding(
                        get: { settings.isOnWheel(action) },
                        set: { settings.setOnWheel(action, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help(action.title)
                }
            }
        }
    }
}
