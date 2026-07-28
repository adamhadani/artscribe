import ArtscribeKit
import Testing

@testable import ArtscribeUI

/// **The words the Practice window says.**
///
/// Views are not snapshot-tested on this project; the rule is to pull the pure
/// part out and test that. What is pure about a progress readout is all of it,
/// and every sentence here has an edge that reads badly if written carelessly —
/// "1 more repetition**s**", a "+0.0%" step on a flat ramp, and a one-repetition
/// ramp whose "step" is a number that does not exist.
@MainActor
@Suite("Practice readout")
struct PracticeReadoutTests {

    @Test("the readout names the repetition, the remainder and the completion")
    func theReadoutSaysWhereTheRampIs() {
        var ramp = SpeedRamp(
            schedule: RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 3))
        #expect(PracticeReadout.headline(ramp) == "Not running.")
        #expect(PracticeReadout.remaining(ramp) == "3 repetitions to play")

        ramp.start()
        #expect(PracticeReadout.headline(ramp) == "Repetition 1 of 3")
        #expect(PracticeReadout.remaining(ramp) == "2 more repetitions")

        ramp.advance()
        // Singular, which the obvious format string gets wrong.
        #expect(PracticeReadout.remaining(ramp) == "1 more repetition")

        ramp.advance()
        #expect(PracticeReadout.headline(ramp) == "Repetition 3 of 3")
        #expect(PracticeReadout.remaining(ramp) == "last repetition")

        ramp.advance()
        #expect(PracticeReadout.headline(ramp) == "Ramp complete — holding 100%")
        #expect(PracticeReadout.remaining(ramp) == "all 3 played")
    }

    @Test("the step summary is signed, and says nothing false about the awkward schedules")
    func theStepSummaryIsHonest() {
        let up = RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 10)
        #expect(PracticeReadout.step(up) == "+5.6% per repetition, 50% → 100%.")

        let down = RampSchedule(startRatio: 1.0, endRatio: 0.6, repetitions: 5)
        #expect(PracticeReadout.step(down) == "−10.0% per repetition, 100% → 60%.")

        // A flat ramp has a delta of zero and must not read "+0.0% per
        // repetition", which would look like a broken calculation.
        let flat = RampSchedule(startRatio: 0.75, endRatio: 0.75, repetitions: 6)
        #expect(PracticeReadout.step(flat) == "6 repetitions, all at 75%.")

        // One repetition has no step at all, and the end speed is unreachable —
        // said out loud rather than left to be discovered.
        let single = RampSchedule(startRatio: 0.4, endRatio: 1.0, repetitions: 1)
        #expect(
            PracticeReadout.step(single)
                == "One repetition, at 40%. The end speed is not reached.")
    }

    @Test("the loop line names the region, and says so when there is none")
    func theLoopLine() {
        // Four seconds at 44100, the same region `PracticeRampTests` practises.
        let line = PracticeReadout.loop(
            range: FrameRange(start: 132_300, count: 176_400), sampleRate: 44100)
        #expect(line.contains("4.0 s"), "\(line) does not name the loop's length")
        #expect(line.hasPrefix("Loop "))

        #expect(
            PracticeReadout.loop(range: FrameRange(start: 0, count: 0), sampleRate: 44100)
                == "No loop set.")
        // A model with no track has no sample rate to divide by.
        #expect(
            PracticeReadout.loop(range: FrameRange(start: 0, count: 100), sampleRate: 0)
                == "No loop set.")
    }

    /// The window has to be able to draw itself at its own minimum.
    @Test("the practice window's minimum size is a size")
    func theWindowMinimumIsSane() {
        #expect(PracticeWindow.minimumWidth >= 260)
        #expect(PracticeWindow.minimumHeight >= 260)
    }
}
