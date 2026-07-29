import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// Task 29's preroll: where a `Space` resume starts from.
///
/// The arithmetic is one function with four boundaries — off, the file start, an
/// active loop's in point, and the end of the file — which is exactly why it is
/// pure and lives outside `ViewerModel`. See `Preroll`.
@Suite("Preroll arithmetic")
struct PrerollTests {

    private static let rate: Double = 44100
    private static let total: FrameIndex = 441_000  // 10 s

    private static func seconds(_ s: Double) -> FrameIndex { FrameIndex(s * rate) }

    // MARK: - The amount itself

    @Test("the shipped preroll is two seconds")
    func theDefault() {
        #expect(Preroll.defaultSeconds == 2)
    }

    /// The one place this type deliberately disagrees with `NudgeAmounts`: zero
    /// is **allowed** and means off. A nudge of zero is a key that silently does
    /// nothing; a preroll of zero is "resume exactly where I stopped", which is
    /// a coherent thing to ask for and is what the app did before the feature.
    @Test("zero is an allowed preroll and means off")
    func zeroIsAllowed() {
        #expect(Preroll.validated(0) == 0)
        #expect(
            Preroll.target(
                from: Self.seconds(5), seconds: 0, sampleRate: Self.rate,
                totalFrames: Self.total, loop: LoopRegion()) == Self.seconds(5))
    }

    @Test("a negative preroll is clamped to off rather than rolling forwards")
    func negativeIsClamped() {
        #expect(Preroll.validated(-1) == 0)
    }

    @Test("an absurd preroll is clamped to the same ceiling as the nudge amounts")
    func absurdIsClamped() {
        #expect(Preroll.validated(10_000) == NudgeAmounts.maximumSeconds)
    }

    /// Not a number at all — a corrupted preference, or a field left mid-edit —
    /// falls back to the default rather than to an arbitrary end of the range,
    /// exactly as `NudgeAmounts.validated` does.
    @Test("a value that is not a number falls back to the default")
    func nonFiniteFallsBack() {
        #expect(Preroll.validated(.nan) == Preroll.defaultSeconds)
        #expect(Preroll.validated(.infinity) == Preroll.defaultSeconds)
    }

    // MARK: - Where it lands

    @Test("the default rolls back two seconds")
    func rollsBackTheDefault() {
        let target = Preroll.target(
            from: Self.seconds(5), seconds: Preroll.defaultSeconds, sampleRate: Self.rate,
            totalFrames: Self.total, loop: LoopRegion())
        #expect(target == Self.seconds(3))
    }

    @Test("a fractional preroll is honoured")
    func fractional() {
        let target = Preroll.target(
            from: Self.seconds(5), seconds: 0.5, sampleRate: Self.rate,
            totalFrames: Self.total, loop: LoopRegion())
        #expect(target == Self.seconds(4.5))
    }

    @Test("a preroll that would go before the file start clamps to zero")
    func clampsAtTheFileStart() {
        let target = Preroll.target(
            from: Self.seconds(1), seconds: 2, sampleRate: Self.rate,
            totalFrames: Self.total, loop: LoopRegion())
        #expect(target == 0)
    }

    @Test("a preroll from the file start stays at the file start")
    func alreadyAtZero() {
        let target = Preroll.target(
            from: 0, seconds: 2, sampleRate: Self.rate, totalFrames: Self.total,
            loop: LoopRegion())
        #expect(target == 0)
    }

    /// No track: there is nowhere to roll back to and no sample rate worth
    /// trusting, so the answer is the only frame that certainly exists.
    @Test("an empty file prerolls to zero")
    func emptyFile() {
        let target = Preroll.target(
            from: 0, seconds: 2, sampleRate: Self.rate, totalFrames: 0, loop: LoopRegion())
        #expect(target == 0)
    }

    @Test("an unusable sample rate leaves the playhead alone")
    func unusableSampleRate() {
        let target = Preroll.target(
            from: Self.seconds(5), seconds: 2, sampleRate: 0, totalFrames: Self.total,
            loop: LoopRegion())
        #expect(target == Self.seconds(5))
    }

    // MARK: - An active loop

    private static let loop = LoopRegion(
        range: FrameRange(start: seconds(4), count: seconds(3)), isEnabled: true)

    /// **The decision.** Inside an active loop the preroll floors at the in
    /// point instead of escaping the region.
    ///
    /// The alternative was to let it out: Task 24 established that the engine
    /// honours an explicit seek and that the loop captures on *arrival*, so a
    /// preroll landing before the in point would play a lead-in once and then be
    /// caught at the out point and never play it again. That is a lead-in you
    /// get on the first repetition only, which is precisely the "the app is
    /// following two rules" complaint Task 22 existed to kill. A loop is the
    /// user's explicit statement of which passage they are working on, and
    /// resuming inside it is what keeps that statement true.
    @Test("inside an active loop the preroll floors at the loop's in point")
    func flooredAtTheLoopStart() {
        let target = Preroll.target(
            from: Self.seconds(5), seconds: 2, sampleRate: Self.rate,
            totalFrames: Self.total, loop: Self.loop)
        #expect(target == Self.seconds(4))
    }

    @Test("inside an active loop a preroll that stays inside is untouched")
    func insideTheLoopIsUntouched() {
        let target = Preroll.target(
            from: Self.seconds(6.5), seconds: 2, sampleRate: Self.rate,
            totalFrames: Self.total, loop: Self.loop)
        #expect(target == Self.seconds(4.5))
    }

    /// A playhead outside the loop is not being governed by it — the user
    /// nudged out, or clicked away — so the loop has no floor to contribute and
    /// the ordinary file clamp applies. The engine's capture-on-arrival is
    /// unchanged either way.
    @Test("a playhead outside an active loop is not floored by it")
    func outsideTheLoop() {
        let target = Preroll.target(
            from: Self.seconds(9), seconds: 2, sampleRate: Self.rate,
            totalFrames: Self.total, loop: Self.loop)
        #expect(target == Self.seconds(7))
    }

    @Test("a loop the user switched off contributes no floor")
    func disabledLoop() {
        var disabled = Self.loop
        disabled.isEnabled = false
        let target = Preroll.target(
            from: Self.seconds(5), seconds: 2, sampleRate: Self.rate,
            totalFrames: Self.total, loop: disabled)
        #expect(target == Self.seconds(3))
    }

    @Test("an enabled but zero-length loop contributes no floor")
    func emptyLoop() {
        let empty = LoopRegion(
            range: FrameRange(start: Self.seconds(4), count: 0), isEnabled: true)
        let target = Preroll.target(
            from: Self.seconds(5), seconds: 2, sampleRate: Self.rate,
            totalFrames: Self.total, loop: empty)
        #expect(target == Self.seconds(3))
    }

    // MARK: - Compounding

    /// **The decision.** Two pause-and-resumes roll back twice.
    ///
    /// It is the same gesture repeated and each press is a fresh resume from
    /// wherever the playhead now is, so making the second one stay put would
    /// mean remembering "we already prerolled" — invisible state that the user
    /// could not see and could not clear. It is also useful: walking backwards
    /// two seconds at a time is how you find the start of a phrase you keep
    /// missing. It is bounded, by the file start and by an active loop's in
    /// point, so it cannot walk anywhere surprising.
    @Test("prerolling twice rolls back twice")
    func compounds() {
        let first = Preroll.target(
            from: Self.seconds(8), seconds: 2, sampleRate: Self.rate,
            totalFrames: Self.total, loop: LoopRegion())
        let second = Preroll.target(
            from: first, seconds: 2, sampleRate: Self.rate, totalFrames: Self.total,
            loop: LoopRegion())
        #expect(first == Self.seconds(6))
        #expect(second == Self.seconds(4))
    }

    @Test("compounding inside a loop still cannot escape it")
    func compoundingIsBoundedByTheLoop() {
        var at = Self.seconds(6.5)
        for _ in 0..<5 {
            at = Preroll.target(
                from: at, seconds: 2, sampleRate: Self.rate, totalFrames: Self.total,
                loop: Self.loop)
        }
        #expect(at == Self.seconds(4))
    }
}

