import AppKit

/// What a scroll or pinch event means to the viewer. Extracted from the
/// `NSEvent` on the spot so only plain numbers cross into main-actor code —
/// `NSEvent` itself is not `Sendable`.
///
/// **The device split.** A physical mouse wheel and a two-finger trackpad swipe
/// arrive as the same event type and are told apart only by
/// `hasPreciseScrollingDeltas` (false for the wheel's coarse line deltas). They
/// carry opposite conventions: a wheel is the zoom control in every app that has
/// a zoom, while two-finger scrolling is panning system-wide. So the wheel
/// zooms, the trackpad pans, and two modifiers cross over — `⌘` zooms on either
/// device, `⇧` pans on either — which also leaves a plain mouse a way to pan.
enum TrackpadAction: Equatable, Sendable {
    case pan(points: Int)
    /// `anchor` is the pointer position in window coordinates, or `nil` when the
    /// event carried no usable one. The model turns it into a frame; a zoom that
    /// anchored anywhere but under the pointer feels broken.
    case zoom(factor: Double, anchor: CGPoint?)

    /// Pinch deltas arrive in small increments; this turns a full `+1.0`
    /// magnification into a doubling of zoom.
    static let pinchGain = 2.0

    /// Zoom per line of wheel travel. One detent is normally one line, so this
    /// is the per-notch step — a little coarser than the keyboard's half-octave
    /// because a wheel is a coarse control and a notch that does nothing visible
    /// reads as a dead control.
    static let wheelZoomPerLine = 1.25
    /// Points of `⌘`-scroll on a trackpad per doubling of zoom. A precise delta
    /// is measured in points, not notches, and a brisk two-finger swipe covers a
    /// few hundred of them, so the gain has to be far gentler than the wheel's.
    static let pointsPerDoubling = 90.0

    /// What `⌘`-scroll zooms *relative to* the bare rate, as a fraction of the
    /// exponent — a third, so three times the travel for the same result.
    ///
    /// The wheel already zooms bare, so without this `⌘` would merely duplicate
    /// it and be worth nothing. Made finer instead, it becomes the careful
    /// control: the one you reach for to creep up on a transient rather than to
    /// cross four octaves of zoom. A third is far enough below 1 to feel like a
    /// different gear and far enough above 0 that a notch still visibly moves —
    /// a "fine" control that does nothing reads as a broken one.
    ///
    /// On a trackpad this is the only scroll-zoom (a bare two-finger swipe
    /// pans), so it makes that gesture slower too. Deliberate: pinch and the
    /// new vertical drag are both coarse and both closer to hand there.
    static let fineZoomRate = 1.0 / 3.0

    /// A wheel's deltas are in **lines**, not points — the same fact the device
    /// split is read off. Panning is measured in points, so a line has to be
    /// converted or a detent moves the viewport by a single point: about twelve
    /// hundred detents to cross the window, which is a dead control. Roughly a
    /// sixth of the keyboard's `Z`/`X` step, so a wheel flick and a key press
    /// are in the same world.
    static let pointsPerLine = 24.0

    /// Ceilings on one event's travel. A synthesised or flung event can report
    /// an absurd delta, and `pow` turns that into a zoom of millions in a single
    /// step — the viewport clamps the result, but the view would still teleport.
    static let maxWheelLines = 10.0
    static let maxPrecisePoints = 240.0

