import ArtscribeKit
import Foundation
import Testing

@testable import ArtscribeUI

/// The three nudge tiers: their amounts, the validation that keeps a nonsense
/// amount out of storage, the seconds→frames conversion, and the clamping at
/// both ends of the file.
///
/// All of it is pure, which is the point: the Settings window is not
/// snapshot-tested, so every decision it can make has to be reachable and
/// checkable without a view.
@Suite("Nudging")
struct NudgingTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    // MARK: - Amounts

    @Test("the shipped amounts are 50 ms, 2 s and 10 s")
    func defaultAmounts() {
        let amounts = NudgeAmounts.defaults
        #expect(amounts[.fine] == 0.05)
        #expect(amounts[.normal] == 2)
        #expect(amounts[.coarse] == 10)
    }

    @Test("every tier has a default and they are strictly increasing")
    func tiersAreOrdered() {
        let seconds = NudgeTier.allCases.map(\.defaultSeconds)
        #expect(seconds == [0.05, 2, 10])
        #expect(zip(seconds, seconds.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("a tier's amount can be set and read back")
    func roundTrip() {
        var amounts = NudgeAmounts.defaults
        amounts[.normal] = 3.5
        #expect(amounts[.normal] == 3.5)
        // The other tiers are untouched.
        #expect(amounts[.fine] == 0.05)
        #expect(amounts[.coarse] == 10)
    }

    // MARK: - Validation
    //
    // A nudge of 0 s silently does nothing, which is the exact
    // silent-degradation failure this project keeps finding. It must never
    // reach storage.

    @Test("zero is clamped to the minimum rather than stored")
    func zeroIsRejected() {
        var amounts = NudgeAmounts.defaults
        amounts[.normal] = 0
        #expect(amounts[.normal] == NudgeAmounts.minimumSeconds)
        #expect(amounts[.normal] > 0)
    }

    @Test("a negative amount is clamped to the minimum")
    func negativeIsRejected() {
        var amounts = NudgeAmounts.defaults
        amounts[.coarse] = -30
        #expect(amounts[.coarse] == NudgeAmounts.minimumSeconds)
    }

    @Test("an absurdly large amount is clamped to the maximum")
    func hugeIsClamped() {
        var amounts = NudgeAmounts.defaults
        amounts[.coarse] = 86_400
        #expect(amounts[.coarse] == NudgeAmounts.maximumSeconds)
    }

    @Test("a non-finite amount falls back to the tier's default")
    func nonFiniteFallsBack() {
        for value in [Double.nan, .infinity, -.infinity] {
            var amounts = NudgeAmounts.defaults
            amounts[.fine] = value
            #expect(amounts[.fine] == NudgeTier.fine.defaultSeconds)
        }
    }

    @Test("a value inside the range is stored exactly")
    func validValuesSurvive() {
        for value in [NudgeAmounts.minimumSeconds, 0.25, 5, NudgeAmounts.maximumSeconds] {
            var amounts = NudgeAmounts.defaults
            amounts[.normal] = value
            #expect(amounts[.normal] == value)
        }
    }

    // MARK: - Units and labels

    @Test("the fine tier is edited in milliseconds and the others in seconds")
    func units() {
        #expect(NudgeTier.fine.unit == .milliseconds)
        #expect(NudgeTier.normal.unit == .seconds)
        #expect(NudgeTier.coarse.unit == .seconds)
        #expect(NudgeTier.fine.unit.display(seconds: 0.05) == 50)
        #expect(NudgeTier.fine.unit.seconds(from: 50) == 0.05)
        #expect(NudgeTier.normal.unit.display(seconds: 2) == 2)
        #expect(NudgeTier.normal.unit.seconds(from: 2) == 2)
    }

    @Test("a display value survives a round trip through its unit")
    func unitRoundTrip() {
        for unit in [NudgeUnit.milliseconds, .seconds] {
            for seconds in [0.001, 0.05, 2.0, 10.0, 600.0] {
                let back = unit.seconds(from: unit.display(seconds: seconds))
                #expect(abs(back - seconds) < 1e-9)
            }
        }
    }

    @Test("amounts read as milliseconds below a second and seconds above it")
    func labels() {
        #expect(NudgeAmounts.label(seconds: 0.05) == "50 ms")
        #expect(NudgeAmounts.label(seconds: 0.001) == "1 ms")
        #expect(NudgeAmounts.label(seconds: 2) == "2 s")
        #expect(NudgeAmounts.label(seconds: 10) == "10 s")
        #expect(NudgeAmounts.label(seconds: 1.5) == "1.5 s")
        // Never "1000 ms": the boundary rounds into seconds, not out of them.
        #expect(NudgeAmounts.label(seconds: 0.9999) == "1 s")
        #expect(NudgeAmounts.label(seconds: .nan) == "—")
    }

    // MARK: - Seconds to frames

    @Test("seconds convert to frames at the file's sample rate")
    func framesFromSeconds() {
        #expect(NudgeStepping.frames(seconds: 2, sampleRate: 44100) == 88_200)
        #expect(NudgeStepping.frames(seconds: 0.05, sampleRate: 44100) == 2205)
        #expect(NudgeStepping.frames(seconds: 10, sampleRate: 48000) == 480_000)
        #expect(NudgeStepping.frames(seconds: -2, sampleRate: 44100) == -88_200)
    }

    @Test("a fractional frame rounds to the nearest, never to zero")
    func framesRound() {
        // 1 ms at 44100 is 44.1 frames.
        #expect(NudgeStepping.frames(seconds: 0.001, sampleRate: 44100) == 44)
        // And the smallest allowed amount never rounds away to nothing, even at
        // the lowest rate anything here is likely to decode at.
        #expect(NudgeStepping.frames(seconds: NudgeAmounts.minimumSeconds, sampleRate: 8000) >= 1)
    }

    @Test("an unusable sample rate converts to no movement at all")
    func framesGuardBadRate() {
        #expect(NudgeStepping.frames(seconds: 2, sampleRate: 0) == 0)
        #expect(NudgeStepping.frames(seconds: 2, sampleRate: -44100) == 0)
        #expect(NudgeStepping.frames(seconds: 2, sampleRate: .nan) == 0)
        #expect(NudgeStepping.frames(seconds: .nan, sampleRate: 44100) == 0)
    }

    // MARK: - Targets and clamping

    @Test("a nudge moves the playhead by the amount, in either direction")
    func targets() {
        let middle: FrameIndex = 220_500  // 5 s
        #expect(
            NudgeStepping.target(
                from: middle, bySeconds: 2, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == middle + 88_200)
        #expect(
            NudgeStepping.target(
                from: middle, bySeconds: -2, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == middle - 88_200)
    }

    @Test("nudging back from the start of the file clamps at zero")
    func clampsAtStart() {
        #expect(
            NudgeStepping.target(
                from: 0, bySeconds: -10, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == 0)
        // And from just inside it, rather than wrapping negative.
        #expect(
            NudgeStepping.target(
                from: 100, bySeconds: -10, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == 0)
    }

    @Test("nudging forward past the end of the file clamps at the last frame")
    func clampsAtEnd() {
        #expect(
            NudgeStepping.target(
                from: Self.totalFrames, bySeconds: 10, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == Self.totalFrames)
        #expect(
            NudgeStepping.target(
                from: Self.totalFrames - 100, bySeconds: 10, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == Self.totalFrames)
    }

    @Test("an amount longer than the whole file lands on the far end, not outside it")
    func clampsBothEndsWithHugeAmount() {
        #expect(
            NudgeStepping.target(
                from: 1000, bySeconds: 600, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == Self.totalFrames)
        #expect(
            NudgeStepping.target(
                from: Self.totalFrames - 1000, bySeconds: -600, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == 0)
    }

    @Test("with no track there is nowhere to go")
    func noTrack() {
        #expect(
            NudgeStepping.target(
                from: 0, bySeconds: 2, sampleRate: Self.sampleRate, totalFrames: 0) == 0)
    }

    /// The conversion runs on `Int64`, and a `Double` large enough to overflow it
    /// is exactly the kind of value a corrupted preference could hand over.
    @Test("an overflowing amount saturates instead of trapping")
    func overflowSaturates() {
        #expect(
            NudgeStepping.target(
                from: FrameIndex.max - 10, bySeconds: 1e18, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == Self.totalFrames)
        #expect(
            NudgeStepping.target(
                from: FrameIndex.min + 10, bySeconds: -1e18, sampleRate: Self.sampleRate,
                totalFrames: Self.totalFrames) == 0)
        #expect(NudgeStepping.frames(seconds: 1e18, sampleRate: Self.sampleRate) == FrameIndex.max)
    }

    // MARK: - Persistence

    private func makeSuite() -> UserDefaults {
        let name = "com.artscribe.tests.nudge.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create a defaults suite")
            return .standard
        }
        return defaults
    }

    @Test("with nothing stored, the shipped defaults are used")
    @MainActor
    func loadsDefaults() {
        let settings = NudgeSettings(defaults: makeSuite())
        #expect(settings.load() == NudgeAmounts.defaults)
    }

    @Test("amounts survive a save and load")
    @MainActor
    func savesAndLoads() {
        let defaults = makeSuite()
        var amounts = NudgeAmounts.defaults
        amounts[.normal] = 3
        amounts[.coarse] = 15
        NudgeSettings(defaults: defaults).save(amounts)
        #expect(NudgeSettings(defaults: defaults).load() == amounts)
    }

    /// Storage is not a trusted source. A value written by an older build, by
    /// `defaults write`, or by a partly failed save must not become a nudge that
    /// silently does nothing.
    @Test("a nonsense stored amount is validated on the way back in")
    @MainActor
    func loadValidates() {
        let defaults = makeSuite()
        defaults.set(0, forKey: NudgeSettings.key(for: .normal))
        defaults.set(1e9, forKey: NudgeSettings.key(for: .coarse))
        defaults.set("not a number", forKey: NudgeSettings.key(for: .fine))
        let loaded = NudgeSettings(defaults: defaults).load()
        #expect(loaded[.normal] == NudgeAmounts.minimumSeconds)
        #expect(loaded[.coarse] == NudgeAmounts.maximumSeconds)
        #expect(loaded[.fine] == NudgeTier.fine.defaultSeconds)
    }

    @Test("restoring defaults clears the stored values")
    @MainActor
    func restoreDefaults() {
        let defaults = makeSuite()
        let settings = NudgeSettings(defaults: defaults)
        var amounts = NudgeAmounts.defaults
        amounts[.normal] = 7
        settings.save(amounts)
        settings.save(.defaults)
        #expect(settings.load() == NudgeAmounts.defaults)
        // Nothing left behind to be resurrected by a later build with different
        // defaults.
        #expect(defaults.object(forKey: NudgeSettings.key(for: .normal)) == nil)
    }
}