/// The preroll as the model applies it, and as Settings edits it.
///
/// `loadForTesting` leaves the playback session nil, so `play()` cannot succeed
/// here — which is why the resume point is checked through `prerollTarget`, the
/// frame `togglePlayPause` seeks to, rather than by pressing play. The keystroke
/// itself is driven in the acceptance run's `playback` group, where there is a
/// real audio graph.
@MainActor
@Suite("Preroll through the model")
struct ViewerModelPrerollTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: Self.totalFrames,
            storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    private func makeSuite() -> UserDefaults {
        let name = "com.artscribe.tests.preroll.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create a defaults suite")
            return .standard
        }
        return defaults
    }

    @Test("a fresh model is on the shipped default")
    func shippedDefault() {
        #expect(makeModel().prerollSeconds == Preroll.defaultSeconds)
    }

    @Test("the resume point is the playhead less the preroll")
    func resumePoint() {
        let model = makeModel()
        model.seek(to: 220_500)  // 5 s
        #expect(model.prerollTarget == 220_500 - FrameIndex(2 * Self.sampleRate))
    }

    @Test("a preroll of zero resumes exactly where it stopped")
    func offResumesInPlace() {
        let model = makeModel()
        model.setPrerollSeconds(0)
        model.seek(to: 220_500)
        #expect(model.prerollTarget == 220_500)
    }

    /// Parked at the end, `play()` rewinds to the selection start or to zero
    /// (`TransportLatch.rewindTarget`) — that press means "play it again", and a
    /// preroll that first stepped back two seconds would cancel the rewind and
    /// play the last two seconds of the file instead.
    @Test("at the end of the file the rewind wins and the preroll stands aside")
    func atTheEndTheRewindWins() {
        let model = makeModel()
        model.seek(to: Self.totalFrames)
        #expect(model.prerollTarget == Self.totalFrames)
    }

    @Test("an active loop floors the resume at its in point")
    func flooredByTheLoop() {
        let model = makeModel()
        model.seek(to: 176_400)  // 4 s
        model.setLoopIn()
        model.seek(to: 308_700)  // 7 s
        model.setLoopOut()
        if !model.loop.isEnabled { model.toggleLoop() }
        model.seek(to: 220_500)  // 5 s, one second into the loop
        #expect(model.prerollTarget == 176_400)
    }

    // MARK: - The preference

    @Test("Settings validates on the way in, so a negative cannot be stored")
    func settingsValidates() {
        let model = makeModel()
        model.setPrerollSeconds(-5)
        #expect(model.prerollSeconds == 0)
        model.setPrerollSeconds(.nan)
        #expect(model.prerollSeconds == Preroll.defaultSeconds)
    }

    @Test("a changed preroll counts as a non-default preference and Restore puts it back")
    func restoreDefaults() {
        let model = makeModel()
        #expect(!model.hasNonDefaultPreferences)
        model.setPrerollSeconds(0.75)
        #expect(model.hasNonDefaultPreferences)
        model.restoreDefaults()
        #expect(model.prerollSeconds == Preroll.defaultSeconds)
        #expect(!model.hasNonDefaultPreferences)
    }

    @Test("the preroll survives a relaunch")
    func persisted() {
        let defaults = makeSuite()
        let model = makeModel()
        model.attach(preroll: PrerollSettings(defaults: defaults))
        model.setPrerollSeconds(1.25)
        #expect(PrerollSettings(defaults: defaults).load() == 1.25)

        let reopened = makeModel()
        reopened.attach(preroll: PrerollSettings(defaults: defaults))
        #expect(reopened.prerollSeconds == 1.25)
    }

    /// Storage is not a trusted source. `0` is the value that separates this
    /// store from `NudgeSettings`: there, zero must never be installed; here it
    /// is a legitimate stored value meaning off, so "absent" and "zero" have to
    /// be told apart — which is why the load reads `object(forKey:)`.
    @Test("a stored zero is read back as off rather than as absent")
    func storedZeroSurvives() {
        let defaults = makeSuite()
        PrerollSettings(defaults: defaults).save(0)
        #expect(PrerollSettings(defaults: defaults).load() == 0)
    }

    @Test("a corrupted stored preroll is validated on the way in")
    func storedNonsenseIsValidated() {
        let defaults = makeSuite()
        defaults.set(-9, forKey: PrerollSettings.key)
        #expect(PrerollSettings(defaults: defaults).load() == 0)
        defaults.set("two", forKey: PrerollSettings.key)
        #expect(PrerollSettings(defaults: defaults).load() == Preroll.defaultSeconds)
    }

    @Test("a preroll back at its default is not left behind in storage")
    func defaultIsNotPersisted() {
        let defaults = makeSuite()
        let settings = PrerollSettings(defaults: defaults)
        settings.save(1.25)
        #expect(defaults.object(forKey: PrerollSettings.key) != nil)
        settings.save(Preroll.defaultSeconds)
        #expect(defaults.object(forKey: PrerollSettings.key) == nil)
    }
}
