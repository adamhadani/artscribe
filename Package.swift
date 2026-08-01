// swift-tools-version: 6.2
import PackageDescription

/// Applied to every target. Swift 6 language mode already implies complete
/// strict concurrency; `treatAllWarnings(as: .error)` keeps the build honest.
let sharedSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "Artscribe",
    // iOS is declared for the *lower* half of the stack — `ArtscribeKit`,
    // `AudioDecode`, `Waveform`, `TimeStretch`, `Playback` — which is portable
    // and is built for iOS in CI to keep it that way. `ArtscribeUI` and up are
    // AppKit and remain macOS-only; declaring the platform does not claim
    // otherwise, it only stops SwiftPM refusing the destination outright.
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ArtscribeKit", targets: ["ArtscribeKit"]),
        // The audio engine, as its own product so an iOS app target can depend
        // on it and so `xcodebuild` has a scheme to build for iOS.
        .library(name: "Playback", targets: ["Playback"]),
        // Everything but the app shell, as one product. It exists so the Xcode
        // target generated from `project.yml` can depend on the package: Xcode
        // can only consume *products*, and `ArtscribeApp` is an executable
        // target. The bundle therefore compiles `Sources/ArtscribeApp` itself
        // (three dozen lines of `App` scene) and takes the rest from here, so
        // there is exactly one copy of the real code and both build systems
        // read it. See `project.yml`.
        .library(name: "ArtscribeUI", targets: ["ArtscribeUI"]),
        // Exported so the Xcode-side iOS test bundle in `project.yml` can depend
        // on them. Xcode consumes *products*, not targets, and these three carry
        // suites that are portable and worth running on a simulator — most of
        // all `TimeStretch`, since Signalsmith is the only backend on iOS and
        // was until now proved exclusively on the Mac. No new code, no new
        // dependency direction: these were already targets of this package.
        .library(name: "AudioDecode", targets: ["AudioDecode"]),
        .library(name: "Waveform", targets: ["Waveform"]),
        .library(name: "TimeStretch", targets: ["TimeStretch"]),
        .executable(name: "artscribe-cli", targets: ["ArtscribeCLI"])
    ],
    targets: [
        .systemLibrary(
            name: "CRubberBand",
            path: "Sources/CRubberBand",
            pkgConfig: "rubberband",
            providers: [.brew(["rubberband"])]
        ),
        // Signalsmith Stretch, vendored, plus the C shim that makes it callable
        // from Swift. Unlike `CRubberBand` this is **not** a system library: the
        // sources are in-tree and we compile them, which is precisely what makes
        // an iOS build possible — there is no Homebrew on a phone.
        //
        // `vendor` is on the header search path because
        // `signalsmith-stretch.h` includes `"signalsmith-linear/stft.h"`, and a
        // quoted include resolves relative to the *including* file first. Only
        // `include/` is public, so Swift sees the flat C surface and never the
        // C++ templates behind it.
        //
        // Accelerate is deliberately not enabled here yet; see `VENDOR.md`.
        .target(
            name: "CSignalsmithStretch",
            cxxSettings: [.headerSearchPath("vendor")]
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
        // Rubber Band comes from Homebrew, which builds a macOS dylib and
        // nothing else, so the dependency is macOS-only and
        // `RubberBandStretcher.swift` is behind `#if canImport(CRubberBand)`.
        // On iOS the module is the `TimeStretcher` protocol and
        // `IdentityStretcher`, which is enough for `Playback` to compile and
        // exactly the seam a second backend plugs into.
        .target(
            name: "TimeStretch",
            dependencies: [
                "ArtscribeKit",
                .target(name: "CRubberBand", condition: .when(platforms: [.macOS])),
                // No platform condition, and that is the point: this backend
                // exists so that `PlatformStretcher` has something real to
                // return on iOS.
                "CSignalsmithStretch"
            ],
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
            dependencies: ["ArtscribeKit", "AudioDecode", "Waveform", "Playback"],
            // The bundled sample track. `.copy` rather than `.process`: it is
            // already the exact bytes to ship, and `.process` would let the
            // toolchain re-encode audio it decided it knew better about.
            resources: [.copy("Resources/GoldbergVariatio4.m4a")],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "ArtscribeUITests",
            dependencies: ["ArtscribeUI"],
            swiftSettings: sharedSwiftSettings
        ),
        // The debug listening tool: decode, stretch, loop, and play to a chosen
        // output device, with the render-thread degradation counters reported.
        .executableTarget(
            name: "ArtscribeCLI",
            dependencies: ["ArtscribeKit", "AudioDecode", "TimeStretch", "Playback"],
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
        // `Playback` is declared rather than picked up transitively through
        // `ArtscribeUI`: the harness closes `OutputAudibility`'s silence gate
        // itself, so it depends on that module for real.
        .executableTarget(
            name: "ArtscribeAcceptance",
            dependencies: ["ArtscribeUI", "Playback"],
            swiftSettings: sharedSwiftSettings
        ),
        // Only the harness's *pure* logic — which groups a command line selects
        // — is tested here. Driving a window is what the harness itself is for;
        // the parsing in front of it is ordinary code and gets ordinary tests.
        .testTarget(
            name: "ArtscribeAcceptanceTests",
            dependencies: ["ArtscribeAcceptance"],
            swiftSettings: sharedSwiftSettings
        )
    ],
    // For the vendored Signalsmith headers. Nothing else in the package is C++.
    cxxLanguageStandard: .cxx17
)
