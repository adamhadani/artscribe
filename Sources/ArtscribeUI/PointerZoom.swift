import CoreGraphics

/// Which lane a pointer-anchored zoom applies to, and where inside it.
///
/// The `x` is local to that lane, in points, because that is what the two
/// mappings back to a frame take: the lanes read through the viewport, the
/// overview through the whole file.
enum ZoomTarget: Equatable, Sendable {
    case lanes(x: Double)
    case overview(x: Double)
}

/// The pure decision behind pointer-anchored zoom: given where the pointer is
/// and where the two lanes were laid out, which one is under it.
///
/// Kept out of the views so it can be tested without one, and out of
/// `TrackpadMonitor` so the same rule serves a pinch, a wheel and a
/// `⌘`-modified swipe.
enum PointerZoom {

    /// - Parameters:
    ///   - point: pointer position in the window's content coordinates,
    ///     top-left origin — the space SwiftUI's `.global` reports frames in.
    ///   - lanes: the waveform lane's frame in that same space.
    ///   - overview: the overview strip's frame in that same space.
    /// - Returns: `nil` when the pointer is over neither, including before the
    ///   first layout pass, when both frames are still empty. The caller then
    ///   falls back to the playhead rather than anchoring at frame 0.
    static func target(at point: CGPoint, lanes: CGRect, overview: CGRect) -> ZoomTarget? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        if !overview.isEmpty, overview.contains(point) {
            return .overview(x: point.x - overview.minX)
        }
        if !lanes.isEmpty, lanes.contains(point) {
            return .lanes(x: point.x - lanes.minX)
        }
        return nil
    }
}
