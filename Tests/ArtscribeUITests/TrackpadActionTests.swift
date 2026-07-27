import Testing

@testable import ArtscribeUI

@Suite("TrackpadAction")
struct TrackpadActionTests {

    @Test("a horizontal swipe pans against the finger direction")
    func horizontalScroll() {
        #expect(TrackpadAction(scrollingDeltaX: 12, scrollingDeltaY: 0) == .pan(points: -12))
        #expect(TrackpadAction(scrollingDeltaX: -12, scrollingDeltaY: 0) == .pan(points: 12))
    }

    /// A mouse wheel, and shift-scroll on a trackpad, only report vertically.
    @Test("a vertical-only scroll still pans")
    func verticalScroll() {
        #expect(TrackpadAction(scrollingDeltaX: 0, scrollingDeltaY: 9) == .pan(points: 9))
        #expect(TrackpadAction(scrollingDeltaX: 0, scrollingDeltaY: -9) == .pan(points: -9))
    }

    @Test("a scroll too small to move a pixel is discarded, not rounded to a jump")
    func tinyScroll() {
        #expect(TrackpadAction(scrollingDeltaX: 0.2, scrollingDeltaY: 0) == nil)
        #expect(TrackpadAction(scrollingDeltaX: 0, scrollingDeltaY: 0) == nil)
        #expect(TrackpadAction(scrollingDeltaX: .nan, scrollingDeltaY: 0) == nil)
    }

    @Test("horizontal travel wins when both axes move")
    func horizontalWins() {
        #expect(TrackpadAction(scrollingDeltaX: 5, scrollingDeltaY: 40) == .pan(points: -5))
    }

    @Test("a full pinch doubles or halves the zoom")
    func pinch() {
        #expect(TrackpadAction(magnification: 0.5) == .zoom(factor: 2))
        #expect(TrackpadAction(magnification: 0) == .zoom(factor: 1))
        #expect(TrackpadAction(magnification: 0.05) == .zoom(factor: 1.1))
    }

    /// A pinch that would invert or blow up the scale must be dropped: the
    /// viewport would otherwise be asked to zoom by a non-positive factor.
    @Test("a degenerate pinch is discarded")
    func degeneratePinch() {
        #expect(TrackpadAction(magnification: -1) == nil)
        #expect(TrackpadAction(magnification: -5) == nil)
        #expect(TrackpadAction(magnification: .nan) == nil)
        #expect(TrackpadAction(magnification: .infinity) == nil)
    }
}
