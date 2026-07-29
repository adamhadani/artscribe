import AppKit
import Testing

@testable import ArtscribeUI

@MainActor
@Suite("TrackpadAction")
struct TrackpadActionTests {

    /// A two-finger trackpad swipe: macOS reports precise (point) deltas.
    private func swipe(
        x: Double = 0, y: Double = 0, command: Bool = false, shift: Bool = false,
        momentum: Bool = false, at anchor: CGPoint? = nil
    ) -> TrackpadAction? {
        TrackpadAction(
            scrollingDeltaX: x, scrollingDeltaY: y, hasPreciseScrollingDeltas: true,
            commandHeld: command, shiftHeld: shift, isMomentum: momentum, at: anchor)
    }

    /// A physical mouse wheel: coarse line deltas, `hasPreciseScrollingDeltas`
    /// false. This is the distinction the whole P0 split rests on.
    private func wheel(
        x: Double = 0, y: Double = 0, command: Bool = false, shift: Bool = false,
        at anchor: CGPoint? = nil
    ) -> TrackpadAction? {
        TrackpadAction(
            scrollingDeltaX: x, scrollingDeltaY: y, hasPreciseScrollingDeltas: false,
            commandHeld: command, shiftHeld: shift, at: anchor)
    }

    private func factor(_ action: TrackpadAction?) -> Double? {
        guard case .zoom(let factor, _) = action else { return nil }
        return factor
    }

    // MARK: - Trackpad keeps panning

    @Test("a horizontal swipe pans against the finger direction")
    func horizontalScroll() {
        #expect(swipe(x: 12) == .pan(points: -12))
        #expect(swipe(x: -12) == .pan(points: 12))
    }

    @Test("a vertical two-finger swipe still pans")
    func verticalScroll() {
        #expect(swipe(y: 9) == .pan(points: 9))
        #expect(swipe(y: -9) == .pan(points: -9))
    }

    @Test("a scroll too small to move a pixel is discarded, not rounded to a jump")
    func tinyScroll() {
        #expect(swipe(x: 0.2) == nil)
        #expect(swipe() == nil)
        #expect(swipe(x: .nan) == nil)
        #expect(swipe(y: .nan) == nil)
    }

    @Test("horizontal travel wins when both axes move")
    func horizontalWins() {
        #expect(swipe(x: 5, y: 40) == .pan(points: -5))
    }

    // MARK: - Mouse wheel zooms

    /// The user's request, and the convention of every app with a zoom: the
    /// gesture that scrolls content up zooms in.
    @Test("a mouse wheel zooms rather than pans, up in and down out")
    func wheelZooms() {
        #expect(factor(wheel(y: 1)).map { $0 > 1 } == true)
        #expect(factor(wheel(y: -1)).map { $0 < 1 } == true)
    }

    @Test("a bigger wheel movement zooms further")
    func wheelIsMonotonic() {
        guard let one = factor(wheel(y: 1)), let three = factor(wheel(y: 3)) else {
            Issue.record("a wheel notch must produce a zoom")
            return
        }
        #expect(three > one)
    }

    /// Rolling back must undo rolling forward, or a wheel sweep drifts.
    @Test("equal and opposite wheel movements cancel out")
    func wheelIsSymmetric() {
        guard let up = factor(wheel(y: 2)), let down = factor(wheel(y: -2)) else {
            Issue.record("a wheel notch must produce a zoom")
            return
        }
        #expect(abs(up * down - 1) < 1e-12)
    }

    /// A flung wheel (or a synthetic event) can report an absurd delta; without
    /// a clamp `pow` runs away to a factor of millions in one event.
    @Test("an absurd wheel delta is clamped rather than teleporting the zoom")
    func wheelIsClamped() {
        guard let huge = factor(wheel(y: 10_000)), let tiny = factor(wheel(y: -10_000)) else {
            Issue.record("a clamped wheel delta still zooms")
            return
        }
        #expect(huge <= 10)
        #expect(tiny >= 0.1)
        #expect(huge.isFinite)
        #expect(tiny > 0)
    }

