/// A half-open range of sample frames: [start, start + count).
public struct FrameRange: Equatable, Sendable, Codable {
    public var start: FrameIndex
    public var count: FrameIndex

    public init(start: FrameIndex, count: FrameIndex) {
        self.start = start
        self.count = count
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case count
    }

    /// Validating, for the same reason `SpeedState` and `VolumeState` are: this
    /// type is persisted inside the visible, user-editable `.artscripture` sidecar
    /// (spec §7), and a hand-edited negative `count` would make `end` precede
    /// `start` — a range that `contains` nothing, reports a positive length to
    /// nobody, and is handed to the render thread as a loop.
    ///
    /// Both fields are floored at zero rather than the pair being rejected: a
    /// negative start is a typo, and a range collapsed to empty at the file's
    /// beginning is a state the whole app already handles.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = Swift.max(0, try container.decode(FrameIndex.self, forKey: .start))
        count = Swift.max(0, try container.decode(FrameIndex.self, forKey: .count))
    }

    /// Saturating, not trapping.
    ///
    /// Every other producer of a `FrameRange` in this app keeps `start + count`
    /// inside the file, but a decoded sidecar does not have to: `{"start":
    /// 9223372036854775807, "count": 9223372036854775807}` is three seconds of
    /// typing, and a plain `start + count` would trap on it — a crash reachable
    /// by editing a text file next to your music. Saturating gives
    /// `clamped(to:)` something to work with instead.
    public var end: FrameIndex {
        let (sum, overflowed) = start.addingReportingOverflow(count)
        guard overflowed else { return sum }
        return count > 0 ? FrameIndex.max : FrameIndex.min
    }

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
