import ArtscribeKit

/// The stepping policy behind `Q`/`W`, `⇧Q`/`⇧W` and the `1`–`4` presets.
///
/// `SpeedState` owns the range and the `timeRatio` reciprocal; this owns the
/// increments and the quantisation. They are separate because the increments are
/// an interaction decision (spec §6.2) and the clamp is an invariant.
public enum SpeedStepping {

    /// `Q` / `W`. Percentage *points* of the speed ratio, not a relative change:
    /// 100% → 95% → 90%, so the sequence of speeds you sweep through is the same
    /// going down as coming back up.
    public static let coarse = 0.05
    /// `⇧Q` / `⇧W`.
    public static let fine = 0.01

    /// `1` / `2` / `3` / `4`.
    public static let presets: [Double] = [1.00, 0.75, 0.50, 0.33]

    /// The grid every reachable ratio sits on, and the resolution the readout
    /// shows. A thousandth is finer than the 1% fine step, so quantising can
    /// never move a ratio the user deliberately set.
    private static let grid = 1000.0

    /// Steps and re-quantises.
    ///
    /// Neither 0.05 nor 0.01 is representable in binary floating point, so naive
    /// repeated addition walks off the grid — nine coarse steps down from 1.0
    /// reach 0.5500000000000002, which reads as 55% but is not 0.55 and never
    /// returns to exactly 1.0 on the way back up. Rounding to the nearest
    /// thousandth after each step keeps `Q`/`W` exactly reversible.
    public static func stepped(_ speed: SpeedState, by delta: Double) -> SpeedState {
        var next = speed
        next.setRatio(quantise(speed.ratio + delta))
        return next
    }

    public static func quantise(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 1.0 }
        return (ratio * grid).rounded() / grid
    }

    public static func percentLabel(_ ratio: Double) -> String { Readout.percent(ratio) }

    /// Whether a preset should show a checkmark in the menu. Compared with a
    /// tolerance of half a grid step: 0.33 is not representable, so an exact
    /// comparison against a value that has been through `quantise` is a coin
    /// toss on the last bit.
    public static func isActive(preset: Double, ratio: Double) -> Bool {
        guard preset.isFinite, ratio.isFinite else { return false }
        return abs(preset - ratio) < 0.5 / grid
    }

    /// Whether the speed readout should stand out, i.e. whether playback is
    /// running at anything but normal speed.
    ///
    /// Deliberately the same tolerance as the menu checkmark: a ratio that still
    /// reads "100%" must not be emphasised, or the emphasis contradicts the
    /// number beside it and stops meaning anything. A non-finite ratio is
    /// altered — it is certainly not normal speed, and nothing here hides it.
    public static func isAltered(_ ratio: Double) -> Bool {
        !isActive(preset: 1.0, ratio: ratio)
    }
}
