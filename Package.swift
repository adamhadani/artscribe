// swift-tools-version: 6.2
import PackageDescription

/// Applied to every target. Swift 6 language mode already implies complete
/// strict concurrency; `treatAllWarnings(as: .error)` keeps the build honest.
let sharedSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "Artscribe",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArtscribeKit", targets: ["ArtscribeKit"])
    ],
    targets: [
        .systemLibrary(
            name: "CRubberBand",
            path: "Sources/CRubberBand",
            pkgConfig: "rubberband",
            providers: [.brew(["rubberband"])]
        ),
        .target(name: "ArtscribeKit", swiftSettings: sharedSwiftSettings),
        .target(
            name: "AudioDecode",
            dependencies: ["ArtscribeKit"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "CRubberBandTests",
            dependencies: ["CRubberBand"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "ArtscribeKitTests",
            dependencies: ["ArtscribeKit"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "AudioDecodeTests",
            dependencies: ["AudioDecode"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "Waveform",
            dependencies: ["ArtscribeKit", "AudioDecode"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "WaveformTests",
            dependencies: ["Waveform"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "TimeStretch",
            dependencies: ["ArtscribeKit", "CRubberBand"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "TimeStretchTests",
            dependencies: ["TimeStretch"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "Playback",
            dependencies: ["ArtscribeKit", "AudioDecode", "TimeStretch"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "PlaybackTests",
            dependencies: ["Playback"],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ArtscribeUI",
            dependencies: ["ArtscribeKit", "AudioDecode", "Waveform"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "ArtscribeUITests",
            dependencies: ["ArtscribeUI"],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "ArtscribeApp",
            dependencies: ["ArtscribeUI"],
            swiftSettings: sharedSwiftSettings
        ),
        // The scripted acceptance harness (see `AcceptanceRun.swift`). A
        // separate executable so it never ships inside `ArtscribeApp`: the
        // product binary should be just the app.
        .executableTarget(
            name: "ArtscribeAcceptance",
            dependencies: ["ArtscribeUI"],
            swiftSettings: sharedSwiftSettings
        )
    ]
)
