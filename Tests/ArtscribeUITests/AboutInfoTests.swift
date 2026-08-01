import Foundation
import Testing

@testable import ArtscribeUI

/// **The About panel's claims, checked.**
///
/// The panel exists to satisfy App Store guideline 5.1.1(i) — the privacy policy
/// has to be reachable from inside the app — and Rubber Band's GPL attribution.
/// Views are not snapshot-tested here, so what is testable is exactly the part
/// that has to be *true*: which build says it contains which library, that the
/// privacy link is still there, and that the version line survives not being in
/// a bundle.
@Suite("About panel")
struct AboutInfoTests {

    // MARK: - The version line

    @Test("a bundled build names both keys")
    func theVersionLineNamesBothKeys() {
        #expect(AboutInfo.line(short: "0.3.0", build: "138") == "Version 0.3.0 (138)")
    }

    /// **The one this type exists for.** `swift run ArtscribeApp` produces a bare
    /// SwiftPM executable with no `Info.plist`, which is the configuration every
    /// developer and every agent on this project actually runs — and the naive
    /// interpolation renders `Version  ()` there, on every launch, for the whole
    /// life of the panel.
    @Test("an unbundled binary says what it is rather than 'Version  ()'")
    func anUnbundledBinaryDegradesToANameForItself() {
        let line = AboutInfo.line(short: nil, build: nil)
        #expect(line == AboutInfo.developmentBuild)
        #expect(!line.contains("("))
        #expect(!line.isEmpty)
    }

    /// A key that is present but empty is the shape a build-setting substitution
    /// takes when it does not happen, and `!= nil` reads it as a version.
    @Test("an empty or blank key counts as absent")
    func blankKeysCountAsAbsent() {
        #expect(AboutInfo.line(short: "", build: "  ") == AboutInfo.developmentBuild)
        #expect(AboutInfo.line(short: " 0.3.0 ", build: "") == "Version 0.3.0")
    }

    /// Half a version is a misconfigured bundle rather than an impossible one,
    /// and is reported rather than swallowed: a shipped app that quietly called
    /// itself a development build would hide the thing that caused it.
    @Test("one key alone is reported as the key it is")
    func oneKeyAloneIsStillReported() {
        #expect(AboutInfo.line(short: "0.3.0", build: nil) == "Version 0.3.0")
        #expect(AboutInfo.line(short: nil, build: "138") == "Build 138")
    }

    /// The live reader, whatever host it runs under. The suite cannot know
    /// whether the test runner's own bundle carries version keys, so what it
    /// asserts is the property that must hold either way.
    @Test("the live version line is never empty and never renders an empty pair")
    func theLiveVersionLineIsWellFormed() {
        let line = AboutInfo.versionLine
        #expect(!line.isEmpty)
        #expect(!line.contains("()"))
        #expect(!line.contains("  "))
    }

    // MARK: - The links

    @Test("every link is an absolute https URL")
    func theLinksAreAbsoluteHTTPSURLs() {
        #expect(AboutInfo.links.count == 3)
        for link in AboutInfo.links {
            #expect(!link.title.isEmpty)
            let url = link.url
            #expect(url != nil, "\(link.address) does not parse as a URL")
            #expect(url?.scheme == "https", "\(link.address) is not https")
            #expect(url?.host() != nil, "\(link.address) has no host")
        }
    }

    /// Guideline 5.1.1(i). The other two links are courtesy; this one is the
    /// reason the panel was built, and it is the kind of thing a tidy-up
    /// removes.
    @Test("the links include a privacy policy")
    func theLinksIncludeAPrivacyPolicy() {
        let privacy = AboutInfo.links.first { $0.title.contains("Privacy") }
        #expect(privacy != nil, "no privacy link — guideline 5.1.1(i) is unmet")
        #expect(privacy?.address.hasSuffix("/privacy/") == true)
    }

    // MARK: - The licences

    /// The macOS build links Rubber Band from Homebrew, so the binary is a
    /// combined work under the GPL and owes the attribution. See
    /// `docs/LICENSING.md` and `NOTICE`.
    @Test("the macOS list attributes Rubber Band under the GPL")
    func theMacOSListAttributesRubberBand() {
        let rubberBand = AboutInfo.licences(on: .macOS).first {
            $0.component.contains("Rubber Band")
        }
        #expect(rubberBand != nil, "the macOS build links Rubber Band and must say so")
        #expect(rubberBand?.terms.contains("GPL") == true)
    }

