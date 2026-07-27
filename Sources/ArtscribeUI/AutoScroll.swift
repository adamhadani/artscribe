import ArtscribeKit

/// Where the view should jump to while the playhead moves — spec §6.1.
///
/// Auto-scroll is **page-flip**: the view is either left completely alone or
/// moved a whole page at a time. Continuous centred scrolling was explicitly
/// rejected in the spec: it looks better in a demo and is miserable to transcribe
/// against, because the waveform never stops moving and your eye never gets a
/// stable picture of the bar you are working on.
///
/// Pure, so the decision is testable without a view, a display link, or audio.
public enum AutoScroll {

    /// How far in from the left edge a flip leaves the playhead, as a fraction of
    /// the visible width. Non-zero so that the moment the page flips you can
    /// still see the beat that just went past.
    public static let leadFraction = 0.12

    /// The viewport start frame the view should move to, or `nil` to hold still.
    ///
    /// - Parameters:
    ///   - playhead: The audible position, already latency-compensated.
    ///   - viewport: The current view.
    ///   - loop: The loop region. An **active** loop that fits on screen
    ///     suppresses following entirely — while you are looping four bars the
    ///     waveform must stop moving, including at the wrap where the playhead
    ///     jumps backward on every pass.
    public static func pageStart(
        playhead: FrameIndex, viewport: Viewport, loop: LoopRegion
    ) -> FrameIndex? {
        let visible = viewport.visibleFrames
        guard visible > 0, viewport.totalFrames > visible else { return nil }

        if loop.isActive && loop.range.count <= visible {
            // Suppression means "stop following the playhead", not "never move":
            // a loop that fits but is off screen — you scrolled away, or set it
            // from the overview strip — is brought into view once, then held.
            let onScreen =
                loop.range.start >= viewport.startFrame && loop.range.end <= viewport.endFrame
            return onScreen ? nil : flip(to: loop.range.start, visible: visible)
        }

        let inside = playhead >= viewport.startFrame && playhead < viewport.endFrame
        return inside ? nil : flip(to: playhead, visible: visible)
    }

    private static func flip(to frame: FrameIndex, visible: FrameIndex) -> FrameIndex {
        Swift.max(0, frame - FrameIndex(leadFraction * Double(visible)))
    }
}
