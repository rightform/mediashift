import AppKit
import ConversionKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings))
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppIdentity.name) Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
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

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Wheel") {
                Toggle("Show the wheel while dragging files", isOn: $settings.wheelEnabled)
                Picker("Hold while dragging", selection: $settings.modifier) {
                    ForEach(GestureModifier.allCases) { modifier in
                        Text(modifier.title).tag(modifier)
                    }
                }
                .disabled(!settings.wheelEnabled)
            }

            Section("Results") {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.outputFolder?.lastPathComponent ?? "Next to the original")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                        if settings.outputFolder != nil {
                            Button("Reset") { settings.outputFolder = nil }
                        }
                    }
                }
                Toggle("Remove metadata when converting", isOn: $settings.removesMetadata)
                Text("Originals are never changed. A new file gets its own name.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                    Text("Applies to images, audio and video.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { settings.launchesAtLogin },
                    set: { settings.launchesAtLogin = $0 }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                LabeledContent("Privacy", value: "Files stay on this Mac")
                LabeledContent("Version", value: AppIdentity.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { settings.outputFolder = panel.url }
    }
}
