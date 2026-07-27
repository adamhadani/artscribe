/// The visible window over the timeline, shared by every lane.
///
/// Zoom always anchors on a caller-supplied frame (normally the playhead) so the
/// anchor stays under the same pixel — see spec §6.1.
public struct Viewport: Equatable, Sendable {
    /// Most zoomed-in state: 100 pixels per frame.
    public static let minFramesPerPixel: Double = 0.01

    public let totalFrames: FrameIndex
    public private(set) var widthPixels: Int
    public private(set) var startFrame: FrameIndex
    public private(set) var framesPerPixel: Double

    public init(totalFrames: FrameIndex, widthPixels: Int) {
        self.totalFrames = Swift.max(0, totalFrames)
        self.widthPixels = Swift.max(1, widthPixels)
        self.startFrame = 0
        self.framesPerPixel = 1
        fit()
    }

    /// Coarsest useful zoom: the whole file exactly fills the width.
    public var maxFramesPerPixel: Double {
        Swift.max(Self.minFramesPerPixel, Double(totalFrames) / Double(widthPixels))
    }

    /// Never exceeds `totalFrames`: a file shorter than the minimum-zoom width in
    /// frames (including an empty file) cannot show more frames than exist.
    public var visibleFrames: FrameIndex {
        let raw = FrameIndex((Double(widthPixels) * framesPerPixel).rounded())
        return Swift.min(raw, totalFrames)
    }

    public var endFrame: FrameIndex { startFrame + visibleFrames }

    public mutating func resize(widthPixels: Int) {
        self.widthPixels = Swift.max(1, widthPixels)
        clamp()
    }

    public mutating func fit() {
        framesPerPixel = maxFramesPerPixel
        startFrame = 0
    }

    /// `factor > 1` zooms in. `anchorFrame` stays under the same pixel.
    public mutating func zoom(by factor: Double, anchorFrame: FrameIndex) {
        guard factor > 0, factor.isFinite else { return }
        let anchorPixel = pixel(forFrame: anchorFrame)
        let target = framesPerPixel / factor
        framesPerPixel = Swift.min(
            maxFramesPerPixel,
            Swift.max(Self.minFramesPerPixel, target))
        let newStart = Double(anchorFrame) - anchorPixel * framesPerPixel
        startFrame = Self.clampedFrameIndex(newStart)
        clamp()
    }

    public mutating func zoom(to range: FrameRange) {
        let r = range.clamped(to: totalFrames)
        guard !r.isEmpty else { return }
        framesPerPixel = Swift.min(
            maxFramesPerPixel,
            Swift.max(
                Self.minFramesPerPixel,
                Double(r.count) / Double(widthPixels)))
        startFrame = r.start
        clamp()
    }

    public mutating func scroll(byPixels pixels: Int) {
        let newStart = Double(startFrame) + Double(pixels) * framesPerPixel
        startFrame = Self.clampedFrameIndex(newStart)
        clamp()
    }

    public func pixel(forFrame frame: FrameIndex) -> Double {
        Double(frame - startFrame) / framesPerPixel
    }

    public func frame(atPixel pixel: Double) -> FrameIndex {
        Self.clampedFrameIndex(Double(startFrame) + pixel * framesPerPixel)
    }

    private mutating func clamp() {
        framesPerPixel = Swift.max(
            Self.minFramesPerPixel, Swift.min(framesPerPixel, maxFramesPerPixel))
        let maxStart = Swift.max(0, totalFrames - visibleFrames)
        startFrame = Swift.max(0, Swift.min(startFrame, maxStart))
    }

    /// Converts a `Double` to `FrameIndex`, clamping into `FrameIndex`'s representable
    /// range instead of trapping. Callers may combine extreme user input (e.g. an
    /// absurd scroll delta or pixel coordinate) with the current zoom level, producing
    /// a `Double` outside `Int64`'s range.
    private static func clampedFrameIndex(_ value: Double) -> FrameIndex {
        guard value.isFinite else {
            return value > 0 ? FrameIndex.max : FrameIndex.min
        }
        if value >= Double(FrameIndex.max) { return FrameIndex.max }
        if value <= Double(FrameIndex.min) { return FrameIndex.min }
        return FrameIndex(value.rounded())
    }
}