    /// A tilt wheel reports horizontally. Zoom is a vertical gesture, so this
    /// stays a pan — which is also the only pan a plain mouse has left.
    @Test("a horizontal-only wheel movement pans")
    func wheelTiltPans() {
        #expect(wheel(x: 1) == .pan(points: -Int(TrackpadAction.pointsPerLine)))
    }

    /// A wheel reports **lines**, not points — that is the same fact the device
    /// split is built on. Feeding a line count straight into a pan measured in
    /// points moves the viewport one point per detent, which is a dead control:
    /// about twelve hundred detents to cross the window.
    @Test("a wheel detent pans a whole line's worth of points, not one point")
    func wheelPanIsMeasuredInPoints() {
        #expect(wheel(y: 1, shift: true) == .pan(points: Int(TrackpadAction.pointsPerLine)))
        #expect(wheel(y: -2, shift: true) == .pan(points: -2 * Int(TrackpadAction.pointsPerLine)))
    }

    /// The trackpad's deltas really are in points, and must not be scaled.
    @Test("a trackpad swipe pans by exactly the points it reported")
    func trackpadPanIsUnscaled() {
        #expect(swipe(y: 9) == .pan(points: 9))
        #expect(swipe(x: 12) == .pan(points: -12))
    }

    @Test("a wheel event with no movement at all is discarded")
    func emptyWheel() {
        #expect(wheel() == nil)
        #expect(wheel(y: .nan) == nil)
    }

    // MARK: - Modifiers

    @Test("Command-scroll zooms on a trackpad too")
    func commandSwipeZooms() {
        #expect(factor(swipe(y: 30, command: true)).map { $0 > 1 } == true)
        #expect(factor(swipe(y: -30, command: true)).map { $0 < 1 } == true)
    }

    @Test("Command-scroll on a wheel still zooms")
    func commandWheelZooms() {
        #expect(factor(wheel(y: 1, command: true)).map { $0 > 1 } == true)
        #expect(factor(wheel(y: -1, command: true)).map { $0 < 1 } == true)
    }

    // MARK: - Command-scroll is the *fine* zoom

    /// The wheel already zooms bare, so `⌘` duplicating it would be worth
    /// nothing. It is the careful gear instead — and "finer" has to mean
    /// strictly less zoom for the same travel, in both directions.
    @Test("Command-scroll zooms less far than the same bare wheel movement")
    func commandWheelIsFiner() throws {
        for lines in [0.5, 1.0, 3.0, 10.0] {
            let coarse = try #require(factor(wheel(y: lines)))
            let fine = try #require(factor(wheel(y: lines, command: true)))
            #expect(fine > 1)
            #expect(fine < coarse, "⌘ over \(lines) lines was not finer than bare")

            let coarseOut = try #require(factor(wheel(y: -lines)))
            let fineOut = try #require(factor(wheel(y: -lines, command: true)))
            #expect(fineOut < 1)
            #expect(fineOut > coarseOut, "⌘ out over \(lines) lines was not finer than bare")
        }
    }

    /// The rate is the *exponent's* — which is what keeps a fine zoom composable
    /// with a coarse one instead of merely smaller. Pinned on both devices,
    /// because the wheel and the trackpad reach `zoomFactor` by different
    /// arithmetic.
    @Test("the fine rate is exactly the named fraction of the coarse one")
    func fineRateIsTheNamedFraction() throws {
        let wheelCoarse = try #require(factor(wheel(y: 3)))
        let wheelFine = try #require(factor(wheel(y: 3, command: true)))
        #expect(abs(log2(wheelFine) / log2(wheelCoarse) - TrackpadAction.fineZoomRate) < 1e-12)

        // A trackpad's bare vertical swipe pans, so the coarse comparison is
        // against the documented rate rather than another action.
        let swipeFine = try #require(factor(swipe(y: 90, command: true)))
        let coarseExponent = 90 / TrackpadAction.pointsPerDoubling
        #expect(abs(log2(swipeFine) / coarseExponent - TrackpadAction.fineZoomRate) < 1e-12)
    }

    /// Roughly a quarter to a third: below that the control is dead, above it
    /// there is no felt difference from the bare gesture.
    @Test("the fine rate is genuinely finer, and not so fine it is dead")
    func fineRateIsInBand() {
        #expect(TrackpadAction.fineZoomRate > 0.2)
        #expect(TrackpadAction.fineZoomRate < 0.4)
    }

