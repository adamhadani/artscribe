import ArtscribeKit

/// Converts pointer positions into frame positions.
///
/// `Viewport.frame(atPixel:)` deliberately clamps only to `FrameIndex`'s
/// representable range, because a viewport does not know how long the file is
/// beyond `totalFrames` — but a *selection* must never run past the end of the
/// file, so clamping to the file happens here, once, for every gesture.
public enum PixelMapping {

    /// Frame under a pointer position, clamped into `[0, totalFrames]`.
    public static func frame(atPixel pixel: Double, in viewport: Viewport) -> FrameIndex {
        let raw = viewport.frame(atPixel: pixel)
        return Swift.max(0, Swift.min(viewport.totalFrames, raw))
    }

    /// The frame range covered by a drag between two pointer positions, in either
    /// direction. A drag that never moved produces an empty range at that frame.
    public static func range(
        fromPixel start: Double,
        toPixel end: Double,
        in viewport: Viewport
    ) -> FrameRange {
        let a = frame(atPixel: start, in: viewport)
        let b = frame(atPixel: end, in: viewport)
        let lo = Swift.min(a, b)
        let hi = Swift.max(a, b)
        return FrameRange(start: lo, count: hi - lo)
    }

    /// Horizontal position of `frame` in an overview lane that shows the whole
    /// file across `width` points. Returns 0 for a file with no frames.
    public static func overviewPixel(
        forFrame frame: FrameIndex,
        totalFrames: FrameIndex,
        width: Double
    ) -> Double {
        guard totalFrames > 0, width > 0 else { return 0 }
        let ratio = Double(Swift.max(0, Swift.min(totalFrames, frame))) / Double(totalFrames)
        return ratio * width
    }

    /// Inverse of `overviewPixel(forFrame:totalFrames:width:)`.
    public static func overviewFrame(
        atPixel pixel: Double,
        totalFrames: FrameIndex,
        width: Double
    ) -> FrameIndex {
        guard totalFrames > 0, width > 0, pixel.isFinite else { return 0 }
        let ratio = Swift.max(0, Swift.min(1, pixel / width))
        return FrameIndex((ratio * Double(totalFrames)).rounded())
    }
}