    /// A trackpad or wheel scroll.
    ///
    /// - Parameters:
    ///   - hasPreciseScrollingDeltas: false for a physical wheel.
    ///   - commandHeld: zooms regardless of device.
    ///   - shiftHeld: pans regardless of device. `⌘` wins if both are held.
    ///   - isMomentum: the coasting tail macOS keeps sending after the fingers
    ///     have left the trackpad. It still pans — that is what momentum is for —
    ///     but it must not zoom: the fingers are gone, and a zoom that keeps
    ///     accelerating after you let go overshoots every time.
    ///   - anchor: pointer position in window coordinates.
    ///
    /// The deltas are used exactly as macOS delivered them. The natural-scrolling
    /// preference is applied by the system *before* delivery (and reported after
    /// the fact by `isDirectionInvertedFromDevice`), so consulting that flag here
    /// would invert the gesture a second time for precisely the users who
    /// flipped the setting. Taking the delta at face value is what respects it.
    init?(
        scrollingDeltaX: Double,
        scrollingDeltaY: Double,
        hasPreciseScrollingDeltas: Bool,
        commandHeld: Bool,
        shiftHeld: Bool,
        isMomentum: Bool = false,
        at anchor: CGPoint?
    ) {
        guard scrollingDeltaX.isFinite, scrollingDeltaY.isFinite else { return nil }
        let zooms = commandHeld || (!hasPreciseScrollingDeltas && !shiftHeld)
        if zooms, isMomentum { return nil }
        // Zoom is a vertical gesture. A tilt wheel or a shift-swapped axis
        // reports horizontally, and that stays a pan.
        if zooms, scrollingDeltaY != 0 {
            guard
                let factor = Self.zoomFactor(
                    deltaY: scrollingDeltaY, precise: hasPreciseScrollingDeltas,
                    fine: commandHeld)
            else { return nil }
            self = .zoom(factor: factor, anchor: anchor)
            return
        }
        // A trackpad already reports points; a wheel reports lines.
        let travel = hasPreciseScrollingDeltas ? 1 : Self.pointsPerLine
        let delta = (scrollingDeltaX != 0 ? scrollingDeltaX : -scrollingDeltaY) * travel
        let points = Int(delta.rounded())
        guard points != 0 else { return nil }
        self = .pan(points: -points)
    }

    init?(magnification: Double, at anchor: CGPoint?) {
        let factor = 1 + magnification * Self.pinchGain
        guard factor > 0, factor.isFinite else { return nil }
        self = .zoom(factor: factor, anchor: anchor)
    }

    @MainActor
    init?(event: NSEvent) {
        guard Self.isOverTheViewer(event) else { return nil }
        let anchor = Self.windowPoint(for: event)
        switch event.type {
        case .scrollWheel:
            self.init(
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                commandHeld: event.modifierFlags.contains(.command),
                shiftHeld: event.modifierFlags.contains(.shift),
                isMomentum: !event.momentumPhase.isEmpty,
                at: anchor)
        case .magnify:
            self.init(magnification: event.magnification, at: anchor)
        default:
            return nil
        }
    }

    /// A positive delta means the content scrolled up, which zooms in.
    ///
    /// `fine` scales the *exponent*, not the factor, which is the only way the
    /// rate stays a rate: a fine zoom then remains symmetric (equal and
    /// opposite travel still cancels) and still composes, so three fine notches
    /// land exactly where one coarse one does.
    private static func zoomFactor(deltaY: Double, precise: Bool, fine: Bool) -> Double? {
        let rate = fine ? fineZoomRate : 1
        let factor: Double
        if precise {
            let points = Swift.max(-maxPrecisePoints, Swift.min(maxPrecisePoints, deltaY))
            factor = pow(2, points * rate / pointsPerDoubling)
        } else {
            let lines = Swift.max(-maxWheelLines, Swift.min(maxWheelLines, deltaY))
            factor = pow(wheelZoomPerLine, lines * rate)
        }
        guard factor > 0, factor.isFinite else { return nil }
        return factor
    }

    /// Whether this scroll belongs to the viewer at all.
    ///
    /// A local monitor sees every scroll the *application* receives, including
    /// ones over the open panel and over every other window this app has, and
    /// the frames the anchor is hit-tested against are the viewer's. Without
    /// this, rolling the wheel over the file list in `⌘O` zooms the waveform
    /// behind the panel — and the panel does not scroll, because the monitor
    /// swallows what it handles.
    ///
    /// Task 25's shortcut window turned that known limit into a P0: its list is
    /// a `ScrollView`, and every wheel notch over it was eaten here and spent on
    /// the waveform behind. So the test is now the window's **identity**, which
    /// `KeyWindowTracker` already holds because the menus needed the same fact.
    /// Key status is deliberately *not* the test: a scroll is delivered to the
    /// window under the pointer whether or not it is the one taking keystrokes,
    /// and on a screen-locked login session nothing is key at all.
    @MainActor
    private static func isOverTheViewer(_ event: NSEvent) -> Bool {
        belongsToTheViewer(
            modalIsUp: NSApp?.modalWindow != nil,
            window: event.window,
            isPanel: event.window is NSPanel,
            isDocument: event.window.map { KeyWindowTracker.shared.isDocument($0) } ?? false)
    }