    /// `embed-dependencies.sh` copies **two** Homebrew dylibs into
    /// `Contents/Frameworks`, because `librubberband` links `libsamplerate`
    /// itself. It is in the shipped bundle and in `NSHumanReadableCopyright`,
    /// and it is in neither `NOTICE` nor `docs/LICENSING.md` — so the omission
    /// is the kind that propagates, and this is what stops it propagating here.
    @Test("the macOS list attributes libsamplerate, which the bundle also embeds")
    func theMacOSListAttributesLibsamplerate() {
        let named = AboutInfo.licences(on: .macOS).map(\.component)
        #expect(named.contains("libsamplerate"))
        // iPadOS links neither, since it links no Rubber Band to pull it in.
        #expect(!AboutInfo.licences(on: .iPadOS).map(\.component).contains("libsamplerate"))
    }

    /// **The claim the whole licensing position rests on.** The iPad binary
    /// contains 640 Signalsmith symbols and zero matching "rubberband", which is
    /// what makes an App Store build possible at all; a panel that told an iPad
    /// reader it contained GPL code would contradict the one fact the product's
    /// distribution terms depend on.
    ///
    /// Checkable from a Mac only because the platform is a parameter rather than
    /// a `#if` — which is the whole reason it is one.
    @Test("the iPadOS list mentions no Rubber Band and no GPL anywhere")
    func theIPadOSListNamesNoRubberBand() {
        for licence in AboutInfo.licences(on: .iPadOS) {
            let row = "\(licence.component) \(licence.terms) \(licence.detail)"
            #expect(!row.contains("Rubber Band"), "iPadOS row names Rubber Band: \(row)")
            #expect(!licence.terms.contains("GPL"), "iPadOS row claims GPL terms: \(row)")
        }
    }

    /// Both Signalsmith libraries, on both platforms. They are two repositories
    /// rather than one — `signalsmith-stretch.h` includes the other's headers —
    /// and MIT attribution is owed to each separately (`VENDOR.md`).
    @Test("every build attributes Artscripture and both Signalsmith libraries")
    func everyBuildAttributesTheVendoredLibraries() {
        for platform in AboutPlatform.allCases {
            let list = AboutInfo.licences(on: platform)
            let named = list.map(\.component)
            #expect(
                named.contains("Artscripture"),
                "\(platform.rawValue) does not name Artscripture")
            #expect(
                named.contains("Signalsmith Stretch"),
                "\(platform.rawValue) does not name Signalsmith Stretch")
            #expect(
                named.contains("Signalsmith Linear"),
                "\(platform.rawValue) does not name Signalsmith Linear")
            let artscribe = list.first { $0.component == "Artscripture" }
            #expect(artscribe?.terms == "Apache-2.0")
            for licence in list where licence.component.hasPrefix("Signalsmith") {
                #expect(licence.terms == "MIT", "\(licence.component) is not MIT")
            }
        }
    }

    /// Every row is filled in and appears once. `AboutLicence.id` is the
    /// component name, so a duplicate would silently collapse two attributions
    /// into one row in the `ForEach` that draws them.
    @Test("every licence row is complete, and each component appears once")
    func everyLicenceRowIsWellFormed() {
        for platform in AboutPlatform.allCases {
            let list = AboutInfo.licences(on: platform)
            for licence in list {
                #expect(!licence.component.isEmpty)
                #expect(!licence.terms.isEmpty)
                #expect(!licence.detail.isEmpty)
            }
            #expect(Set(list.map(\.id)).count == list.count, "\(platform.rawValue) has a duplicate")
        }
    }

    /// The list drawn by the running build is the one for the running build.
    /// Trivial, and the thing that breaks if `current` is ever written the wrong
    /// way round in a `#if`.
    @Test("the live list is the list for this platform")
    func theLiveListMatchesThisPlatform() {
        #expect(AboutInfo.licences == AboutInfo.licences(on: .current))
        #if os(macOS)
        #expect(AboutPlatform.current == .macOS)
        #else
        #expect(AboutPlatform.current == .iPadOS)
        #endif
    }

    // MARK: - The panel itself

    /// A panel, not a workspace: it is a centred column of four short lines, and
    /// the two constants are hoisted out of the frame modifier so this can hold
    /// them against each other rather than leave it to the eye.
    /// `@MainActor` because a `View`'s statics inherit its isolation, not
    /// because the check needs the main thread.
    @MainActor
    @Test("the About panel opens wider than it is tall")
    func theAboutPanelIsWiderThanItIsTall() {
        #expect(AboutWindow.minimumWidth > AboutWindow.minimumHeight)
        #expect(AboutWindow.minimumWidth < ShortcutWindow.minimumWidth)
    }
}
