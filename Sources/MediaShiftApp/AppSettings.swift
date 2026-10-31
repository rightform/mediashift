import AppKit
import ConversionKit
import Observation
import ServiceManagement

/// The modifier that turns an ordinary drag into a conversion gesture.
enum GestureModifier: String, CaseIterable, Identifiable {
    case shift, control, option

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: "Shift"
        case .control: "Control"
        case .option: "Option"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let wheelEnabled = "wheelEnabled"
        static let modifier = "gestureModifier"
        static let level = "compressionLevel"
        static let usesTargetSize = "usesTargetSize"
        static let targetMegabytes = "targetMegabytes"
        static let removesMetadata = "removesMetadata"
        static let outputFolder = "outputFolder"
    }

    private let defaults = UserDefaults.standard

    var wheelEnabled: Bool {
        didSet { defaults.set(wheelEnabled, forKey: Key.wheelEnabled) }
    }

    var modifier: GestureModifier {
        didSet { defaults.set(modifier.rawValue, forKey: Key.modifier) }
    }

    var compressionLevel: CompressionLevel {
        didSet { defaults.set(compressionLevel.rawValue, forKey: Key.level) }
    }

    var usesTargetSize: Bool {
        didSet { defaults.set(usesTargetSize, forKey: Key.usesTargetSize) }
    }

    var targetMegabytes: Double {
        didSet { defaults.set(targetMegabytes, forKey: Key.targetMegabytes) }
    }

    var removesMetadata: Bool {
        didSet { defaults.set(removesMetadata, forKey: Key.removesMetadata) }
    }

    /// Nil saves next to the original.
    var outputFolder: URL? {
        didSet { defaults.set(outputFolder?.path, forKey: Key.outputFolder) }
    }

    /// Reads from the system, which is the source of truth and can change in System Settings.
    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLoginError = "Could not change this. You can set it in System Settings under Login Items."
            }
        }
    }

    var launchAtLoginError: String?

    init() {
        wheelEnabled = defaults.object(forKey: Key.wheelEnabled) as? Bool ?? true
        modifier = defaults.string(forKey: Key.modifier).flatMap(GestureModifier.init) ?? .shift
        compressionLevel = defaults.string(forKey: Key.level).flatMap(CompressionLevel.init) ?? .balanced
        usesTargetSize = defaults.bool(forKey: Key.usesTargetSize)
        targetMegabytes = defaults.object(forKey: Key.targetMegabytes) as? Double ?? 10
        removesMetadata = defaults.bool(forKey: Key.removesMetadata)
        outputFolder = defaults.string(forKey: Key.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var conversionOptions: ConversionOptions {
        ConversionOptions(
            compressionLevel: compressionLevel,
            targetBytes: usesTargetSize ? Int64(targetMegabytes * 1_000_000) : nil,
            removesMetadata: removesMetadata,
            outputDirectory: outputFolder
        )
    }
}
