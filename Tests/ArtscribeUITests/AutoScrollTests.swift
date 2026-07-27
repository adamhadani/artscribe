import ArtscribeKit
import Testing

@testable import ArtscribeUI

/// Page-flip auto-scroll (spec §6.1).
///
/// Continuous centred scrolling is explicitly rejected: it demos well and is
/// miserable to transcribe against, because the waveform never stops moving. So
/// the only two answers this function may give are "leave the view alone" and
/// "flip to the page containing the playhead" — never "nudge".
@Suite("Auto-scroll")
struct AutoScrollTests {

    private static let total: FrameIndex = 1_000_000

    /// A viewport showing frames 100 000–200 000 of a one-million-frame file.
    private func zoomed() -> Viewport {
        var viewport = Viewport(totalFrames: Self.total, widthPixels: 1000)
        viewport.zoom(to: FrameRange(start: 100_000, count: 100_000))
        return viewport
    }

    private var lead: FrameIndex { FrameIndex(AutoScroll.leadFraction * 100_000) }

    @Test("a playhead inside the window leaves the view alone")
    func insideHolds() {
        #expect(
            AutoScroll.pageStart(playhead: 150_000, viewport: zoomed(), loop: LoopRegion())
                == nil)
    }

    @Test("a playhead past the right edge flips forward one page")
    func flipsForward() {
        let start = AutoScroll.pageStart(
            playhead: 250_000, viewport: zoomed(), loop: LoopRegion())
        #expect(start == 250_000 - lead)
    }

    /// The playhead lands a little way in from the left edge rather than exactly
    /// on it, so the moment you flip you can already see what just went past.
    @Test("the flipped page puts the playhead in from the left edge, not on it")
    func flipLeavesLeadIn() {
        let viewport = zoomed()
        guard
            let start = AutoScroll.pageStart(
                playhead: 250_000, viewport: viewport, loop: LoopRegion())
        else {
            Issue.record("expected a page flip")
            return
        }
        #expect(start < 250_000)
        #expect(250_000 - start < viewport.visibleFrames / 2)
    }

    @Test("a playhead before the left edge flips backward the same way")
    func flipsBackward() {
        let start = AutoScroll.pageStart(playhead: 50_000, viewport: zoomed(), loop: LoopRegion())
        #expect(start == 50_000 - lead)
    }

    @Test("a flip near the start of the file clamps at zero rather than going negative")
    func clampsAtZero() {
        #expect(AutoScroll.pageStart(playhead: 5_000, viewport: zoomed(), loop: LoopRegion()) == 0)
    }

    @Test("nothing scrolls when the whole file already fits on screen")
    func wholeFileFitsHolds() {
        let viewport = Viewport(totalFrames: Self.total, widthPixels: 1000)
        #expect(
            AutoScroll.pageStart(playhead: Self.total, viewport: viewport, loop: LoopRegion())
                == nil)
    }

    // MARK: - Loop suppression

    /// The point of the suppression: while you are looping four bars, the view
    /// must stop moving entirely — including at the wrap, where the playhead
    /// jumps backward every pass.
    @Test("an active loop that fits on screen suppresses scrolling completely")
    func activeLoopSuppresses() {
        let loop = LoopRegion(
            range: FrameRange(start: 120_000, count: 40_000), isEnabled: true)
        for playhead in [FrameIndex(120_000), 140_000, 159_999] {
            #expect(AutoScroll.pageStart(playhead: playhead, viewport: zoomed(), loop: loop) == nil)
        }
    }

    @Test("a disabled loop does not suppress scrolling")
    func disabledLoopDoesNotSuppress() {
        let loop = LoopRegion(
            range: FrameRange(start: 120_000, count: 40_000), isEnabled: false)
        #expect(
            AutoScroll.pageStart(playhead: 250_000, viewport: zoomed(), loop: loop)
                == 250_000 - lead)
    }

    @Test("an active loop longer than the window still page-flips")
    func longLoopStillFlips() {
        let loop = LoopRegion(
            range: FrameRange(start: 100_000, count: 400_000), isEnabled: true)
        #expect(
            AutoScroll.pageStart(playhead: 250_000, viewport: zoomed(), loop: loop)
                == 250_000 - lead)
    }

    /// Suppression means "do not follow the playhead", not "never move". A loop
    /// that fits but is off screen — you scrolled away, or set it from the
    /// overview — is brought into view once, and then held.
    @Test("an active loop that fits but is off screen is brought on screen once")
    func offScreenLoopIsBroughtIntoView() {
        let loop = LoopRegion(
            range: FrameRange(start: 600_000, count: 40_000), isEnabled: true)
        var viewport = zoomed()
        guard let start = AutoScroll.pageStart(playhead: 610_000, viewport: viewport, loop: loop)
        else {
            Issue.record("expected the off-screen loop to be brought into view")
            return
        }
        #expect(start == 600_000 - lead)

        // Having scrolled there, the next tick must hold.
        viewport.scroll(byPixels: Int((Double(start - viewport.startFrame) / 100).rounded()))
        #expect(AutoScroll.pageStart(playhead: 610_000, viewport: viewport, loop: loop) == nil)
    }
}
