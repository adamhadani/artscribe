import Testing

@testable import ArtscribeKit

/// **The ramp's state machine and its trigger**, both pure.
///
/// The two halves are tested together because the interesting property is the
/// one that spans them: the ramp moves on a *wrap event* and on nothing else, so
/// the number of times `advance()` is reached has to depend on how many times
/// the loop went round and not at all on how many observations were made.
/// `advancingIsCountedInWrapsNotInObservations` is that property stated
/// directly; the model-level version, driven through a real polled playhead,
/// lives in `PracticeRampTests`.
@Suite("Speed ramp")
struct SpeedRampTests {

    private let loop = LoopRegion(
        range: FrameRange(start: 100_000, count: 200_000), isEnabled: true)

    // MARK: - The run

    @Test("a ramp starts on the first repetition at the start speed")
    func startingPlacesTheNeedleAtTheBeginning() {
        var ramp = SpeedRamp()
        #expect(ramp.isIdle)
        #expect(!ramp.isRunning)

        ramp.start()
        #expect(ramp.isRunning)
        #expect(ramp.index == 0)
        #expect(ramp.repetition == 1)
        #expect(ramp.total == 10)
        #expect(ramp.remaining == 9)
        #expect(ramp.currentRatio == 0.50)
        #expect(ramp.progress == 0)
    }

    @Test("each wrap moves one repetition on and returns the speed to apply")
    func eachWrapStepsTheSpeed() {
        var ramp = SpeedRamp(
            schedule: RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 5))
        ramp.start()

