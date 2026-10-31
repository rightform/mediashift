import AppKit
import ConversionKit
import Foundation
import Testing

@testable import MediaShiftApp

@MainActor
private func blankDefaults() -> UserDefaults {
    UserDefaults(suiteName: "MediaShiftTests-\(UUID().uuidString)")!
}

@MainActor
@Test func aNewInstallUsesTheRecommendedChoices() {
    let options = AppSettings(defaults: blankDefaults()).conversionOptions
    #expect(options.compressionLevel == .balanced)
    #expect(options.targetBytes == nil)
    #expect(!options.removesMetadata)
    #expect(options.outputDirectory == nil)
    #expect(options.convertedSuffix == nil)
    #expect(options.compressedSuffix == "compressed")
    #expect(options.cleanedSuffix == "clean")
    #expect(options.imageQuality == nil)
    #expect(options.imageMaxPixelSize == nil)
    #expect(options.media == MediaOptions())
    #expect(options.paperSize == .a4)
    #expect(options.pageImageDPI == 200)
    #expect(options.recognizesScans)
}

@MainActor
@Test func choicesSurviveARestart() {
    let defaults = blankDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.modifier = .command
    settings.wheelHaptics = false
    settings.setOnWheel(.convert(.bmp), false)
    settings.maximumJobs = 6
    settings.finishAction = .reveal
    settings.playsSound = true
    settings.showsToast = false
    settings.convertedSuffix = "web"
    settings.usesCustomImageQuality = true
    settings.imageQualityPercent = 60
    settings.imageMaxPixelSize = 1600
    settings.videoCodec = .hevc
    settings.videoQuality = .higher
    settings.maxVideoResolution = 720
    settings.audioBitrate = 256
    settings.gifWidth = 480
    settings.gifFrameRate = 24
    settings.paperSize = .letter
    settings.pageImageDPI = 300
    settings.recognizesScans = false

    let again = AppSettings(defaults: defaults)
    #expect(again.modifier == .command)
    #expect(!again.wheelHaptics)
    #expect(!again.isOnWheel(.convert(.bmp)))
    #expect(again.maximumJobs == 6)
    #expect(again.finishAction == .reveal)
    #expect(again.playsSound)
    #expect(!again.showsToast)
    #expect(again.convertedSuffix == "web")
    #expect(again.imageQualityPercent == 60)
    #expect(again.imageMaxPixelSize == 1600)
    #expect(again.videoCodec == .hevc)
    #expect(again.videoQuality == .higher)
    #expect(again.maxVideoResolution == 720)
    #expect(again.audioBitrate == 256)
    #expect(again.gifWidth == 480)
    #expect(again.gifFrameRate == 24)
    #expect(again.paperSize == .letter)
    #expect(again.pageImageDPI == 300)
    #expect(!again.recognizesScans)
}

@MainActor
@Test func choicesReachTheConverter() {
    let settings = AppSettings(defaults: blankDefaults())
    settings.convertedSuffix = " web "
    settings.compressedSuffix = "small"
    settings.usesCustomImageQuality = true
    settings.imageQualityPercent = 60
    settings.imageMaxPixelSize = 1600
    settings.videoCodec = .hevc
    settings.videoQuality = .higher
    settings.maxVideoResolution = 720
    settings.audioBitrate = 256
    settings.gifWidth = 480
    settings.gifFrameRate = 24
    settings.paperSize = .letter
    settings.pageImageDPI = 300
    settings.recognizesScans = false

    let options = settings.conversionOptions
    #expect(options.convertedSuffix == "web")
    #expect(options.compressedSuffix == "small")
    #expect(options.imageQuality == 0.6)
    #expect(options.imageMaxPixelSize == 1600)
    #expect(options.media.videoCodec == .hevc)
    #expect(options.media.videoQuality == .higher)
    #expect(options.media.maxVideoResolution == 720)
    #expect(options.media.audioBitrate == 256_000)
    #expect(options.media.gifWidth == 480)
    #expect(options.media.gifFrameRate == 24)
    #expect(options.paperSize == .letter)
    #expect(options.pageImageDPI == 300)
    #expect(!options.recognizesScans)
}

@MainActor
@Test func aQualitySetAsideIsNotUsed() {
    let settings = AppSettings(defaults: blankDefaults())
    settings.imageQualityPercent = 40
    #expect(settings.conversionOptions.imageQuality == nil)
}

@MainActor
@Test func aBlankFileNamePartFallsBackRatherThanCollidingWithTheSource() {
    let settings = AppSettings(defaults: blankDefaults())
    settings.compressedSuffix = "   "
    settings.cleanedSuffix = "/:"
    #expect(settings.conversionOptions.compressedSuffix == "compressed")
    #expect(settings.conversionOptions.cleanedSuffix == "clean")
}

@MainActor
@Test func restoringDefaultsUndoesEveryChoice() {
    let defaults = blankDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.wheelEnabled = false
    settings.setOnWheel(.compress, false)
    settings.maximumJobs = 8
    settings.videoCodec = .h264
    settings.gifWidth = 320
    settings.recognizesScans = false

    settings.restoreDefaults()

    #expect(settings.wheelEnabled)
    #expect(settings.isOnWheel(.compress))
    #expect(settings.maximumJobs == 3)
    #expect(settings.videoCodec == .automatic)
    #expect(settings.gifWidth == 720)
    #expect(settings.recognizesScans)
    #expect(AppSettings(defaults: defaults).maximumJobs == 3)
}

@MainActor
@Test func hiddenActionsLeaveOnlyTheWheel() {
    let settings = AppSettings(defaults: blankDefaults())
    let photo = [URL(fileURLWithPath: "/a.jpg")]
    let everything = ConversionCatalog.actions(for: photo)
    #expect(settings.wheelActions(for: photo) == everything)

    settings.setOnWheel(.convert(.bmp), false)
    settings.setOnWheel(.compress, false)
    #expect(!settings.wheelActions(for: photo).contains(.convert(.bmp)))
    #expect(!settings.wheelActions(for: photo).contains(.compress))
    #expect(settings.wheelActions(for: photo).count == everything.count - 2)

    // The menu bar list goes to the catalog directly, so it still offers them.
    #expect(ConversionCatalog.actions(for: photo).contains(.compress))

    settings.setOnWheel(.compress, true)
    #expect(settings.wheelActions(for: photo).contains(.compress))
}

@MainActor
@Test func theWheelSettingsOfferEveryAction() {
    let offered = Set(ConversionCatalog.allTargets)
    for format in FileFormat.allCases {
        #expect(offered.isSuperset(of: ConversionCatalog.targets(for: format)), "\(format)")
    }
    // Read-only formats have nothing to hide.
    #expect(!offered.contains(.numbers))
    #expect(!offered.contains(.key))
}

@MainActor
@Test func theQueueHonoursTheLimitAndReportsABatchOnce() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let inputs = (1...3).map { folder.appendingPathComponent("note\($0).txt") }
    for input in inputs { try Data("Hello".utf8).write(to: input) }

    let settings = AppSettings(defaults: blankDefaults())
    settings.maximumJobs = 1
    let queue = JobQueue(settings: settings)

    let (outputs, hadFailure): ([URL], Bool) = await withCheckedContinuation { continuation in
        queue.onBatchFinished = { outputs, hadFailure in continuation.resume(returning: (outputs, hadFailure)) }
        queue.add(inputs, action: .convert(.md))
        let running = queue.jobs.filter { if case .running = $0.state { true } else { false } }
        #expect(running.count == 1)
    }
    #expect(outputs.count == 3)
    #expect(!hadFailure)
    #expect(queue.activeJobs.isEmpty)
}
