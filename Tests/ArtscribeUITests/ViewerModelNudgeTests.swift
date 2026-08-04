import ArtscribeKit
import AudioDecode
import Foundation
import Observation
import Testing
import Waveform

@testable import ArtscribeUI

/// The three nudge tiers as the keyboard and the Settings window drive them.
///
/// The arithmetic itself lives in `NudgingTests`; what is checked here is the
/// model's behaviour around it — the clamps at both ends of a real track, the
/// transport being left alone, the loop being left alone, and the amounts
/// reaching the action without a relaunch.
@MainActor
@Suite("ViewerModel nudging")
struct ViewerModelNudgeTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    private func makeModel(frames: FrameIndex = Self.totalFrames) -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(frames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: frames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    @Test("each tier moves the playhead by its own amount, both ways")
    func nudgeTiers() {
        // A minute long, so a 10 s rewind from the middle is a real move rather
        // than a clamp — the clamping is the next test's job.
        let model = makeModel(frames: FrameIndex(60 * Self.sampleRate))
        let middle: FrameIndex = FrameIndex(30 * Self.sampleRate)
        for (tier, seconds) in [(NudgeTier.fine, 0.05), (.normal, 2), (.coarse, 10)] {
            let frames = FrameIndex(seconds * Self.sampleRate)
            model.seek(to: middle)
            model.nudge(tier, direction: .forward)
            #expect(model.playhead == middle + frames)
            model.nudge(tier, direction: .backward)
            #expect(model.playhead == middle)
        }
    }

    @Test("nudging clamps at both ends of the file instead of misbehaving")
    func nudgeClamps() {
        let model = makeModel()
        model.seek(to: 1000)
        model.nudge(.coarse, direction: .backward)
        #expect(model.playhead == 0)
        // Pressing it again at the boundary holds. That `nudge` also declines to
        // push a redundant `.seek` — which would reset the stretcher and click —
        // is not observable from here: without a session there is no ring to
        // watch, and re-assigning an equal `playhead` is silent under
        // `@Observable`. It is guarded at the call site, not by this test.
        model.nudge(.coarse, direction: .backward)
        #expect(model.playhead == 0)

        model.seek(to: Self.totalFrames - 1000)
        model.nudge(.coarse, direction: .forward)
        #expect(model.playhead == Self.totalFrames)
        model.nudge(.coarse, direction: .forward)
        #expect(model.playhead == Self.totalFrames)
    }

    /// Whether or not playback is running — and it must not stop, start, or
    /// restart it either way. The only thing a nudge is allowed to push is
    /// `.seek`.
    @Test("nudging while the transport is running leaves it running")
    func nudgeDoesNotDisturbTheTransport() {
        let model = makeModel()
        model.seek(to: 100_000)
        model.transport.request(true, now: 0)
        #expect(model.pollTransport(enginePlaying: true, now: 0.1) == .started)
        #expect(model.isPlaying)

        model.nudge(.normal, direction: .forward)
        #expect(model.playhead == 100_000 + 88_200)
        #expect(model.isPlaying)

        model.nudge(.normal, direction: .backward)
        #expect(model.playhead == 100_000)
        #expect(model.isPlaying)
    }

    /// The documented decision (matching Transcribe!): a nudge may leave the
    /// loop. The tier you reach for when the phrase starts a beat earlier than
    /// you set the in point is exactly the one that has to cross it, and `F` is
    /// one key away when you want to be back inside.
    @Test("a nudge may leave an active loop region, and leaves the loop alone")
    func nudgeMayLeaveTheLoop() {
        let model = makeModel()
        model.seek(to: 200_000)
        model.setLoopIn()
        model.seek(to: 300_000)
        model.setLoopOut()
        model.toggleLoop()
        let loop = model.loop
        #expect(loop.isActive)

        model.seek(to: 210_000)
        model.nudge(.coarse, direction: .backward)
        #expect(model.playhead < loop.range.start)
        // The loop itself is untouched: it is still there, still enabled, and
        // `F` still goes back to it.
        #expect(model.loop == loop)
        model.restartLoop()
        #expect(model.playhead == loop.range.start)
    }

    @Test("a changed amount takes effect on the very next nudge, and restores")
    func nudgeAmountsApplyLive() {
        let model = makeModel()
        model.prefs.setNudgeAmount(5, for: .normal)
        #expect(model.prefs.nudgeAmounts[.normal] == 5)
        model.seek(to: 0)
        model.nudge(.normal, direction: .forward)
        #expect(model.playhead == FrameIndex(5 * Self.sampleRate))

        model.prefs.restoreDefaultNudgeAmounts()
        #expect(model.prefs.nudgeAmounts == NudgeAmounts.defaults)
        model.seek(to: 0)
        model.nudge(.normal, direction: .forward)
        #expect(model.playhead == FrameIndex(2 * Self.sampleRate))
    }

    @Test("an amount the model is asked to store is validated first")
    func nudgeAmountsAreValidated() {
        let model = makeModel()
        model.prefs.setNudgeAmount(0, for: .normal)
        #expect(model.prefs.nudgeAmounts[.normal] == NudgeAmounts.minimumSeconds)
        // Which is the whole point: a nudge still moves.
        model.seek(to: 0)
        model.nudge(.normal, direction: .forward)
        #expect(model.playhead > 0)
    }

    @Test("nudging is a no-op with no track loaded")
    func nudgeWithoutTrack() {
        let model = ViewerModel()
        for tier in NudgeTier.allCases {
            model.nudge(tier, direction: .forward)
            model.nudge(tier, direction: .backward)
        }
        #expect(model.playhead == 0)
    }

    /// The `_modify` trap, guarded where this task could have reintroduced it:
    /// the nudge path reads the amounts and must never write them, or every
    /// press would invalidate the Playback menu's titles.
    @Test("nudging never invalidates an observer of the amounts")
    func nudgingDoesNotInvalidateTheAmounts() {
        let model = makeModel()
        let counter = InvalidationCounter()
        withObservationTracking {
            _ = model.prefs.nudgeAmounts
        } onChange: {
            MainActor.assumeIsolated { counter.bump() }
        }
        model.seek(to: 100_000)
        for _ in 0..<50 {
            model.nudge(.normal, direction: .forward)
            model.nudge(.normal, direction: .backward)
        }
        #expect(counter.count == 0)
    }

    // MARK: - The redundant seek, and the counter that watches for one

    /// `.seek` is one of the two paths that reset the stretcher, and a reset at
    /// a loop boundary clicks — this project's most important defect class. `F`
    /// pressed twice, or the lock screen's ⟲ leant on blind against an enabled
    /// loop, must not issue the second one. The nudge keys above have guarded
    /// this since Task 14; `restartLoop` did not.
    @Test("F on the in point issues no second seek")
    func restartOnTheInPointIsANoOp() {
        let model = makeModel()
        model.seek(to: 100_000)
        model.setLoopIn()
        model.seek(to: 300_000)
        model.setLoopOut()
        model.restartLoop()
        #expect(model.playhead == 100_000)

        let seeks = model.seekGeneration
        model.restartLoop()
        #expect(model.playhead == 100_000)
        #expect(model.seekGeneration == seeks, "a redundant seek would reset the stretcher")
    }

    /// The lock screen's clock is anchored on this counter — it is how a skip
    /// forward is told from ordinary playback, which is the same pair of
    /// numbers. See `NowPlayingSnapshot.seekGeneration`.
    @Test("every deliberate jump moves the seek counter, and a refused one does not")
    func seekGenerationCountsUserJumps() {
        let model = makeModel()
        let start = model.seekGeneration
        model.seek(to: 100_000)
        #expect(model.seekGeneration == start + 1)

        // A seek onto the frame the playhead already occupies — what a skip
        // clamped at the end of the track produces. Still a seek, and the lock
        // screen still has to hear about it, because its own ⟳ produced it.
        model.seek(to: 100_000)
        #expect(model.seekGeneration == start + 2)

        // A nudge goes out through `seek(to:)`, so it counts…
        model.nudge(.normal, direction: .forward)
        #expect(model.seekGeneration == start + 3)

        // …and one refused at the end of the file does not.
        model.seek(to: Self.totalFrames)
        let atEnd = model.seekGeneration
        model.nudge(.coarse, direction: .forward)
        #expect(model.seekGeneration == atEnd)
    }

    @Test("attaching a store adopts what it holds")
    func nudgeSettingsAreAdopted() {
        let name = "com.artscripture.tests.model.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create a defaults suite")
            return
        }
        var stored = NudgeAmounts.defaults
        stored[.coarse] = 30
        NudgeSettings(defaults: defaults).save(stored)

        let model = makeModel()
        model.prefs.adopt(nudge: NudgeSettings(defaults: defaults))
        #expect(model.prefs.nudgeAmounts[.coarse] == 30)
        // And an edit goes back out to the same store.
        model.prefs.setNudgeAmount(20, for: .coarse)
        #expect(NudgeSettings(defaults: defaults).load()[.coarse] == 20)
    }
}
