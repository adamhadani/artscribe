import AppKit

/// What a trackpad event means to the viewer. Extracted from the `NSEvent` on
/// the spot so only plain numbers cross into main-actor code — `NSEvent` itself
/// is not `Sendable`.
enum TrackpadAction: Equatable, Sendable {
    case pan(points: Int)
    case zoom(factor: Double)

    /// Pinch deltas arrive in small increments; this turns a full `+1.0`
    /// magnification into a doubling of zoom.
    static let pinchGain = 2.0

    /// A trackpad or wheel scroll. Shift-scroll and a plain mouse wheel report
    /// only a vertical delta, so that is treated as horizontal travel too.
    init?(scrollingDeltaX: Double, scrollingDeltaY: Double) {
        let delta = scrollingDeltaX != 0 ? scrollingDeltaX : -scrollingDeltaY
        guard delta.isFinite else { return nil }
        let points = Int(delta.rounded())
        guard points != 0 else { return nil }
        self = .pan(points: -points)
    }

    init?(magnification: Double) {
        let factor = 1 + magnification * Self.pinchGain
        guard factor > 0, factor.isFinite else { return nil }
        self = .zoom(factor: factor)
    }

    init?(event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            self.init(
                scrollingDeltaX: event.scrollingDeltaX, scrollingDeltaY: event.scrollingDeltaY)
        case .magnify:
            self.init(magnification: event.magnification)
        default:
            return nil
        }
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
            guard let action = TrackpadAction(event: event) else { return event }
            // AppKit dispatches local monitors on the main thread.
            MainActor.assumeIsolated { action.apply(to: model) }
            // Nothing else in this window scrolls, so the event stops here.
            return nil
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
        case .zoom(let factor): model.zoom(by: factor)
        }
    }
}
