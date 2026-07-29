/// **A ramp in progress**: the schedule, plus where in it we are.
///
/// Split from `RampSchedule` because they answer different questions and change
/// at different times. The schedule is a plan the user types in and edits; this
/// is the position of the needle on it, moved by the loop rather than by anyone.
///
/// Pure and `Equatable`, so the whole of the practice hub's behaviour can be
/// driven without a window, a clock or an audio device — the only part that
/// needs any of those is the *event* that calls `advance()`, which is a loop
/// wrap and lives on `ViewerModel`.
///
/// ## What happens when the ramp finishes
///
/// It **holds the final speed and leaves the transport alone.** `phase` goes to
/// `.complete`, the loop keeps playing, and the speed stays where the last
/// repetition put it.
///
/// The alternative — stopping playback — was rejected for two reasons. The first
/// is that a ramp is a speed automation, not a transport: it does not own the
/// play state, it was very likely started while something was already playing,
/// and a tool that silently pauses you is a tool you have to reach for the
/// keyboard to undo. The second is what the end of a ramp actually *is*: you
/// have arrived at the passage, at tempo, in the loop, which is the thing the
/// whole exercise was for. Stopping there takes the payoff away at the exact
/// moment it arrives.
///
/// The completion is not silent, which is the other half of the decision — the
/// window says so, in as many words, and `phase` is what it reads.
public struct SpeedRamp: Equatable, Sendable {

    public enum Phase: String, Equatable, Sendable {
        /// Not running. The window shows the fields, editable.
        case idle
        /// Running: the speed follows the schedule, one step per loop wrap.
        case running
        /// Every repetition has been played. The final speed is held; see above.
        case complete
    }

    /// The plan. Editable while idle; the window refuses to change it mid-ramp,
    /// because a repetition count that shrinks under a running index is a
    /// question with no good answer and no musician has ever wanted to ask it.
    public var schedule: RampSchedule

    public private(set) var phase: Phase = .idle
    /// Which repetition is playing **now**, counting from zero.
    public private(set) var index: Int = 0

    public init(schedule: RampSchedule = RampSchedule()) {
        self.schedule = schedule
    }

    public var isRunning: Bool { phase == .running }
    public var isIdle: Bool { phase == .idle }

    /// The repetition now playing, counting from one — what the window shows,
    /// and what a musician counts.
    public var repetition: Int { index + 1 }

    public var total: Int { schedule.repetitions }

    /// How many repetitions are still to come **after** this one. Zero on the
    /// last pass and zero once complete, which is the honest reading of "how
    /// many more do I have to play".
    public var remaining: Int { Swift.max(0, total - repetition) }

    /// The speed this repetition is played at.
    public var currentRatio: Double { schedule.ratio(at: index) }

    /// How far through the ramp we are, 0…1, for a progress bar.
    ///
    /// Measured in *repetitions completed*, so it reads 0 on the first pass and
    /// 1 only when the ramp is done. Deliberately not `repetition / total`,
    /// which would show a tenth of the bar filled before a note had been played.
    public var progress: Double {
        guard total > 1 else { return phase == .complete ? 1 : 0 }
        guard phase != .complete else { return 1 }
        return Double(index) / Double(total - 1)
    }

    /// Begin, at the first repetition's speed.
    public mutating func start() {
        phase = .running
        index = 0
    }

    /// Stop, wherever we are. Deliberately leaves the *speed* alone: whatever
    /// the ramp last set is what is playing, and snapping back to 100% would
    /// undo the thing the user pressed stop in order to keep working at.
    public mutating func stop() {
        phase = .idle
        index = 0
    }

    /// **One loop wrap.** The only thing that moves a running ramp forward.
    ///
    /// - Returns: the new speed to apply, or `nil` when nothing should change —
    ///   which is the case both when no ramp is running and when this wrap was
    ///   the last one, since a completed ramp holds the speed it finished on.
    @discardableResult
    public mutating func advance() -> Double? {
        guard phase == .running else { return nil }
        guard index + 1 < schedule.repetitions else {
            phase = .complete
            return nil
        }
        index += 1
        return schedule.ratio(at: index)
    }
}
