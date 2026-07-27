public struct LoopRegion: Equatable, Sendable, Codable {
    public var range: FrameRange
    public var isEnabled: Bool

    public init(range: FrameRange = FrameRange(start: 0, count: 0), isEnabled: Bool = false) {
        self.range = range
        self.isEnabled = isEnabled
    }

    /// Only loop when enabled and the region is long enough to be meaningful.
    public var isActive: Bool { isEnabled && range.count > 0 }
}
