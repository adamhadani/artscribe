/// A half-open range of sample frames: [start, start + count).
public struct FrameRange: Equatable, Sendable, Codable {
    public var start: FrameIndex
    public var count: FrameIndex

    public init(start: FrameIndex, count: FrameIndex) {
        self.start = start
        self.count = count
    }

    public var end: FrameIndex { start + count }
    public var isEmpty: Bool { count <= 0 }

    /// Clamps into [0, total], collapsing to empty at `start` if inverted.
    public func clamped(to total: FrameIndex) -> FrameRange {
        let s = Swift.max(0, Swift.min(start, total))
        let e = Swift.max(s, Swift.min(end, total))
        return FrameRange(start: s, count: e - s)
    }

    public func contains(_ frame: FrameIndex) -> Bool {
        frame >= start && frame < end
    }
}
