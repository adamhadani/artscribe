import Foundation

/// **Everything the About panel claims**, extracted from the view so it can be
/// tested.
///
/// The panel is not decoration. App Store guideline 5.1.1(i) requires the
/// privacy policy to be reachable *inside* the app rather than only in store
/// metadata, and Rubber Band's GPL carries an attribution obligation on the
/// builds that link it. Both of those are assertions that have to be **true**,
/// and this project does not snapshot-test views — so the assertions live in a
/// type a test can interrogate and the view draws whatever it finds here.
///
/// The licence list in particular is a function of the platform rather than a
/// `#if`, for exactly that reason: a compile-time list can only ever be checked
/// on the platform the tests run on, which is the Mac, which is the half that
/// was never in doubt.
public enum AboutInfo {

    /// One line of prose under the wordmark. Deliberately the same sentence the
    /// website and `CLAUDE.md` open with, so the three do not drift into three
    /// different descriptions of the same app.
    public static let tagline = "A keyboard-first music transcription tool."

    // MARK: - Version

    /// The version line, read off `Bundle.main`.
    ///
    /// **This has to survive not being in a bundle.** `swift run ArtscribeApp`
    /// produces a bare SwiftPM executable with no `Info.plist` at all — which is
    /// the configuration every developer and every agent on this project
    /// actually runs — so both keys come back `nil` and the naive
    /// `"Version \(short) (\(build))"` renders `Version  ()`. See
    /// `line(short:build:)` for what is shown instead.
    public static var versionLine: String {
        let bundle = Bundle.main
        return line(
            short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// What an unbundled binary says where a version would go.
    ///
    /// Not an empty string, and not a fabricated `0.0.0`: an empty line leaves a
    /// gap the layout was built around, and a made-up number is the one thing a
    /// version string must never be. "Development build" is what is actually
    /// running.
    public static let developmentBuild = "Development build"

    /// Both keys, one of them, or neither — enumerated rather than interpolated.
    ///
    /// The build number alone is a malformed bundle rather than an impossible
    /// one, so it is reported as a build rather than swallowed: a panel that
    /// silently said "Development build" about a shipped app would hide the
    /// misconfiguration that caused it.
    static func line(short: String?, build: String?) -> String {
        switch (present(short), present(build)) {
        case let (short?, build?): return "Version \(short) (\(build))"
        case let (short?, nil): return "Version \(short)"
        case let (nil, build?): return "Build \(build)"
        case (nil, nil): return developmentBuild
        }
    }

    /// A value only counts if it has something in it. An `Info.plist` whose
    /// build-setting substitution did not happen leaves the key present and
    /// empty, which `!= nil` would happily render as `Version  ()` — the very
    /// string this type exists to prevent.
    private static func present(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Links

    /// Where the panel points, in the order it draws them.
    ///
    /// **Privacy is the one that is not optional.** The other two are courtesy;
    /// that one is guideline 5.1.1(i), and `theLinksIncludeAPrivacyPolicy` is
    /// what stops a tidy-up removing it.
    public static let links: [AboutLink] = [
        AboutLink(title: "Website", address: "https://adamhadani.github.io/artscripture/"),
        AboutLink(title: "Support", address: "https://adamhadani.github.io/artscripture/support/"),
        AboutLink(
            title: "Privacy Policy", address: "https://adamhadani.github.io/artscripture/privacy/")
    ]

    // MARK: - Licences

    /// What is inside the build the reader is holding.
    ///
    /// **The platform is a parameter, not a `#if`.** The claim that matters
    /// commercially — that an iPadOS build contains no GPL code — is the one a
    /// macOS test run could never check if this were a compile-time list, and it
    /// is the half that decides whether the app may be sold at all
    /// (`docs/LICENSING.md`). Passing the platform in costs one enum and makes
    /// both answers testable from either.
    ///
    /// Note also what is *not* asked here: `#if canImport(CRubberBand)`, which
    /// is how `TimeStretch` decides the same question. `ArtscribeUI` does not
    /// depend on that module, so the answer would be `false` on macOS too — the
    /// GPL attribution would vanish from the one build that owes it, silently
    /// and without failing anything.
    public static func licences(on platform: AboutPlatform) -> [AboutLicence] {
        var list: [AboutLicence] = [
            AboutLicence(
                component: "Artscripture",
                terms: "Apache-2.0",
                detail: "This application's own source."),
            AboutLicence(
                component: "Signalsmith Stretch",
                terms: "MIT",
                detail: "The time stretcher. Vendored as source and compiled into every build."),
            AboutLicence(
                component: "Signalsmith Linear",
                terms: "MIT",
                detail: "The FFT and STFT it is built on — a second library, not part of the first."
            ),
            // Every build, both platforms. Listed with the code because it is
            // shipped the same way the code is: inside the binary.
            //
            // CC0 by the *recording project's* intent — the Open Goldberg
            // Variations were crowd-funded expressly to put the performance in
            // the public domain. Bach being long dead settles the composition
            // and nothing else; a 2012 recording carries its own copyright, and
            // "the music is old" is exactly the reasoning that would have got
            // this wrong.
            AboutLicence(
                component: SampleTrack.title,
                terms: "CC0 / public domain",
                detail: SampleTrack.credit)
        ]
        // macOS only, and the same statement `Package.swift` makes with
        // `.when(platforms: [.macOS])`: Homebrew builds Rubber Band as a macOS
        // dylib and nothing else, so no iOS build can contain it. Verified on
        // the artefact rather than inferred — the iPad binary carries 640
        // Signalsmith symbols and zero matching "rubberband" (see `NOTICE`).
        guard platform == .macOS else { return list }
        list.append(
            AboutLicence(
                component: "Rubber Band Library",
                terms: "GPL-2.0-or-later",
                detail: "The stretcher on macOS. Not present in the iPadOS build."))
        // **Found by reading `embed-dependencies.sh` rather than by reading the
        // licensing documents**, which is why it is written down here. The
        // bundle embeds *two* Homebrew dylibs, not one — `librubberband` links
        // `libsamplerate` itself — so a macOS build carries BSD-2-Clause code
        // that `NOTICE` and `docs/LICENSING.md` do not mention. `Info.plist`'s
        // `NSHumanReadableCopyright` does, and it is the only place that did.
        //
        // An attribution list assembled from the licensing prose would have
        // inherited that omission; this one is assembled from what the build
        // actually puts in `Contents/Frameworks`.
        list.append(
            AboutLicence(
                component: "libsamplerate",
                terms: "BSD-2-Clause",
                detail: "Resampling, linked by Rubber Band and embedded alongside it."))
        return list
    }

    /// The list for the build this code is running in.
    public static var licences: [AboutLicence] { licences(on: .current) }
}

/// One outbound link in the panel.
///
/// It holds the address as text and parses on demand rather than storing a
/// `URL`, because a non-failable `URL` here would mean a force-unwrap in a
/// static list — and `theLinksAreAbsoluteHTTPSURLs` catches a malformed one at
/// test time instead, which is where a typo in a constant should surface.
public struct AboutLink: Identifiable, Hashable, Sendable {
    public let title: String
    public let address: String

    public var id: String { address }
    public var url: URL? { URL(string: address) }

    public init(title: String, address: String) {
        self.title = title
        self.address = address
    }
}

/// One row of the licence list: what is in the build, under what terms, and why
/// it is there.
public struct AboutLicence: Identifiable, Hashable, Sendable {
    public let component: String
    public let terms: String
    public let detail: String

    public var id: String { component }

    public init(component: String, terms: String, detail: String) {
        self.component = component
        self.terms = terms
        self.detail = detail
    }
}

/// Which build the panel is describing.
///
/// Named for the products rather than for the SDKs — `iPadOS`, not `iOS` —
/// because these strings are read by a person deciding whether the copy in front
/// of them is the one with GPL code in it, and "iOS" is not what the App Store
/// calls the iPad build.
public enum AboutPlatform: String, CaseIterable, Hashable, Sendable {
    case macOS
    case iPadOS

    public static var current: AboutPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iPadOS
        #endif
    }
}