    /// The rule above, as a pure function, so all four of its states can be
    /// driven in a test — including the two an acceptance run cannot reach.
    ///
    /// - Parameter window: `nil` for a **synthesised** event. The acceptance
    ///   harness posts those (`NSEvent(cgEvent:)` carries no window) and nothing
    ///   else in this app produces one, so they are taken as the viewer's; the
    ///   anchor then falls back to the live pointer over the document window.
    static func belongsToTheViewer(
        modalIsUp: Bool, window: AnyObject?, isPanel: Bool, isDocument: Bool
    ) -> Bool {
        guard !modalIsUp else { return false }
        guard window != nil else { return true }
        guard !isPanel else { return false }
        return isDocument
    }

    /// The pointer position in the window's content view, with a top-left origin
    /// so it can be compared against the frames SwiftUI reports in its global
    /// coordinate space.
    ///
    /// `NSEvent.locationInWindow` has a bottom-left origin in the *window*, which
    /// includes the title bar, so neither the origin nor the flip can be skipped.
    /// The flip is decided by asking the view rather than assuming: an
    /// `NSHostingView` is flipped, but nothing guarantees the content view always
    /// is one.
    ///
    /// An event that reached the monitor without a window — a synthesised one,
    /// or one delivered while no window is key — still happened somewhere, so
    /// the live pointer position stands in. Falling back to `nil` instead would
    /// silently drop the anchor and zoom on the playhead.
    @MainActor
    private static func windowPoint(for event: NSEvent) -> CGPoint? {
        // `NSApp` is nil until an `NSApplication` exists, which in a unit test
        // it does not — and touching `NSApplication.shared` there would create
        // one as a side effect of asking where the pointer is.
        guard let app = NSApp else { return nil }
        // The document window first: a synthesised event's anchor is hit-tested
        // against the *viewer's* lanes, and `keyWindow` is whichever window
        // happens to be taking keystrokes — the shortcut window, on the run that
        // opens it. `windows.first` is creation order, which is only the
        // document by luck.
        guard
            let window = event.window ?? KeyWindowTracker.shared.documentWindow ?? app.keyWindow
                ?? app.windows.first,
            let view = window.contentView
        else { return nil }
        let inWindow =
            event.window == nil
            ? window.convertPoint(fromScreen: NSEvent.mouseLocation) : event.locationInWindow
        let local = view.convert(inWindow, from: nil)
        return CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
    }
}

/// Delivers scroll-wheel and pinch events to the viewer.
///
/// SwiftUI has no gesture for a trackpad scroll on macOS, and wrapping an
/// `NSView` to catch one would have to sit in front of the lanes and swallow the
/// drag-select gesture. A *local* event monitor sees the events without joining
/// the hit-test chain, and needs no accessibility permission.
@MainActor
final class TrackpadMonitor {
    private var monitor: Any?

    func start(model: ViewerModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            // AppKit dispatches local monitors on the main thread. The `Bool`
            // crosses back out rather than the event itself, which is not
            // `Sendable` and so cannot be the result of `assumeIsolated`.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let action = TrackpadAction(event: event) else { return false }
                action.apply(to: model)
                return true
            }
            // Only an event the viewer actually claimed stops here. Everything
            // else — the shortcut window's list, the open panel's file list —
            // is handed straight back, which is what `isOverTheViewer` is for.
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension TrackpadAction {
    @MainActor
    func apply(to model: ViewerModel) {
        switch self {
        case .pan(let points):
            model.scroll(byPoints: points)
        case .zoom(let factor, let anchor):
            // The same preference the vertical drags read. One window holding
            // two zoom conventions — a drag that goes one way and a wheel that
            // goes the other — is worse than disagreeing with any other app, so
            // the switch governs both. The *defaults* still differ per device,
            // because a wheel is indirect and every application zooms in on a
            // forward roll; what the toggle promises is that both flip together.
            let applied = model.prefs.invertZoomDrag && factor > 0 ? 1 / factor : factor
            model.zoom(by: applied, at: anchor)
        }
    }
}
