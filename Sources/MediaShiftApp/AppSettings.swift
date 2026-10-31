import AppKit
import ConversionKit
import Observation
import ServiceManagement

/// The modifier that turns an ordinary drag into a conversion gesture.
enum GestureModifier: String, CaseIterable, Identifiable {
    case shift, control, option, command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: "Shift"
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        }
    }
}

/// What happens once the queue has nothing left to do.
enum FinishAction: String, CaseIterable, Identifiable {
    case nothing, reveal, open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: "Do Nothing"
        case .reveal: "Show in Finder"
        case .open: "Open the Result"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let wheelEnabled = "wheelEnabled"
        static let modifier = "gestureModifier"
        static let wheelHaptics = "wheelHaptics"
        static let hiddenWheelActions = "hiddenWheelActions"
        static let level = "compressionLevel"
        static let usesTargetSize = "usesTargetSize"
        static let targetMegabytes = "targetMegabytes"
        static let removesMetadata = "removesMetadata"
        static let outputFolder = "outputFolder"
        static let convertedSuffix = "convertedSuffix"
        static let compressedSuffix = "compressedSuffix"
        static let cleanedSuffix = "cleanedSuffix"
        static let maximumJobs = "maximumJobs"
        static let finishAction = "finishAction"
        static let playsSound = "playsSound"
        static let showsToast = "showsToast"
        static let usesCustomImageQuality = "usesCustomImageQuality"
        static let imageQualityPercent = "imageQualityPercent"
        static let imageMaxPixelSize = "imageMaxPixelSize"
        static let videoCodec = "videoCodec"
        static let videoQuality = "videoQuality"
        static let maxVideoResolution = "maxVideoResolution"
        static let audioBitrate = "audioBitrate"
        static let gifWidth = "gifWidth"
        static let gifFrameRate = "gifFrameRate"
        static let paperSize = "paperSize"
        static let pageImageDPI = "pageImageDPI"
        static let recognizesScans = "recognizesScans"