        var applied: [Double] = [ramp.currentRatio]
        for _ in 0..<4 {
            guard let next = ramp.advance() else { break }
            applied.append(next)
        }
        #expect(applied == [0.5, 0.625, 0.75, 0.875, 1.0])
        #expect(ramp.repetition == 5)
        #expect(ramp.remaining == 0)
        #expect(ramp.isRunning, "the fifth repetition is still being played")
    }

    /// The end-of-ramp decision, asserted rather than described: the ramp
    /// completes, says so, and **holds** the final speed by returning no new one.
    /// Nothing here touches the transport, which is the other half of the same
    /// choice — see `SpeedRamp`'s documentation for why stopping was rejected.
    @Test("the wrap after the last repetition completes the ramp and holds the final speed")
    func completingHoldsTheFinalSpeed() {
        var ramp = SpeedRamp(
            schedule: RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 3))
        ramp.start()
        #expect(ramp.advance() == 0.75)
        #expect(ramp.advance() == 1.0)

        // The wrap at the end of the final repetition.
        #expect(ramp.advance() == nil, "a completed ramp must not ask for a new speed")
        #expect(ramp.phase == .complete)
        #expect(!ramp.isRunning)
        #expect(ramp.currentRatio == 1.0, "the final speed is held, not reset")
        #expect(ramp.repetition == 3)
        #expect(ramp.remaining == 0)
        #expect(ramp.progress == 1)

        // And it stays there however many more times the loop goes round.
        for _ in 0..<20 { #expect(ramp.advance() == nil) }
        #expect(ramp.phase == .complete)
        #expect(ramp.index == 2)
    }

    @Test("a single-repetition ramp completes on its first wrap")
    func oneRepetitionCompletesAtTheFirstWrap() {
        var ramp = SpeedRamp(
            schedule: RampSchedule(startRatio: 0.4, endRatio: 1.0, repetitions: 1))
        ramp.start()
        #expect(ramp.currentRatio == 0.4)
        #expect(ramp.remaining == 0)
        #expect(ramp.advance() == nil)
        #expect(ramp.phase == .complete)
        #expect(ramp.currentRatio == 0.4)
    }

    @Test("a descending ramp steps downwards, one wrap at a time")
    func descendingRamp() {
        var ramp = SpeedRamp(
            schedule: RampSchedule(startRatio: 1.0, endRatio: 0.6, repetitions: 5))
        ramp.start()
        var applied = [ramp.currentRatio]
        while let next = ramp.advance() { applied.append(next) }
        #expect(applied == [1.0, 0.9, 0.8, 0.7, 0.6])
        #expect(ramp.phase == .complete)
    }

    @Test("a stopped ramp ignores wraps, and stopping does not touch the speed it reached")
    func stoppingParksTheRamp() {
        var ramp = SpeedRamp()
        ramp.start()
        ramp.advance()
        ramp.advance()
        #expect(ramp.repetition == 3)

        ramp.stop()
        #expect(ramp.isIdle)
        #expect(ramp.advance() == nil, "a stopped ramp must not step on a wrap")
        #expect(ramp.isIdle)
        // `stop()` deliberately says nothing about the transport's speed: the
        // model leaves it where the last repetition put it, which is what
        // `PracticeRampTests.stoppingLeavesTheSpeedWhereItWas` measures.
    }

    @Test("an idle ramp never advances, however many wraps arrive")
    func anIdleRampIgnoresWraps() {
        var ramp = SpeedRamp()
        for _ in 0..<50 { #expect(ramp.advance() == nil) }
        #expect(ramp.index == 0)
        #expect(ramp.isIdle)
    }

    @Test("progress reads zero on the first pass and one only when complete")
    func progressIsMeasuredInCompletedRepetitions() {
        var ramp = SpeedRamp(
            schedule: RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 5))
        ramp.start()
        #expect(ramp.progress == 0)
        ramp.advance()
        #expect(abs(ramp.progress - 0.25) < 1e-12)
        ramp.advance()
        ramp.advance()
        ramp.advance()
        #expect(ramp.progress == 1)
        #expect(ramp.isRunning, "the last repetition is still playing")
        ramp.advance()
        #expect(ramp.progress == 1)
        #expect(ramp.phase == .complete)
    }

    // MARK: - The wrap tracker

    @Test("a large backward jump inside an active loop is a wrap")
    func aBackwardJumpIsAWrap() {
        var tracker = LoopWrapTracker()
        #expect(!wrapped(&tracker, 120_000, loop), "the first poll has no baseline")
        #expect(!wrapped(&tracker, 200_000, loop))
        #expect(!wrapped(&tracker, 299_000, loop))
        #expect(wrapped(&tracker, 101_000, loop), "the loop went round")
        #expect(!wrapped(&tracker, 150_000, loop))
    }

    /// The property that makes this a wrap detector rather than a timer in
    /// disguise: **only the number of times the loop went round matters.** The
    /// same two passes are observed at three wildly different poll rates and
    /// report the same two wraps.
    @Test("advancing is counted in wraps, not in observations")
    func advancingIsCountedInWrapsNotInObservations() {
        let start = loop.range.start
        let span = loop.range.count - 1
        for steps in [4, 40, 4000] {
            var tracker = LoopWrapTracker()
            var wraps = 0
            // Two full passes of the loop, sampled `steps` times each.
            for _ in 0..<2 {
                for step in 0...steps {
                    let frame = start + span * FrameIndex(step) / FrameIndex(steps)
                    if wrapped(&tracker, frame, loop) { wraps += 1 }
                }
            }
            #expect(wraps == 1, "\(steps) polls per pass reported \(wraps) wraps over two passes")
        }
    }

    @Test("a small backward step is jitter, not a wrap")
    func jitterIsNotAWrap() {
        var tracker = LoopWrapTracker()
        // Through the middle first, so the traversal condition is satisfied and
        // this test is measuring the size threshold rather than passing for the
        // other reason.
        _ = wrapped(&tracker, 190_000, loop)
        _ = wrapped(&tracker, 250_000, loop)
        // The audible position is latency-compensated and the compensation moves
        // with the speed, so it can step back a little without the loop having
        // gone anywhere.
        #expect(!wrapped(&tracker, 249_000, loop))
        #expect(!wrapped(&tracker, 200_001, loop))
        // Half the loop is 100_000 frames; a step of exactly that is not enough.
        #expect(!wrapped(&tracker, 100_001, loop))
    }

    @Test("no wrap is reported without an active loop, in either direction")
    func anInactiveLoopHasNoWraps() {
        let disabled = LoopRegion(range: loop.range, isEnabled: false)
        let empty = LoopRegion(range: FrameRange(start: 0, count: 0), isEnabled: true)
        for region in [disabled, empty] {
            var tracker = LoopWrapTracker()
            _ = wrapped(&tracker, 299_000, region)
            #expect(!wrapped(&tracker, 100_100, region))
        }
    }

    /// Enabling a loop while the playhead is past it must not report a wrap on
    /// the first poll afterwards — the baseline was taken in a different regime.
    @Test("switching a loop on drops the baseline rather than measuring across it")
    func enablingALoopDoesNotFakeAWrap() {
        let disabled = LoopRegion(range: loop.range, isEnabled: false)
        var tracker = LoopWrapTracker()
        _ = wrapped(&tracker, 900_000, disabled)
        #expect(!wrapped(&tracker, 100_500, loop))
        // And the very next poll is a normal forward one.
        #expect(!wrapped(&tracker, 140_000, loop))
    }

    @Test("a reset baseline cannot be measured across")
    func resetDropsTheBaseline() {
        var tracker = LoopWrapTracker()
        _ = wrapped(&tracker, 190_000, loop)
        _ = wrapped(&tracker, 299_000, loop)
        // What `ViewerModel.seek(to:)` does: a deliberate jump is shaped exactly
        // like a wrap and is not one.
        tracker.reset()
        #expect(!wrapped(&tracker, 100_500, loop))
        // The loop then genuinely goes round from there — through the middle,
        // which is what a lap does and what jitter cannot.
        _ = wrapped(&tracker, 190_000, loop)
        _ = wrapped(&tracker, 298_000, loop)
        #expect(wrapped(&tracker, 100_200, loop))
    }

    /// **The regression that cost a bad acceptance run.** Real positions,
    /// recorded from a live four-second loop at the instant the ramp stepped
    /// 50% → 75%, replayed exactly.
    ///
    /// The audible position crosses the loop boundary, then the speed change
    /// re-scales the engine's in-flight backlog and it crosses *back*, then
    /// forward again 87 ms later. Against the backward-jump test alone that is
    /// two wraps, and the run reported a "repetition" lasting 0.07 s. There must
    /// be exactly one.
    @Test("the position jitter a speed change causes at the boundary is one wrap, not two")
    func boundaryJitterAfterASpeedChangeIsOneWrap() {
        // 30.000 s to 34.000 s at 44100 Hz, the acceptance run's own loop.
        let region = LoopRegion(
            range: FrameRange(start: 1_323_000, count: 176_400), isEnabled: true)
        let measured: [FrameIndex] = [
            1_400_000,  // mid-lap, as every real lap passes
            1_497_243, 1_497_948, 1_498_419, 1_498_654,
            1_322_960,  // the wrap — the ramp steps to 75% here
            1_497_796, 1_498_501, 1_499_206,  // the mis-scaled backlog, back over the line
            1_323_160  // and across again, 87 ms after the first
        ]
        var tracker = LoopWrapTracker()
        var wraps: [FrameIndex] = []
        for frame in measured where wrapped(&tracker, frame, region) {
            wraps.append(frame)
        }
        #expect(wraps == [1_322_960], "the boundary jitter was counted as a lap: \(wraps)")

        // And the *next* real lap still counts, so the fix suppresses jitter
        // rather than suppressing the feature.
        for frame in [FrameIndex(1_400_000), 1_499_000] { _ = wrapped(&tracker, frame, region) }
        #expect(wrapped(&tracker, 1_323_500, region))
    }

    /// `#expect` cannot call a `mutating` method — its macro expansion captures
    /// the receiver immutably — so every observation goes through here.
    private func wrapped(
        _ tracker: inout LoopWrapTracker, _ playhead: FrameIndex, _ loop: LoopRegion
    ) -> Bool {
        tracker.observe(playhead: playhead, loop: loop)
    }
}
