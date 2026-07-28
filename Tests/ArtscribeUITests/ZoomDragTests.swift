import ArtscribeKit
import CoreGraphics
import Foundation
import Testing

@testable import ArtscribeUI

/// The pure half of drag-to-zoom: how far a vertical drag moves the zoom, and
/// what a left-drag in the lanes was decided to mean.
///
/// Views are not snapshot-tested here, so this is where the gesture maths is
/// pinned. The two properties that matter are *smoothness* (no steps, no dead
/// zone) and *absoluteness* (the zoom is a function of where the pointer is
/// now, not of the path it took there) — a drag that integrated increments
/// would drift, and would not come back when you dragged back.
@Suite("ZoomDrag")
struct ZoomDragTests {

    private static let start = CGPoint(x: 400, y: 300)

    private func drag(framesPerPixel: Double = 8, anchorFrame: FrameIndex = 12_345) -> ZoomDrag {
        ZoomDrag(
            start: Self.start, anchorFrame: anchorFrame, startFramesPerPixel: framesPerPixel)
    }

    // MARK: - Direction

    /// **Drag down to zoom in.** Task 16 shipped the opposite, reasoning from
    /// Ableton's and Melodyne's beat-time rulers (neither manual states a
    /// direction) and from the wheel. The user has since driven it and prefers
    /// down; their hand beats the reasoning, so this is the shipped default and
    /// the old direction is one Settings toggle away.
    @Test("dragging down zooms in and dragging up zooms out")
    func direction() {
        #expect(ZoomDrag.cumulativeFactor(fromY: 300, toY: 400).map { $0 > 1 } == true)
        #expect(ZoomDrag.cumulativeFactor(fromY: 300, toY: 200).map { $0 < 1 } == true)
    }

