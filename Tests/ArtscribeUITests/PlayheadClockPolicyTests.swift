import Foundation
import Testing

@testable import ArtscribeUI

/// When the playhead poll gives up on the display link.
///
/// The behaviour this guards cannot be tested directly — a test cannot put a
/// display to sleep — so the decision is a pure function of two numbers and
/// *that* is what gets tested. Everything around it is `Timer` and
/// `CADisplayLink` plumbing with no judgement in it.
@Suite("Playhead clock stall policy")
struct PlayheadClockPolicyTests {

    /// A 60 Hz link ticks every 16.7 ms. Ordinary jitter — a slow frame, a
    /// waveform bitmap being rebuilt — must not be mistaken for a stopped
    /// display, or the standby clock flaps in and out during normal use.
    @Test("a link ticking normally is not stalled", arguments: [0.0, 0.017, 0.05, 0.2])
    func healthyLinkIsNotStalled(gap: TimeInterval) {
        #expect(!PlayheadClockPolicy.isStalled(now: 100 + gap, lastTick: 100))
    }

    /// The case the whole thing exists for: the display slept, the link stopped,
    /// and nothing has polled the playhead since.
    @Test("a link that has gone quiet is stalled", arguments: [0.3, 1.0, 60.0, 600.0])
    func quietLinkIsStalled(gap: TimeInterval) {
        #expect(PlayheadClockPolicy.isStalled(now: 100 + gap, lastTick: 100))
    }

    /// The bound has to sit above a missed frame or two and below the point where
    /// a short loop's wrap would be missed — `LoopWrapTracker` sees wraps by
    /// observing polled positions, and a missed wrap is a practice repetition
    /// that never counts.
    @Test("the threshold is longer than a few frames and shorter than a short loop")
    func thresholdIsInTheUsefulRange() {
        let frame = 1.0 / 60
        #expect(
            PlayheadClockPolicy.stallThreshold > 5 * frame,
            "too tight — normal jitter would trip the standby clock")
        #expect(
            PlayheadClockPolicy.stallThreshold < 0.5,
            "too loose — wraps in a short loop would be missed before the timer took over")
    }

    /// **The bug this replaced, stated as a test.**
    ///
    /// `PlayheadClock.isRunning` used to answer `link != nil`, and a
    /// `CADisplayLink` that has stopped firing is still a perfectly valid,
    /// non-nil, un-invalidated object. So the documented advice — "assert
    /// `isRunning` and skip the position checks" — would have skipped nothing:
    /// the clock reported itself healthy while not having ticked in ten minutes.
    ///
    /// Staleness is a question about *time*, not about whether an object exists.
    @Test("staleness is decided by elapsed time, not by the link existing")
    func stalenessIsAboutTimeNotExistence() {
        // Ten minutes of silence from a link that is still very much alive.
        #expect(PlayheadClockPolicy.isStalled(now: 700, lastTick: 100))
    }
}