    /// Three fine notches must land exactly where one coarse notch does, and a
    /// fine zoom must still undo itself. Both follow from scaling the exponent
    /// and neither survives scaling the factor.
    @Test("fine notches compose and cancel like coarse ones")
    func fineZoomComposes() throws {
        let coarse = try #require(factor(wheel(y: 1)))
        let fine = try #require(factor(wheel(y: 1, command: true)))
        #expect(abs(pow(fine, 1 / TrackpadAction.fineZoomRate) - coarse) < 1e-12)

        let back = try #require(factor(wheel(y: -1, command: true)))
        #expect(abs(fine * back - 1) < 1e-12)
    }

    /// The clamp still holds with `⌘` down: it is applied to the raw delta,
    /// before the rate, so a flung wheel cannot escape it by holding a modifier.
    @Test("an absurd Command-scroll delta is still clamped")
    func fineZoomIsClamped() throws {
        let huge = try #require(factor(wheel(y: 10_000, command: true)))
        let tiny = try #require(factor(wheel(y: -10_000, command: true)))
        #expect(huge.isFinite)
        #expect(huge <= 10)
        #expect(tiny > 0)
        #expect(abs(huge * tiny - 1) < 1e-12)
    }

    /// Shift is the pan escape hatch, the mirror of Command being the zoom one:
    /// without it a plain mouse could no longer scroll the timeline at all.
    @Test("Shift-scroll pans on both devices")
    func shiftPans() {
        let line = Int(TrackpadAction.pointsPerLine)
        #expect(wheel(y: 1, shift: true) == .pan(points: line))
        #expect(swipe(y: 9, shift: true) == .pan(points: 9))
        #expect(wheel(x: 1, shift: true) == .pan(points: -line))
    }

    /// The coasting tail after the fingers leave the trackpad.
    @Test("momentum keeps panning but never zooms")
    func momentum() {
        #expect(swipe(y: 9, momentum: true) == .pan(points: 9))
        #expect(swipe(y: 30, command: true, momentum: true) == nil)
    }

    @Test("Command beats Shift when both are held")
    func commandBeatsShift() {
        #expect(factor(wheel(y: 1, command: true, shift: true)).map { $0 > 1 } == true)
    }

    // MARK: - Anchor

