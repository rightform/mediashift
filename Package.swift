// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MediaShift",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ConversionKit", targets: ["ConversionKit"]),
        .executable(name: "mediashift", targets: ["mediashift"]),
        .executable(name: "MediaShiftApp", targets: ["MediaShiftApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0"),
    ],
    targets: [
        // Shared vocabulary: formats, the document model, errors. No heavy dependencies.
        .target(name: "ConversionCore"),

        // Office and iWork files, read and written without Office or iWork installed.
        .target(
            name: "OfficeFormats",
            dependencies: ["ConversionCore", "ZIPFoundation"],
            resources: [.copy("Resources")]
        ),

        // Images through ImageIO, audio and video through a bundled ffmpeg.
        .target(name: "MediaEngine", dependencies: ["ConversionCore"]),

        // Text documents: readers and writers around the shared document model.
        .target(
            name: "DocumentEngine",
            dependencies: [
                "ConversionCore",
                "ZIPFoundation",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),

        // The single entry point used by the app and the command line tool.
        .target(name: "ConversionKit", dependencies: ["ConversionCore", "OfficeFormats", "MediaEngine", "DocumentEngine"]),

        .executableTarget(name: "mediashift", dependencies: ["ConversionKit"]),
        .executableTarget(name: "MediaShiftApp", dependencies: ["ConversionKit"]),

        .testTarget(name: "ConversionCoreTests", dependencies: ["ConversionCore"]),
        .testTarget(name: "OfficeFormatsTests", dependencies: ["OfficeFormats"]),
        .testTarget(name: "MediaEngineTests", dependencies: ["MediaEngine"]),
        .testTarget(name: "DocumentEngineTests", dependencies: ["DocumentEngine"]),
        .testTarget(name: "ConversionKitTests", dependencies: ["ConversionKit"]),
        .testTarget(name: "MediaShiftAppTests", dependencies: ["MediaShiftApp"]),
    ]
)
