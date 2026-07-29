/// **Notices the loop going round**, from the positions the UI already polls.
///
/// The practice ramp advances one step per repetition, and the honest definition
/// of "a repetition" is *the loop wrapped*. Deriving it from a timer instead —
/// fire every `loopSeconds / speedRatio` — is wrong the moment either of those
/// two numbers changes underneath the timer, and in this feature **both change
/// constantly**: the ramp's entire job is to change the speed, and the loop
/// boundaries are draggable and nudgeable while it runs. A timer would drift out
/// of phase with the music on the first step and never come back.
///
/// So the wrap is taken from the engine's own position. `PlaybackEngine` already
/// publishes the audible frame and `ViewerModel` already polls it on the display
/// link; this is the two lines that turn that stream into an event. Nothing new
/// crosses the render-thread boundary, and the rule that the audio thread never
/// pushes (spec §5) is untouched.
///
/// ## What counts as a wrap
///
/// Two things together, and the second is not optional:
///
/// 1. a *backward* jump of more than half the loop, and
/// 2. the playhead having been seen in the **middle half** of the loop since
///    the last wrap — that is, the loop having actually been traversed.
///
/// ## Why the second condition exists — measured, not defensive
///
/// The audible position is not a clean sawtooth at the boundary. It is
/// latency-compensated, the compensation is scaled by the speed ratio, and
/// `PlaybackEngine.audiblePosition` derives it from a backlog that is *briefly
/// mis-scaled* whenever the time ratio changes (that engine's own words: "an
/// error bounded by one backlog that drains within a block or two"). The ramp
/// changes the speed at every wrap, so this happens at every wrap, and it makes
/// the reported position step back across the boundary it has just crossed.
///
/// Measured on a four-second loop at 50% → 75%, sampled every 20 ms:
///
/// ```
///  7.493  playhead=1498654   (loop 1323000..1499400, near the end)
///  7.526  playhead=1322960   ← the wrap; the ramp steps to 75%
///  7.550  playhead=1497796   ← back over the boundary, 1.6k frames of backlog
///  7.592  playhead=1499206
///  7.613  playhead=1323160   ← crosses again, 87 ms after the first
/// ```
///
/// With the backward-jump test alone, that second crossing is a wrap: the ramp
/// advanced twice in 87 ms, and the acceptance run recorded a "repetition" that
/// lasted 0.07 s against a loop that takes five seconds to play. Requiring the
/// **middle** of the loop to have been visited in between costs nothing in
/// normal playback — every real lap goes through it — and boundary jitter can
/// never satisfy it, because by definition it never leaves the boundary.
///
/// A time-based debounce would also have suppressed it, and would have been the
/// wrong fix: it would need a duration derived from the loop length and the
/// speed, which are the two things this feature changes underneath itself.
///
/// ## What does not count
///
/// A deliberate seek is shaped exactly like a wrap and is not one: pressing `F`
/// to restart the loop, or nudging back into it, must not be counted as a
/// repetition. That is why this holds no opinion about seeks and instead offers
/// `reset()` — `ViewerModel.seek(to:)` is the single path a user seek takes, and
/// it clears the baseline there, so the next poll starts a fresh comparison
/// rather than measuring across the jump.
///
/// ## The one case it cannot see
///
/// A loop so short that the playhead skips its middle half between two polls —
/// at 60 Hz and double speed, under about 130 ms of audio — reports no wraps at
/// all. That is a loop far too short to practise against, and the alternative
/// (asking the render thread to count) is a new upward channel that spec §5
/// does not have.
public struct LoopWrapTracker: Equatable, Sendable {

    /// Where the playhead was at the previous observation, or `nil` when there
    /// is nothing to compare against — before the first poll, and after every
    /// `reset()`.
    private var previous: FrameIndex?
    /// Whether the middle of the loop has been visited since the last wrap.
    /// Without this the boundary jitter above counts as a second lap.
    private var traversed = false

    public init() {}

    /// Forget where the playhead was, so the next observation starts a fresh
    /// comparison. Called for every deliberate move: a seek, and any change to
    /// the loop itself.
    public mutating func reset() {
        previous = nil
        traversed = false
    }

    /// One polled position.
    ///
    /// - Returns: `true` exactly when the loop has just gone round.
    public mutating func observe(playhead: FrameIndex, loop: LoopRegion) -> Bool {
        guard loop.isActive else {
            // No active loop means no wraps, and the position we would compare
            // against next time is from a different regime. Dropped rather than
            // kept, so enabling a loop cannot report a wrap on its first poll.
            reset()
            return false
        }
        let last = previous
        previous = playhead
        let offset = playhead - loop.range.start
        let quarter = loop.range.count / 4
        if offset > quarter && offset < loop.range.count - quarter { traversed = true }

        guard traversed, let last, playhead < last else { return false }
        guard last - playhead > loop.range.count / 2 else { return false }
        traversed = false
        return true
    }
}