    @Test("the preference flips it back, exactly")
    func invertedDirection() throws {
        let downNormal = try #require(ZoomDrag.cumulativeFactor(fromY: 300, toY: 400))
        let downInverted = try #require(
            ZoomDrag.cumulativeFactor(fromY: 300, toY: 400, inverted: true))
        #expect(downInverted < 1)
        // Not merely "the other way": the same travel must produce exactly the
        // reciprocal, or the two directions are different gestures.
        #expect(abs(downNormal * downInverted - 1) < 1e-12)
    }

    @Test("a drag that has not moved vertically has not zoomed, either way round")
    func identity() {
        #expect(ZoomDrag.cumulativeFactor(fromY: 300, toY: 300) == 1)
        #expect(ZoomDrag.cumulativeFactor(fromY: 300, toY: 300, inverted: true) == 1)
    }

    @Test("a drag of the doubling distance doubles the zoom")
    func oneDoubling() {
        let down = ZoomDrag.cumulativeFactor(fromY: 300, toY: 300 + ZoomDrag.pointsPerDoubling)
        let up = ZoomDrag.cumulativeFactor(fromY: 300, toY: 300 - ZoomDrag.pointsPerDoubling)
        #expect(down.map { abs($0 - 2) < 1e-12 } == true)
        #expect(up.map { abs($0 - 0.5) < 1e-12 } == true)
    }

    /// Down then equally up must land exactly back, or a zoom sweep drifts.
    @Test("equal and opposite travel cancels out")
    func symmetry() throws {
        let down = try #require(ZoomDrag.cumulativeFactor(fromY: 300, toY: 390))
        let up = try #require(ZoomDrag.cumulativeFactor(fromY: 300, toY: 210))
        #expect(abs(up * down - 1) < 1e-12)
    }

    // MARK: - Smoothness

    /// The whole reason to have this gesture: every single point of travel has
    /// to move the zoom, by a small and equal proportion. A stepped
    /// implementation (rounding travel to notches, or a dead zone near the
    /// start) fails both halves of this.
    @Test("every point of travel moves the zoom, by an equal proportion")
    func smoothNotStepped() throws {
        let step = pow(2, 1 / ZoomDrag.pointsPerDoubling)
        var previous = try #require(ZoomDrag.cumulativeFactor(fromY: 300, toY: 300))
        for offset in 1...240 {
            let factor = try #require(
                ZoomDrag.cumulativeFactor(fromY: 300, toY: 300 + Double(offset)))
            #expect(factor > previous, "travel of \(offset) points did not move the zoom")
            #expect(abs(factor / previous - step) < 1e-12)
            previous = factor
        }
    }

    // MARK: - Absoluteness

    /// Sampling the drag every point and jumping straight to its end must give
    /// the same zoom. This is what makes it drift-free: each event asks for the
    /// zoom the *current* pointer position implies, rather than compounding a
    /// per-event increment.
    @Test("a sampled drag and a single jump land on the same zoom")
    func pathIndependence() {
        var sampled = Viewport(totalFrames: 2_000_000, widthPixels: 1000)
        var jumped = sampled
        let gesture = drag(framesPerPixel: sampled.framesPerPixel, anchorFrame: 500_000)

        for offset in stride(from: 1.0, through: 200.0, by: 1.0) {
            guard
                let factor = gesture.factor(
                    atY: 300 + offset, currentFramesPerPixel: sampled.framesPerPixel)
            else { continue }
            sampled.zoom(by: factor, anchorFrame: gesture.anchorFrame)
        }
        if let factor = gesture.factor(atY: 500, currentFramesPerPixel: jumped.framesPerPixel) {
            jumped.zoom(by: factor, anchorFrame: gesture.anchorFrame)
        }

        #expect(abs(sampled.framesPerPixel - jumped.framesPerPixel) < 1e-9)
    }

    /// Drag past the viewport's own zoom ceiling and back again. An incremental
    /// gesture would leave the zoom stuck at the clamp for the whole return
    /// journey; an absolute one comes straight back.
    @Test("a drag past the zoom limit comes back when you drag back")
    func clampIsNotSticky() {
        var viewport = Viewport(totalFrames: 2_000_000, widthPixels: 1000)
        let before = viewport.framesPerPixel
        let gesture = drag(framesPerPixel: before, anchorFrame: 1_000_000)

        for y in stride(from: 300.0, through: 2600.0, by: 20.0) {
            guard
                let factor = gesture.factor(atY: y, currentFramesPerPixel: viewport.framesPerPixel)
            else { continue }
            viewport.zoom(by: factor, anchorFrame: gesture.anchorFrame)
        }
        #expect(viewport.framesPerPixel < before)

        for y in stride(from: 2600.0, through: 300.0, by: -20.0) {
            guard
                let factor = gesture.factor(atY: y, currentFramesPerPixel: viewport.framesPerPixel)
            else { continue }
            viewport.zoom(by: factor, anchorFrame: gesture.anchorFrame)
        }
        #expect(abs(viewport.framesPerPixel - before) < 1e-9)
    }

    // MARK: - Degenerate input

    /// A synthesised or flung event can report an absurd position, and `pow`
    /// turns that into a factor of billions in one step.
    @Test("absurd travel is clamped rather than blowing up")
    func clamped() throws {
        let down = try #require(ZoomDrag.cumulativeFactor(fromY: 300, toY: 1_000_000))
        let up = try #require(ZoomDrag.cumulativeFactor(fromY: 300, toY: -1_000_000))
        #expect(down.isFinite)
        #expect(up > 0)
        #expect(abs(up * down - 1) < 1e-9)
    }

    @Test("a non-finite position produces no zoom at all")
    func nonFinite() {
        #expect(ZoomDrag.cumulativeFactor(fromY: .nan, toY: 300) == nil)
        #expect(ZoomDrag.cumulativeFactor(fromY: 300, toY: .nan) == nil)
        #expect(ZoomDrag.cumulativeFactor(fromY: 300, toY: .infinity) == nil)
        #expect(drag().factor(atY: .nan, currentFramesPerPixel: 8) == nil)
        #expect(drag().factor(atY: 200, currentFramesPerPixel: 0) == nil)
        #expect(drag(framesPerPixel: 0).factor(atY: 200, currentFramesPerPixel: 8) == nil)
    }
}

/// What a left-drag in the waveform lanes was decided to mean. Decided once,
/// when the mouse goes down, and held for the gesture's life — see
/// `ViewerModel.laneDragChanged`.
@Suite("LaneDragMode")
struct LaneDragModeTests {

    @Test("a plain drag selects")
    func plain() {
        #expect(LaneDragMode(option: false, shift: false) == .select(extending: false))
    }

    @Test("Shift-drag extends the selection")
    func shift() {
        #expect(LaneDragMode(option: false, shift: true) == .select(extending: true))
    }

    /// ⌥ is the zoom modifier because it collides with neither ⇧-drag (extend)
    /// nor ⌘-drag, and because Melodyne sets the precedent for a modifier-drag
    /// zoom inside the editing pane.
    @Test("Option-drag zooms")
    func option() {
        #expect(LaneDragMode(option: true, shift: false) == .zoom)
    }

    /// Holding both is a typo, not a third gesture. ⌥ wins, matching the way
    /// ⌥ beats ⇧ in the nudge tiers.
    @Test("Option beats Shift when both are held")
    func optionBeatsShift() {
        #expect(LaneDragMode(option: true, shift: true) == .zoom)
    }
}