    @Test("a zoom carries the pointer position so it can anchor there")
    func zoomCarriesAnchor() {
        let point = CGPoint(x: 640, y: 300)
        #expect(
            wheel(y: 1, at: point).map { action in
                guard case .zoom(_, let anchor) = action else { return false }
                return anchor == point
            } == true)
        #expect(
            swipe(y: 30, command: true, at: point).map { action in
                guard case .zoom(_, let anchor) = action else { return false }
                return anchor == point
            } == true)
    }

    // MARK: - Pinch

    @Test("a full pinch doubles or halves the zoom")
    func pinch() {
        #expect(TrackpadAction(magnification: 0.5, at: nil) == .zoom(factor: 2, anchor: nil))
        #expect(TrackpadAction(magnification: 0, at: nil) == .zoom(factor: 1, anchor: nil))
        #expect(TrackpadAction(magnification: 0.05, at: nil) == .zoom(factor: 1.1, anchor: nil))
    }

    /// A pinch that would invert or blow up the scale must be dropped: the
    /// viewport would otherwise be asked to zoom by a non-positive factor.
    @Test("a degenerate pinch is discarded")
    func degeneratePinch() {
        #expect(TrackpadAction(magnification: -1, at: nil) == nil)
        #expect(TrackpadAction(magnification: -5, at: nil) == nil)
        #expect(TrackpadAction(magnification: .nan, at: nil) == nil)
        #expect(TrackpadAction(magnification: .infinity, at: nil) == nil)
    }

    // MARK: - Real events

    /// The device split is read off `hasPreciseScrollingDeltas`, so it is worth
    /// proving that a line-unit event really does report `false` and a
    /// pixel-unit one `true` — the mapping above is only correct if that holds.
    @Test("a line-unit event is a wheel and a pixel-unit event is a trackpad")
    func realEventClassification() throws {
        let lines = try #require(scrollEvent(units: .line, wheel1: 1))
        let points = try #require(scrollEvent(units: .pixel, wheel1: 24))
        #expect(lines.hasPreciseScrollingDeltas == false)
        #expect(points.hasPreciseScrollingDeltas == true)

        #expect(factor(TrackpadAction(event: lines)).map { $0 > 1 } == true)
        #expect(TrackpadAction(event: points) == .pan(points: 24))

        // The same line-unit event, panned rather than zoomed: one detent has to
        // be worth a line of travel, not a single point.
        let shifted = TrackpadAction(
            scrollingDeltaX: lines.scrollingDeltaX, scrollingDeltaY: lines.scrollingDeltaY,
            hasPreciseScrollingDeltas: lines.hasPreciseScrollingDeltas,
            commandHeld: false, shiftHeld: true, at: nil)
        #expect(shifted == .pan(points: Int(TrackpadAction.pointsPerLine)))
    }

    /// The natural-scrolling preference is applied by macOS *before* the event
    /// is delivered, and reported by `isDirectionInvertedFromDevice`. Reading
    /// that flag here would invert the gesture a second time for exactly the
    /// users who flipped the setting, so the mapping is deliberately a function
    /// of the delivered delta alone — which is what makes it follow the
    /// preference. This test pins that: nothing in the mapping consults the
    /// flag, so the same delivered delta always means the same thing.
    @Test("the direction comes from the delivered delta, never re-inverted")
    func naturalScrollingIsRespected() throws {
        let event = try #require(scrollEvent(units: .line, wheel1: 1))
        let mapped = TrackpadAction(
            scrollingDeltaX: event.scrollingDeltaX,
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            commandHeld: false, shiftHeld: false, at: nil)
        #expect(TrackpadAction(event: event) == mapped)
    }

    // MARK: - Which window the gesture belongs to

    /// The P0 this rule exists for: the shortcut window's list is a
    /// `ScrollView`, the monitor is a **local** one and so sees every scroll the
    /// application receives, and it returns `nil` for anything it handles. Any
    /// answer but "not the viewer's" here is a wheel notch eaten in one window
    /// and spent panning the waveform in another.
    ///
    /// Driven as a pure function because two of these four states cannot be
    /// produced in a running acceptance harness: it posts synthesised events,
    /// which carry no window at all.
    @Test("a scroll in another plain window is not the viewer's")
    func scrollInASecondWindowIsNotOurs() {
        let other = NSObject()
        #expect(
            !TrackpadAction.belongsToTheViewer(
                modalIsUp: false, window: other, isPanel: false, isDocument: false))
    }

    @Test("a scroll in the document window is the viewer's")
    func scrollInTheDocumentIsOurs() {
        #expect(
            TrackpadAction.belongsToTheViewer(
                modalIsUp: false, window: NSObject(), isPanel: false, isDocument: true))
    }

    /// A synthesised event — what the acceptance harness posts — carries no
    /// window, and nothing else in this app produces one. Refusing it would take
    /// every trackpad, wheel and pinch check in the run down with it.
    @Test("a synthesised event with no window is the viewer's")
    func synthesisedEventIsOurs() {
        #expect(
            TrackpadAction.belongsToTheViewer(
                modalIsUp: false, window: nil, isPanel: false, isDocument: false))
    }

    /// The two cases the rule already had, kept: the open panel's file list, and
    /// anything at all while a modal session is up.
    @Test("a scroll over a panel or under a modal is never the viewer's")
    func panelsAndModalsAreNeverOurs() {
        #expect(
            !TrackpadAction.belongsToTheViewer(
                modalIsUp: false, window: NSObject(), isPanel: true, isDocument: true))
        #expect(
            !TrackpadAction.belongsToTheViewer(
                modalIsUp: true, window: nil, isPanel: false, isDocument: true))
    }

    private func scrollEvent(units: CGScrollEventUnit, wheel1: Int32) -> NSEvent? {
        CGEvent(
            scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: wheel1, wheel2: 0,
            wheel3: 0
        ).flatMap(NSEvent.init(cgEvent:))
    }
}
