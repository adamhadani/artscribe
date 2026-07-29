import ArtscribeKit

/// **The words the Practice window says**, extracted so they can be tested.
///
/// Views are not snapshot-tested on this project; the rule is to pull the pure
/// part out and test that instead. What is pure about a progress readout is all
/// of it — every sentence here is a function of `SpeedRamp` and the loop, and
/// every one of them has an edge that reads badly if it is written carelessly:
/// "1 more repetition**s**", a step of "+0.0%" on a flat ramp, and a ramp of one
/// repetition whose "step" is a number that does not exist.
public enum PracticeReadout {

    /// The per-repetition step, spelled out under the fields.
    ///
    /// Signed, because a descending ramp is a legitimate way to practise and a
    /// readout that said "5.6% per repetition" while the speed fell would be
    /// worse than none. One repetition has no step at all and says so rather
    /// than claiming a delta of zero, which would read as a flat ramp.
    public static func step(_ schedule: RampSchedule) -> String {
        guard schedule.repetitions > 1 else {
            return "One repetition, at \(percent(schedule.startRatio)). "
                + "The end speed is not reached."
        }
        guard schedule.delta != 0 else {
            return "\(schedule.repetitions) repetitions, all at "
                + "\(percent(schedule.startRatio))."
        }
        let sign = schedule.delta > 0 ? "+" : "−"
        let size = signedPercent(abs(schedule.delta))
        return "\(sign)\(size) per repetition, "
            + "\(percent(schedule.startRatio)) → \(percent(schedule.endRatio))."
    }

    /// Which repetition is playing, or that the ramp is over.
    public static func headline(_ ramp: SpeedRamp) -> String {
        switch ramp.phase {
        case .idle:
            return "Not running."
        case .running:
            return "Repetition \(ramp.repetition) of \(ramp.total)"
        case .complete:
            // Says what is happening *now*, not only that something finished:
            // the loop is still going round at the final speed, and a bare
            // "Complete" would leave the user wondering why they can still hear
            // it. See `SpeedRamp` for why holding was chosen over stopping.
            return "Ramp complete — holding \(percent(ramp.currentRatio))"
        }
    }

    /// How many repetitions are still to come. Singular when there is one, which
    /// is the case a `\(n) repetitions` format gets wrong every time.
    public static func remaining(_ ramp: SpeedRamp) -> String {
        switch ramp.phase {
        case .idle:
            return "\(ramp.total) repetition\(ramp.total == 1 ? "" : "s") to play"
        case .complete:
            return "all \(ramp.total) played"
        case .running:
            let left = ramp.remaining
            guard left > 0 else { return "last repetition" }
            return "\(left) more repetition\(left == 1 ? "" : "s")"
        }
    }

    /// The region being practised, so the window says *which* loop it means when
    /// it is on a second display from the waveform.
    public static func loop(range: FrameRange, sampleRate: Double) -> String {
        guard range.count > 0, sampleRate > 0 else { return "No loop set." }
        let start = TimeCode.precise(frames: range.start, sampleRate: sampleRate)
        let end = TimeCode.precise(frames: range.end, sampleRate: sampleRate)
        let seconds = TimeCode.seconds(frames: range.count, sampleRate: sampleRate)
        return "Loop \(start)–\(end)  ·  \(secondsLabel(seconds))"
    }

    /// A ratio as whole percent — the same rounding the speed readout uses, so
    /// the two cannot disagree about what 55.6% is called.
    private static func percent(_ ratio: Double) -> String { Readout.percent(ratio) }

    /// A *step* as percentage points, to one decimal.
    ///
    /// Finer than `Readout.percent` on purpose: the default ramp's step is
    /// 5.5556 points, and rounding it to "6%" would not add up to the range it
    /// is stated beside — nine steps of 6 is 54, and the range is 50.
    private static func signedPercent(_ ratio: Double) -> String {
        guard ratio.isFinite else { return "—" }
        let points = (ratio * 1000).rounded() / 10
        return "\(points)%"
    }

    private static func secondsLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        return "\((seconds * 10).rounded() / 10) s"
    }
}