        static let all = [
            wheelEnabled, modifier, wheelHaptics, hiddenWheelActions, level, usesTargetSize, targetMegabytes,
            removesMetadata, outputFolder, convertedSuffix, compressedSuffix, cleanedSuffix, maximumJobs,
            finishAction, playsSound, showsToast, usesCustomImageQuality, imageQualityPercent, imageMaxPixelSize,
            videoCodec, videoQuality, maxVideoResolution, audioBitrate, gifWidth, gifFrameRate, paperSize,
            pageImageDPI, recognizesScans,
        ]
    }

    private let defaults: UserDefaults

    // MARK: Wheel

    var wheelEnabled: Bool {
        didSet { defaults.set(wheelEnabled, forKey: Key.wheelEnabled) }
    }

    var modifier: GestureModifier {
        didSet { defaults.set(modifier.rawValue, forKey: Key.modifier) }
    }

    var wheelHaptics: Bool {
        didSet { defaults.set(wheelHaptics, forKey: Key.wheelHaptics) }
    }

    /// Actions left off the wheel. They stay available from the menu bar.
    var hiddenWheelActions: Set<String> {
        didSet { defaults.set(Array(hiddenWheelActions).sorted(), forKey: Key.hiddenWheelActions) }
    }

    // MARK: Output

    /// Nil saves next to the original.
    var outputFolder: URL? {
        didSet { defaults.set(outputFolder?.path, forKey: Key.outputFolder) }
    }

    var convertedSuffix: String {
        didSet { defaults.set(convertedSuffix, forKey: Key.convertedSuffix) }
    }

    var compressedSuffix: String {
        didSet { defaults.set(compressedSuffix, forKey: Key.compressedSuffix) }
    }

    var cleanedSuffix: String {
        didSet { defaults.set(cleanedSuffix, forKey: Key.cleanedSuffix) }
    }

    var removesMetadata: Bool {
        didSet { defaults.set(removesMetadata, forKey: Key.removesMetadata) }
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

    // MARK: General

    var maximumJobs: Int {
        didSet { defaults.set(maximumJobs, forKey: Key.maximumJobs) }
    }

    var finishAction: FinishAction {
        didSet { defaults.set(finishAction.rawValue, forKey: Key.finishAction) }
    }

    var playsSound: Bool {
        didSet { defaults.set(playsSound, forKey: Key.playsSound) }
    }

    var showsToast: Bool {
        didSet { defaults.set(showsToast, forKey: Key.showsToast) }
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

    // MARK: Images

    var usesCustomImageQuality: Bool {
        didSet { defaults.set(usesCustomImageQuality, forKey: Key.usesCustomImageQuality) }
    }

    var imageQualityPercent: Double {
        didSet { defaults.set(imageQualityPercent, forKey: Key.imageQualityPercent) }
    }

    /// The longest side in pixels. Zero keeps the size.
    var imageMaxPixelSize: Int {
        didSet { defaults.set(imageMaxPixelSize, forKey: Key.imageMaxPixelSize) }
    }

    // MARK: Video and audio

    var videoCodec: VideoCodecChoice {
        didSet { defaults.set(videoCodec.rawValue, forKey: Key.videoCodec) }
    }

    var videoQuality: VideoQuality {
        didSet { defaults.set(videoQuality.rawValue, forKey: Key.videoQuality) }
    }

    /// The shorter side in pixels. Zero keeps the size.
    var maxVideoResolution: Int {
        didSet { defaults.set(maxVideoResolution, forKey: Key.maxVideoResolution) }
    }

    /// In kilobits per second. Zero uses the format's default.
    var audioBitrate: Int {
        didSet { defaults.set(audioBitrate, forKey: Key.audioBitrate) }
    }

    var gifWidth: Int {
        didSet { defaults.set(gifWidth, forKey: Key.gifWidth) }
    }

    var gifFrameRate: Int {
        didSet { defaults.set(gifFrameRate, forKey: Key.gifFrameRate) }
    }

    // MARK: Documents

    var paperSize: PaperSize {
        didSet { defaults.set(paperSize.rawValue, forKey: Key.paperSize) }
    }

    var pageImageDPI: Double {
        didSet { defaults.set(pageImageDPI, forKey: Key.pageImageDPI) }
    }

    var recognizesScans: Bool {
        didSet { defaults.set(recognizesScans, forKey: Key.recognizesScans) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wheelEnabled = defaults.object(forKey: Key.wheelEnabled) as? Bool ?? true
        modifier = defaults.string(forKey: Key.modifier).flatMap(GestureModifier.init) ?? .shift
        wheelHaptics = defaults.object(forKey: Key.wheelHaptics) as? Bool ?? true
        hiddenWheelActions = Set(defaults.stringArray(forKey: Key.hiddenWheelActions) ?? [])
        outputFolder = defaults.string(forKey: Key.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        convertedSuffix = defaults.string(forKey: Key.convertedSuffix) ?? ""
        compressedSuffix = defaults.string(forKey: Key.compressedSuffix) ?? "compressed"
        cleanedSuffix = defaults.string(forKey: Key.cleanedSuffix) ?? "clean"
        removesMetadata = defaults.bool(forKey: Key.removesMetadata)
        compressionLevel = defaults.string(forKey: Key.level).flatMap(CompressionLevel.init) ?? .balanced
        usesTargetSize = defaults.bool(forKey: Key.usesTargetSize)
        targetMegabytes = defaults.object(forKey: Key.targetMegabytes) as? Double ?? 10
        maximumJobs = defaults.object(forKey: Key.maximumJobs) as? Int ?? 3
        finishAction = defaults.string(forKey: Key.finishAction).flatMap(FinishAction.init) ?? .nothing
        playsSound = defaults.bool(forKey: Key.playsSound)
        showsToast = defaults.object(forKey: Key.showsToast) as? Bool ?? true
        usesCustomImageQuality = defaults.bool(forKey: Key.usesCustomImageQuality)
        imageQualityPercent = defaults.object(forKey: Key.imageQualityPercent) as? Double ?? 85
        imageMaxPixelSize = defaults.integer(forKey: Key.imageMaxPixelSize)
        videoCodec = defaults.string(forKey: Key.videoCodec).flatMap(VideoCodecChoice.init) ?? .automatic
        videoQuality = defaults.string(forKey: Key.videoQuality).flatMap(VideoQuality.init) ?? .standard
        maxVideoResolution = defaults.integer(forKey: Key.maxVideoResolution)
        audioBitrate = defaults.integer(forKey: Key.audioBitrate)
        gifWidth = defaults.object(forKey: Key.gifWidth) as? Int ?? 720
        gifFrameRate = defaults.object(forKey: Key.gifFrameRate) as? Int ?? 15
        paperSize = defaults.string(forKey: Key.paperSize).flatMap(PaperSize.init) ?? .a4
        pageImageDPI = defaults.object(forKey: Key.pageImageDPI) as? Double ?? 200
        recognizesScans = defaults.object(forKey: Key.recognizesScans) as? Bool ?? true
    }

    /// Back to how the app ships. Login items belong to the system and are left alone.
    func restoreDefaults() {
        Key.all.forEach(defaults.removeObject)
        let fresh = AppSettings(defaults: defaults)
        wheelEnabled = fresh.wheelEnabled
        modifier = fresh.modifier
        wheelHaptics = fresh.wheelHaptics
        hiddenWheelActions = fresh.hiddenWheelActions
        outputFolder = fresh.outputFolder
        convertedSuffix = fresh.convertedSuffix
        compressedSuffix = fresh.compressedSuffix
        cleanedSuffix = fresh.cleanedSuffix
        removesMetadata = fresh.removesMetadata
        compressionLevel = fresh.compressionLevel
        usesTargetSize = fresh.usesTargetSize
        targetMegabytes = fresh.targetMegabytes
        maximumJobs = fresh.maximumJobs
        finishAction = fresh.finishAction
        playsSound = fresh.playsSound
        showsToast = fresh.showsToast
        usesCustomImageQuality = fresh.usesCustomImageQuality
        imageQualityPercent = fresh.imageQualityPercent
        imageMaxPixelSize = fresh.imageMaxPixelSize
        videoCodec = fresh.videoCodec
        videoQuality = fresh.videoQuality
        maxVideoResolution = fresh.maxVideoResolution
        audioBitrate = fresh.audioBitrate
        gifWidth = fresh.gifWidth
        gifFrameRate = fresh.gifFrameRate
        paperSize = fresh.paperSize
        pageImageDPI = fresh.pageImageDPI
        recognizesScans = fresh.recognizesScans
    }

    // MARK: What the wheel shows

    func isOnWheel(_ action: ConversionAction) -> Bool {
        !hiddenWheelActions.contains(action.settingsKey)
    }

    func setOnWheel(_ action: ConversionAction, _ isShown: Bool) {
        if isShown {
            hiddenWheelActions.remove(action.settingsKey)
        } else {
            hiddenWheelActions.insert(action.settingsKey)
        }
    }

    func wheelActions(for urls: [URL]) -> [ConversionAction] {
        ConversionCatalog.actions(for: urls).filter(isOnWheel)
    }

    var conversionOptions: ConversionOptions {
        ConversionOptions(
            compressionLevel: compressionLevel,
            targetBytes: usesTargetSize ? Int64(targetMegabytes * 1_000_000) : nil,
            removesMetadata: removesMetadata,
            outputDirectory: outputFolder,
            convertedSuffix: OutputNaming.cleanSuffix(convertedSuffix),
            compressedSuffix: OutputNaming.cleanSuffix(compressedSuffix) ?? "compressed",
            cleanedSuffix: OutputNaming.cleanSuffix(cleanedSuffix) ?? "clean",
            imageQuality: usesCustomImageQuality ? imageQualityPercent / 100 : nil,
            imageMaxPixelSize: imageMaxPixelSize > 0 ? imageMaxPixelSize : nil,
            media: MediaOptions(
                videoCodec: videoCodec,
                videoQuality: videoQuality,
                maxVideoResolution: maxVideoResolution > 0 ? maxVideoResolution : nil,
                audioBitrate: audioBitrate > 0 ? audioBitrate * 1000 : nil,
                gifWidth: gifWidth,
                gifFrameRate: gifFrameRate
            ),
            paperSize: paperSize,
            pageImageDPI: pageImageDPI,
            recognizesScans: recognizesScans
        )
    }
}

extension ConversionAction {
    /// A stable name for remembering a choice about this action.
    var settingsKey: String {
        switch self {
        case .convert(let format): format.rawValue
        case .compress: "compress"
        case .stripMetadata: "stripMetadata"
        }
    }
}
