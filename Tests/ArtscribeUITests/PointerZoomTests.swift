import CoreGraphics
import Testing

@testable import ArtscribeUI

/// The pure half of pointer-anchored zoom: which lane the pointer is over, and
/// where inside it. The `NSEvent` → window-point conversion is AppKit's job and
/// is exercised by the acceptance run; this is the decision that follows it.
@Suite("PointerZoom")
struct PointerZoomTests {

    /// Roughly the real layout: overview strip under the title bar, lanes below
    /// the ruler, both full width.
    private let overview = CGRect(x: 0, y: 40, width: 1280, height: 58)
    private let lanes = CGRect(x: 0, y: 122, width: 1280, height: 500)

    @Test("a point in the lanes anchors on the lanes, in local coordinates")
    func insideLanes() {
        let target = PointerZoom.target(
            at: CGPoint(x: 640, y: 300), lanes: lanes, overview: overview)
        #expect(target == .lanes(x: 640))
    }

    @Test("a point in the overview anchors on the overview")
    func insideOverview() {
        let target = PointerZoom.target(
            at: CGPoint(x: 200, y: 60), lanes: lanes, overview: overview)
        #expect(target == .overview(x: 200))
    }

    /// The lanes are not always at x == 0 — a future inspector column would
    /// inset them — so the x handed on must be local to the lane, not the window.
    @Test("the x handed on is local to the lane, not to the window")
    func localCoordinates() {
        let inset = CGRect(x: 180, y: 122, width: 1100, height: 500)
        let target = PointerZoom.target(
            at: CGPoint(x: 400, y: 300), lanes: inset, overview: overview)
        #expect(target == .lanes(x: 220))
    }

    @Test("a point over the ruler, the status bar or nothing at all has no target")
    func outside() {
        #expect(
            PointerZoom.target(at: CGPoint(x: 640, y: 110), lanes: lanes, overview: overview)
                == nil)
        #expect(
            PointerZoom.target(at: CGPoint(x: 640, y: 700), lanes: lanes, overview: overview)
                == nil)
        #expect(
            PointerZoom.target(at: CGPoint(x: 640, y: 10), lanes: lanes, overview: overview)
                == nil)
    }

    /// Before the first layout pass both frames are `.zero`; a zoom then has to
    /// fall back to the playhead rather than anchor at frame 0.
    @Test("an unlaid-out lane has no target")
    func emptyFrames() {
        #expect(PointerZoom.target(at: .zero, lanes: .zero, overview: .zero) == nil)
    }

    @Test("a non-finite point has no target")
    func nonFinitePoint() {
        #expect(
            PointerZoom.target(
                at: CGPoint(x: CGFloat.nan, y: 300), lanes: lanes, overview: overview)
                == nil)
    }
}
