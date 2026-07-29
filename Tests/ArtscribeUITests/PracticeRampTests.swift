import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// **The Practice hub against the model**, driven through the same door the
/// display link uses.
///
/// `SpeedRampTests` proves the arithmetic and the wrap rule in isolation. What
/// is left, and what this covers, is everything that only exists once the two
/// are wired to a transport: that the ramp reaches the *speed* through the
/// keyboard's own path, that it enables a loop it was handed switched off, that
/// a seek is not mistaken for a repetition, and — the load-bearing one — that
/// what moves it is a wrap and not the passage of time.
///
/// No audio device is opened: `loadForTesting` leaves the playback session nil,
/// so `notePlayhead` is fed the positions the display link would have polled.
/// That is the honest seam — it is the same method `tickPlayback` calls with the
/// engine's audible frame, one line below the poll.
@MainActor
@Suite("Practice ramp")
struct PracticeRampTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    /// A four-second loop, three seconds in — a realistic practice region, and
    /// long enough that half of it is unambiguous.
    private static let loopStart: FrameIndex = 132_300
    private static let loopCount: FrameIndex = 176_400

    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: Self.totalFrames,
            storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    /// A model with an enabled loop, ready to ramp.
    private func makeLoopedModel(enabled: Bool = true) -> ViewerModel {
        let model = makeModel()
        model.seek(to: Self.loopStart)
        model.setLoopIn()
        model.seek(to: Self.loopStart + Self.loopCount)
        model.setLoopOut()
        if enabled != model.loop.isEnabled { model.toggleLoop() }
        return model
    }

    /// Plays one whole repetition, sampled `polls` times, and reports whether a
    /// wrap was seen. The final position is just inside the loop's in point,
    /// which is where the engine puts the playhead when it goes round.
    @discardableResult
    private func playOneRepetition(_ model: ViewerModel, polls: Int = 12) -> Bool {
        let start = model.loop.range.start
        let span = model.loop.range.count - 1
        for step in 1...polls {
            model.notePlayhead(start + span * FrameIndex(step) / FrameIndex(polls))
        }
        let before = model.ramp.index
        model.notePlayhead(start + 512)
        return model.ramp.index != before || model.ramp.phase == .complete
    }

    // MARK: - Starting

    @Test("a ramp cannot start without a loop region, and the window says why")
    func aRampNeedsALoop() {
        let model = makeModel()
        #expect(!model.canRamp)
        model.startRamp()
        #expect(model.ramp.isIdle, "a ramp started with no loop")
        #expect(model.speed.ratio == 1.0, "starting a refused ramp changed the speed")

        // And a model with no track at all cannot either — the window offers the
        // Open route in that case (see `NoLoopGuidance`).
        let empty = ViewerModel()
        #expect(!empty.canRamp)
        empty.startRamp()
        #expect(empty.ramp.isIdle)
    }

    @Test("starting sets the first repetition's speed and goes to the loop's in point")
    func startingArmsTheFirstRepetition() {
        let model = makeLoopedModel()
        model.seek(to: Self.loopStart + 90_000)
        model.startRamp()

        #expect(model.ramp.isRunning)
        #expect(model.ramp.repetition == 1)
        #expect(model.ramp.total == 10)
        #expect(model.speed.ratio == RampSchedule.defaultStartRatio)
        #expect(
            model.playhead == model.loop.range.start,
            "the first repetition has to be a whole one")
    }

    /// A region that exists but is switched off is one keystroke from being what
    /// was meant. Starting the ramp is that keystroke.
    @Test("starting a ramp switches looping on when only the region is set")
    func startingEnablesTheLoop() {
        let model = makeLoopedModel(enabled: false)
        #expect(!model.loop.isEnabled)
        #expect(model.canRamp, "a region with looping off is still rampable")

        model.startRamp()
        #expect(model.loop.isEnabled)
        #expect(model.loop.isActive)
        #expect(model.ramp.isRunning)
    }

    // MARK: - Advancing

    /// The headline behaviour: one wrap, one step, at the schedule's speeds.
    @Test("each loop wrap steps the speed to the next repetition's")
    func eachWrapStepsTheSpeed() {
        let model = makeLoopedModel()
        model.setRampSchedule(
            RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 5))
        model.startRamp()

        var speeds = [model.speed.ratio]
        for _ in 0..<4 {
            playOneRepetition(model)
            speeds.append(model.speed.ratio)
        }
        #expect(speeds == [0.5, 0.625, 0.75, 0.875, 1.0])
        #expect(model.ramp.repetition == 5)
        #expect(model.ramp.remaining == 0)
    }

    /// **The one that says this is not a timer.**
    ///
    /// The same two repetitions are polled at three very different rates — four
    /// samples a pass and four hundred — and the ramp lands on the same
    /// repetition and the same speed every time. A ramp driven by elapsed time,
    /// or by a count of observations, could not do that; nor could one whose step
    /// depended on how often the display link happened to fire.
    @Test("the ramp advances per wrap, not per poll or per unit of time")
    func advancingIsDrivenByWrapsAndNotByTime() {
        for polls in [4, 40, 400] {
            let model = makeLoopedModel()
            model.setRampSchedule(
                RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 5))
            model.startRamp()

            playOneRepetition(model, polls: polls)
            playOneRepetition(model, polls: polls)
            #expect(
                model.ramp.repetition == 3,
                "\(polls) polls a repetition left the ramp on \(model.ramp.repetition)")
            #expect(model.speed.ratio == 0.75)
        }
    }

    /// Time visibly passing without the loop going round must move nothing —
    /// which is the same statement from the other side.
    @Test("polls that never wrap advance nothing, however many arrive")
    func pollingWithoutWrappingChangesNothing() {
        let model = makeLoopedModel()
        model.startRamp()
        let start = model.loop.range.start
        let span = model.loop.range.count - 1

        // Two hundred polls that only ever move forward: several repetitions'
        // worth of wall clock, and not one boundary crossed.
        for step in 0...200 {
            model.notePlayhead(start + span * FrameIndex(step) / 200)
        }
        #expect(model.ramp.repetition == 1)
        #expect(model.speed.ratio == RampSchedule.defaultStartRatio)
    }

    /// A deliberate jump backwards is shaped exactly like a wrap. Pressing `F`
    /// to hear the phrase again must not cost a repetition.
    @Test("restarting the loop by hand is not counted as a repetition")
    func aSeekIsNotAWrap() {
        let model = makeLoopedModel()
        model.startRamp()
        let start = model.loop.range.start

        model.notePlayhead(start + model.loop.range.count - 2000)
        // `F`, straight back to the in point — the same movement a wrap makes.
        model.restartLoop()
        model.notePlayhead(start + 400)
        #expect(model.ramp.repetition == 1, "a manual restart counted as a wrap")
        #expect(model.speed.ratio == RampSchedule.defaultStartRatio)

        // And a nudge back into the loop, likewise.
        model.notePlayhead(start + model.loop.range.count - 2000)
        model.nudge(.coarse, direction: .backward)
        model.notePlayhead(start + 800)
        #expect(model.ramp.repetition == 1)
    }

    /// Moving the loop's edges under a running ramp changes the geometry the
    /// wrap is measured against, so the baseline has to go with it.
    @Test("editing the loop under a running ramp does not fake a wrap")
    func editingTheLoopDoesNotFakeAWrap() {
        let model = makeLoopedModel()
        model.startRamp()
        model.notePlayhead(model.loop.range.start + model.loop.range.count - 2000)

        model.moveLoop(.inPoint, .aggressive, direction: .forward)
        model.notePlayhead(model.loop.range.start + 300)
        #expect(model.ramp.repetition == 1, "a loop edit counted as a wrap")
    }

    // MARK: - Finishing

    /// The end-of-ramp decision, measured on the model: the ramp completes, the
    /// **speed is held** at the end value, and the transport is not touched.
    @Test("the ramp completes holding its final speed, and leaves the transport alone")
    func completingHoldsTheFinalSpeedAndDoesNotStop() {
        let model = makeLoopedModel()
        model.setRampSchedule(
            RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 3))
        model.startRamp()
        playOneRepetition(model)
        playOneRepetition(model)
        #expect(model.speed.ratio == 1.0)
        #expect(model.ramp.isRunning)

        // The wrap at the end of the last repetition.
        playOneRepetition(model)
        #expect(model.ramp.phase == .complete)
        #expect(model.speed.ratio == 1.0, "the final speed must be held, not reset")
        #expect(model.loop.isActive, "the loop must keep going round")

        // And several more wraps change nothing at all.
        playOneRepetition(model)
        playOneRepetition(model)
        #expect(model.ramp.phase == .complete)
        #expect(model.speed.ratio == 1.0)
        #expect(model.ramp.repetition == 3)
    }

    @Test("a descending ramp slows down one repetition at a time")
    func aDescendingRampSlowsDown() {
        let model = makeLoopedModel()
        model.setRampSchedule(
            RampSchedule(startRatio: 1.0, endRatio: 0.6, repetitions: 5))
        model.startRamp()

        var speeds = [model.speed.ratio]
        for _ in 0..<4 {
            playOneRepetition(model)
            speeds.append(model.speed.ratio)
        }
        #expect(speeds == [1.0, 0.9, 0.8, 0.7, 0.6])
    }

    @Test("stopping leaves the speed where the ramp left it")
    func stoppingLeavesTheSpeedWhereItWas() {
        let model = makeLoopedModel()
        model.setRampSchedule(
            RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 5))
        model.startRamp()
        playOneRepetition(model)
        playOneRepetition(model)
        #expect(model.speed.ratio == 0.75)

        model.stopRamp()
        #expect(model.ramp.isIdle)
        #expect(model.speed.ratio == 0.75, "stopping snapped the speed back")
        // And further wraps are ignored.
        playOneRepetition(model)
        #expect(model.speed.ratio == 0.75)
        #expect(model.ramp.isIdle)
    }

    @Test("the toggle starts, stops, and restarts a completed ramp from the top")
    func toggling() {
        let model = makeLoopedModel()
        model.setRampSchedule(
            RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 2))
        model.toggleRamp()
        #expect(model.ramp.isRunning)
        model.toggleRamp()
        #expect(model.ramp.isIdle)

        model.toggleRamp()
        playOneRepetition(model)
        playOneRepetition(model)
        #expect(model.ramp.phase == .complete)
        model.toggleRamp()
        #expect(model.ramp.isRunning)
        #expect(model.ramp.repetition == 1)
        #expect(model.speed.ratio == 0.5, "a restarted ramp begins at the start speed")
    }

    // MARK: - The schedule

    @Test("the schedule is clamped on the way in and cannot be edited mid-ramp")
    func theScheduleIsGuarded() {
        let model = makeLoopedModel()
        model.setRampStartRatio(9)
        model.setRampEndRatio(-1)
        model.setRampRepetitions(0)
        #expect(model.ramp.schedule.startRatio == SpeedState.maxRatio)
        #expect(model.ramp.schedule.endRatio == SpeedState.minRatio)
        #expect(model.ramp.schedule.repetitions == RampSchedule.minimumRepetitions)

        model.setRampSchedule(RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 6))
        model.startRamp()
        model.setRampRepetitions(2)
        #expect(
            model.ramp.schedule.repetitions == 6,
            "the plan changed under a running ramp")
    }

    /// The ramp must reach the transport through the path the `1`–`4` keys use,
    /// not a private one — that is what keeps it to a single ratio change the
    /// engine applies on its next quantum, with no stretcher reset and therefore
    /// no click. Measured here as the observable consequence: the speed the ramp
    /// sets is quantised and clamped exactly as a keyed one is.
    @Test("ramp speeds go through the same quantise-and-clamp as a keyed speed change")
    func rampSpeedsAreQuantisedLikeKeyedOnes() {
        let model = makeLoopedModel()
        // 50% to 100% over four is 16.667 points a step: the second repetition's
        // raw value is 0.6666…, which the shared path rounds to a thousandth.
        model.setRampSchedule(RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 4))
        model.startRamp()
        playOneRepetition(model)
        #expect(model.speed.ratio == 0.667)
        #expect(model.speed.timeRatio == 1.0 / 0.667, "the reciprocal is what the engine gets")

        // Nothing the ramp sets can leave the transport's range, because the
        // range is enforced where it always was.
        model.stopRamp()
        model.setRampSchedule(RampSchedule(startRatio: 0.1, endRatio: 2.0, repetitions: 8))
        model.startRamp()
        for _ in 0..<9 {
            playOneRepetition(model)
            #expect(model.speed.ratio >= SpeedState.minRatio)
            #expect(model.speed.ratio <= SpeedState.maxRatio)
        }
    }
}
