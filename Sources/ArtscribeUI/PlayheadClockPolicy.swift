import Foundation

/// When the playhead poll should stop trusting the display link.
///
/// A pure function of two numbers, kept out of `PlayheadClock` so it can be
/// tested without a screen — which is the whole difficulty with the thing it
/// guards. A test for "what happens when the display sleeps" cannot put a
/// display to sleep; it can decide what the answer should be for a given gap
/// since the last tick.
enum PlayheadClockPolicy {

    /// How long a silent display link is tolerated before the timer stands in.
    ///
    /// A 60 Hz link ticks every 16.7 ms, so this is fifteen missed frames. The
    /// number is a compromise between two costs, and neither is severe:
    ///
    /// - **Too low** and ordinary main-thread congestion — a window resize, a
    ///   waveform bitmap being rebuilt — trips the standby clock. That is
    ///   harmless (it hands back the moment a real tick arrives) but pointless.
    /// - **Too high** and the gap before the timer takes over gets long enough
    ///   to miss loop wraps. `LoopWrapTracker` sees wraps by observing polled
    ///   positions, so a poll that stops for a second can miss a wrap in a short
    ///   loop, and a missed wrap is a practice repetition that never counts.
    ///
    /// 250 ms costs at most one missed wrap on a loop shorter than that, once,
    /// at the moment the display sleeps — against the alternative, which was the
    /// poll stopping forever.
    static let stallThreshold: TimeInterval = 0.25

    /// Whether the link has been quiet long enough to be treated as stopped.
    ///
    /// Deliberately *not* "is the link non-nil". A `CADisplayLink` that has
    /// stopped firing is still a perfectly valid, non-nil, un-invalidated
    /// object — which is exactly why `PlayheadClock.isRunning` used to answer
    /// `true` about a clock that had not ticked in ten minutes, and why the
    /// advice to "assert `isRunning` and skip" could never have worked.
    static func isStalled(now: TimeInterval, lastTick: TimeInterval) -> Bool {
        now - lastTick > stallThreshold
    }
}
