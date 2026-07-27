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
        at anchor: CGPoint?
    ) {
        guard scrollingDeltaX.isFinite, scrollingDeltaY.isFinite else { return nil }
        let zooms = commandHeld || (!hasPreciseScrollingDeltas && !shiftHeld)
        // Zoom is a vertical gesture. A tilt wheel or a shift-swapped axis
        // reports horizontally, and that stays a pan.
        if zooms, scrollingDeltaY != 0 {
            guard
                let factor = Self.zoomFactor(
                    deltaY: scrollingDeltaY, precise: hasPreciseScrollingDeltas)
            else { return nil }
            self = .zoom(factor: factor, anchor: anchor)
            return
        }
        let delta = scrollingDeltaX != 0 ? scrollingDeltaX : -scrollingDeltaY
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
        let anchor = Self.windowPoint(for: event)
        switch event.type {
        case .scrollWheel:
            self.init(
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                commandHeld: event.modifierFlags.contains(.command),
                shiftHeld: event.modifierFlags.contains(.shift),
                at: anchor)
        case .magnify:
            self.init(magnification: event.magnification, at: anchor)
        default:
            return nil
        }
    }

    /// A positive delta means the content scrolled up, which zooms in.
    private static func zoomFactor(deltaY: Double, precise: Bool) -> Double? {
        let factor: Double
        if precise {
            let points = Swift.max(-maxPrecisePoints, Swift.min(maxPrecisePoints, deltaY))
            factor = pow(2, points / pointsPerDoubling)
        } else {
            let lines = Swift.max(-maxWheelLines, Swift.min(maxWheelLines, deltaY))
            factor = pow(wheelZoomPerLine, lines)
        }
        guard factor > 0, factor.isFinite else { return nil }
        return factor
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
        guard let window = event.window ?? app.keyWindow ?? app.windows.first,
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
            // Nothing else in this window scrolls, so a handled event stops here.
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
        case .pan(let points): model.scroll(byPoints: points)
        case .zoom(let factor, let anchor): model.zoom(by: factor, at: anchor)
        }
    }
}
