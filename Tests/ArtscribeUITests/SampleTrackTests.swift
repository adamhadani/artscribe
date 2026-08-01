import AudioDecode
import Foundation
import Testing

@testable import ArtscribeUI

/// The bundled sample track: that it is actually in the bundle, and the rule
/// for when it is offered.
@Suite("Sample track")
struct SampleTrackTests {

    /// The offer exists for an app with nothing in it. One recent file is
    /// enough to mean the user has their own material and the list below is the
    /// better thing to show.
    @Test("offered only when there are no recents")
    func offeredOnlyOnAnEmptyApp() {
        #expect(SampleTrack.isOffered(recentCount: 0))
        #expect(!SampleTrack.isOffered(recentCount: 1))
        #expect(!SampleTrack.isOffered(recentCount: 8))
    }

    /// The rule is about *state*, not about having been shown once. Clearing
    /// the recents puts the app back to empty, and an empty app should offer
    /// the sample again rather than leave the screen with nothing on it.
    @Test("clearing the recents brings the offer back")
    func clearingRecentsRestoresTheOffer() {
        #expect(!SampleTrack.isOffered(recentCount: 3))
        #expect(SampleTrack.isOffered(recentCount: 0))
    }

    /// The resource resolves at runtime.
    ///
    /// Weaker than it looks, and worth being honest about: SwiftPM catches both
    /// obvious packaging mistakes at *build* time — omitting `resources:` makes
    /// `Bundle.module` a compile error, and misspelling the path fails the build
    /// with "missing inputs". Both were tried. What this adds is the runtime
    /// half, and a size that would notice a truncated or accidentally swapped
    /// file.
    ///
    /// The case none of it covers is the resource failing to reach the *app*
    /// bundle rather than the test bundle — that is an Xcode/xcodegen path, and
    /// checking it means looking inside a built `.app`.
    @Test("the audio is actually in the resource bundle")
    func resourceIsBundled() throws {
        let url = try #require(SampleTrack.bundledURL, "the sample is missing from the bundle")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        // Big enough to be audio rather than a truncated placeholder, small
        // enough to notice if someone drops an album in here.
        #expect((100_000...1_000_000).contains(size ?? 0), "unexpected size: \(size ?? -1) bytes")
    }

    /// **The check the build cannot make**: that the bytes are audio this app
    /// can actually play.
    ///
    /// A demo track that fails to decode is worse than none — it turns the one
    /// thing offered on an empty screen into an error message, in front of the
    /// reviewer it exists to satisfy. `.copy` rather than `.process` in
    /// `Package.swift` is what keeps the toolchain from re-encoding it into
    /// something else; this is what would notice if that changed.
    @Test("the sample decodes, in stereo, at the length it claims")
    func sampleDecodes() async throws {
        let url = try #require(SampleTrack.bundledURL)
        let audio = try await AudioFileDecoder.decode(url: url)
        #expect(audio.channels == 2, "the waveform draws one lane per channel")
        #expect(audio.sampleRate == 44_100)
        let seconds = audio.duration
        #expect((27.0...29.0).contains(seconds), "expected ~28 s, got \(seconds)")
    }

    /// The credit names the performer and the licence, because the entry that
    /// matters legally is the *recording*, not the composition.
    @Test("the credit names the performer and CC0")
    func creditIsSpecific() {
        #expect(SampleTrack.credit.contains("Ishizaka"))
        #expect(SampleTrack.credit.contains("CC0"))
        #expect(SampleTrack.source.contains("archive.org"))
    }
}

/// What the resting screen says, per platform.
///
/// The bug: "Drop an audio file here" shipped to iPhone, where dragging a file
/// in needs two apps on screen and there is no Split View — so a first-time user
/// was told to do something the device cannot do.
@Suite("Empty-state prompt")
struct EmptyStatePromptTests {

    /// The phone must not be told to drop anything, and must not be offered a
    /// keyboard shortcut it has no keyboard for.
    @Test("the phone is never told to drop or to press a key")
    func phoneSaysNeitherDropNorChord() {
        let headline = EmptyStatePrompt.headline(for: .phone)
        let hint = EmptyStatePrompt.hint(for: .phone)
        #expect(!headline.lowercased().contains("drop"))
        #expect(!hint.lowercased().contains("drop"))
        #expect(!hint.contains("⌘"))
    }

