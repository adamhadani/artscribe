/// **The ramping loop's plan**: which speed each repetition is played at.
///
/// The Practice hub's whole idea, and the user's own: you set a loop over the
/// phrase you cannot play, and the app walks the speed from something you *can*
/// play up to tempo, one repetition at a time, without you touching anything.
/// The MVP form of that was "add a fixed percentage each pass"; this is the form
/// the user asked for instead, and it is strictly better because it is stated in
/// the terms the practice session actually has — *where I start*, *where I need
/// to get to*, and *how long I am prepared to spend getting there*. The
/// per-repetition delta falls out of those three rather than being a fourth
/// thing to guess.
///
/// Pure, and deliberately in `ArtscribeKit`: it is arithmetic over a range that
/// `SpeedState` already owns, and nothing about it needs a window, a clock or an
/// audio graph to be right. `RampScheduleTests` is where the awkward cases live.
///
/// ## The endpoints are both played
///
/// `delta` divides by `repetitions - 1`, not by `repetitions`. Ten repetitions
/// from 50% to 100% therefore play 50%, 55.6%, … , 94.4%, 100% — the first
/// repetition is at the start speed and the last is at the end speed, which is
/// what "start speed" and "end speed" mean to the person typing them in.
/// Dividing by `repetitions` would give a tenth pass at 95% and never play the
/// tempo the whole exercise was aimed at.
///
/// ## Descending is a first-class case
///
/// `endRatio` below `startRatio` is legitimate and musicians do it — you take a
/// passage you can just about play at tempo and slow it down to hear what your
/// fingers are actually doing. So nothing here assumes ascent: `delta` is signed
/// and every bound is a clamp into `SpeedState`'s range rather than a
/// `max(start, …)` that would quietly invert an inverted range.
public struct RampSchedule: Equatable, Sendable, Codable {

    /// Slow enough to be playable, fast enough not to be a different piece of
    /// music. Half speed is also `3` on the keyboard, so the default start is a
    /// tempo the user already has a key for.
    public static let defaultStartRatio = 0.50
    /// Tempo. The point of the exercise.
    public static let defaultEndRatio = 1.00
    /// Ten passes at ~5.6% each. Long enough that no single step is a jump, short
    /// enough that a four-bar loop finishes in a couple of minutes.
    public static let defaultRepetitions = 10

    /// One repetition is a valid ramp — it is how you drill a single tempo for
    /// exactly one pass — so the floor is 1, not 2.
    public static let minimumRepetitions = 1
    /// A ceiling rather than none. At 99 the arithmetic is still meaningful
    /// (0.9 percentage points a pass over the default range) and a mistyped
    /// `1000` becomes something the window can display rather than a ramp that
    /// would outlast the practice session.
    public static let maximumRepetitions = 99

    public private(set) var startRatio: Double
    public private(set) var endRatio: Double
    public private(set) var repetitions: Int

    public init(
        startRatio: Double = RampSchedule.defaultStartRatio,
        endRatio: Double = RampSchedule.defaultEndRatio,
        repetitions: Int = RampSchedule.defaultRepetitions
    ) {
        self.startRatio = SpeedState.clamped(startRatio)
        self.endRatio = SpeedState.clamped(endRatio)
        self.repetitions = Self.clampRepetitions(repetitions)
    }

    private enum CodingKeys: String, CodingKey {
        case startRatio
        case endRatio
        case repetitions
    }

    /// Every field optional on the way in, for the same reason `SpeedState` and
    /// `LoopRegion` validate theirs: this is persisted where a human can reach
    /// it, and a missing or absurd field has an obviously right answer — the
    /// shipped default — whereas throwing the payload away would lose the two
    /// fields that *were* readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decodeIfPresent(Double.self, forKey: .startRatio)
        let end = try container.decodeIfPresent(Double.self, forKey: .endRatio)
        let count = try container.decodeIfPresent(Int.self, forKey: .repetitions)
        self.init(
            startRatio: start ?? Self.defaultStartRatio,
            endRatio: end ?? Self.defaultEndRatio,
            repetitions: count ?? Self.defaultRepetitions)
    }

    // MARK: - Editing
    //
    // Setters rather than settable properties, so the clamp cannot be bypassed
    // by assigning to a field — the same shape `SpeedState.setRatio` has, and
    // for the same reason.

    public mutating func setStartRatio(_ value: Double) {
        startRatio = SpeedState.clamped(value)
    }

    public mutating func setEndRatio(_ value: Double) {
        endRatio = SpeedState.clamped(value)
    }

    public mutating func setRepetitions(_ value: Int) {
        repetitions = Self.clampRepetitions(value)
    }

    // MARK: - The plan

    /// How much the speed moves between one repetition and the next. **Signed**:
    /// negative for a descending ramp, and exactly zero both when the two ends
    /// agree and when there is only one repetition to play.
    ///
    /// The `repetitions > 1` guard is not defensive tidying — `repetitions == 1`
    /// is the division by zero that a naive `(end - start) / count` walks
    /// straight into, and one repetition is a case the window offers.
    public var delta: Double {
        guard repetitions > 1 else { return 0 }
        return (endRatio - startRatio) / Double(repetitions - 1)
    }

    /// The speed for a repetition, counting from zero.
    ///
    /// The last index answers `endRatio` **exactly** rather than
    /// `startRatio + delta * (n - 1)`. Neither 0.05 nor a ninth of a half is
    /// representable in binary floating point, so the computed last value misses
    /// the target by a few ulps — invisible in the readout and audible to
    /// nobody, but it would mean the ramp's own arithmetic disagreed with the
    /// number the user typed, and a test comparing the two would have to be
    /// written with a tolerance to pass. Making the endpoint exact is cheaper
    /// than explaining why it is not.
    ///
    /// Out-of-range indices are clamped rather than trapping: this is read from
    /// a view body while the schedule can be edited underneath it.
    public func ratio(at index: Int) -> Double {
        guard repetitions > 1 else { return startRatio }
        let clamped = Swift.max(0, Swift.min(index, repetitions - 1))
        guard clamped < repetitions - 1 else { return endRatio }
        return SpeedState.clamped(startRatio + delta * Double(clamped))
    }

    /// Every speed the ramp will play, in order. For tests and for anything that
    /// wants to show the plan; the ramp itself asks for one index at a time.
    public var ratios: [Double] {
        (0..<repetitions).map { ratio(at: $0) }
    }

    private static func clampRepetitions(_ value: Int) -> Int {
        Swift.max(minimumRepetitions, Swift.min(maximumRepetitions, value))
    }
}