    /// iPad keeps the drop, because there it genuinely works.
    @Test("the tablet still offers the drop")
    func tabletKeepsTheDrop() {
        #expect(EmptyStatePrompt.headline(for: .tabletWithDrop).lowercased().contains("drop"))
        #expect(!EmptyStatePrompt.hint(for: .tabletWithDrop).contains("⌘"))
    }

    /// Only the desktop names a key equivalent.
    @Test("only the desktop names a chord")
    func onlyDesktopNamesAChord() {
        #expect(EmptyStatePrompt.hint(for: .desktop).contains("⌘O"))
    }

    /// Every surface says something. An empty string here would leave the
    /// emptiest screen in the app blank.
    @Test("no surface is left without words")
    func nothingIsBlank() {
        for surface in [EmptyStatePrompt.Surface.desktop, .tabletWithDrop, .phone] {
            #expect(!EmptyStatePrompt.headline(for: surface).isEmpty)
            #expect(!EmptyStatePrompt.hint(for: surface).isEmpty)
        }
    }
}

/// The guidance shown when Practice has nothing to work with.
///
/// It used to say *"press A … press S … press G"* and *"File ▸ Open… (⌘O), or
/// drop an audio file on the window"* — every instruction impossible on a touch
/// device, shown at exactly the moment somebody is stuck and reading carefully.
@Suite("No-loop guidance")
struct LoopGuidanceTests {

    @Test("touch surfaces are never told to press a letter key")
    func touchIsNotToldToPressKeys() {
        for surface in [EmptyStatePrompt.Surface.tabletWithDrop, .phone] {
            let loop = EmptyStatePrompt.loopGuidance(for: surface)
            #expect(!loop.contains("press "), "\(surface) is told to press a key")
            #expect(!loop.contains("⌘"))
        }
    }

    /// …and are pointed at the control that actually exists there. Naming it is
    /// the point: the button was added because touch had no route to a loop.
    @Test("touch surfaces are pointed at the Selection → Loop button")
    func touchNamesTheButton() {
        for surface in [EmptyStatePrompt.Surface.tabletWithDrop, .phone] {
            #expect(EmptyStatePrompt.loopGuidance(for: surface).contains("Selection → Loop"))
        }
    }

    /// The phone is never told to drop a file or to use a File menu it has not
    /// got.
    @Test("the phone is not sent to a File menu or told to drop")
    func phoneOpenGuidanceIsPossible() {
        let open = EmptyStatePrompt.openGuidance(for: .phone)
        #expect(!open.lowercased().contains("drop"))
        #expect(!open.contains("▸"))
        #expect(!open.contains("⌘"))
    }

    /// The desktop keeps its keys — this is a keyboard-first app there, and
    /// softening it everywhere would be the opposite mistake.
    @Test("the desktop still names its keys")
    func desktopKeepsItsKeys() {
        #expect(EmptyStatePrompt.loopGuidance(for: .desktop).contains("press A"))
        #expect(EmptyStatePrompt.openGuidance(for: .desktop).contains("⌘O"))
    }
}

/// The About panel's one line of prose.
@Suite("About tagline")
struct AboutTaglineTests {

    /// "Keyboard-first" describes an app a phone user cannot use as advertised,
    /// and About is where the app introduces itself.
    @Test("the phone is not sold a keyboard-first app")
    func phoneIsNotPromisedAKeyboard() {
        #expect(!AboutInfo.tagline(for: .phone).lowercased().contains("keyboard"))
    }

    /// Where a keyboard is the point, it stays the point. Softening it
    /// everywhere would be the opposite mistake.
    @Test("desktop and tablet keep the claim")
    func desktopAndTabletKeepIt() {
        #expect(AboutInfo.tagline(for: .desktop).lowercased().contains("keyboard"))
        #expect(AboutInfo.tagline(for: .tabletWithDrop).lowercased().contains("keyboard"))
    }

    @Test("every surface says something about transcription or looping")
    func everySurfaceDescribesTheApp() {
        for surface in [EmptyStatePrompt.Surface.desktop, .tabletWithDrop, .phone] {
            let line = AboutInfo.tagline(for: surface).lowercased()
            #expect(line.contains("transcription") || line.contains("loop"))
        }
    }
}
