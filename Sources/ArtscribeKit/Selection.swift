/// A selection expressed as an anchor and a moving head, so backward drags
/// and shift-extension normalise for free.
public struct Selection: Equatable, Sendable, Codable {
    public private(set) var anchor: FrameIndex
    public private(set) var head: FrameIndex

    public init() {
        anchor = 0
        head = 0
    }

    public init(anchor: FrameIndex, head: FrameIndex) {
        self.anchor = anchor
        self.head = head
    }

    /// Derived from `anchor`/`head` rather than stored, so it can never
    /// desynchronise from the range it describes (including via `Decodable`).
    public var isEmpty: Bool { anchor == head }

    public var range: FrameRange {
        guard !isEmpty else { return FrameRange(start: anchor, count: 0) }
        let lo = Swift.min(anchor, head)
        let hi = Swift.max(anchor, head)
        return FrameRange(start: lo, count: hi - lo)
    }

    public mutating func begin(at frame: FrameIndex) {
        anchor = frame
        head = frame
    }

    public mutating func extend(to frame: FrameIndex) {
        head = frame
    }

    public mutating func clear() {
        self = Selection()
    }

    /// The same selection slid along the timeline, both edges together.
    ///
    /// The length is preserved and the anchor stays the anchor, so a selection
    /// made by dragging backwards moves the way it was made. A move that would
    /// take either edge outside the file is **clamped as a whole** rather than
    /// applied to one edge: pushed against an end, the selection stops there
    /// with its length intact instead of shrinking against the wall or
    /// inverting past it. That is the entire reason this lives here and is
    /// tested at both boundaries — the interesting behaviour is all at the ends.
    ///
    /// - Parameters:
    ///   - delta: signed frames; negative moves earlier. Any magnitude is
    ///     accepted, including `FrameIndex.min`, because the amount it is
    ///     derived from comes from a user-editable preference.
    ///   - totalFrames: the file length. The upper bound is inclusive, matching
    ///     `ViewerModel.seek(to:)`: a selection may end exactly at the last
    ///     frame boundary.
    public func translated(by delta: FrameIndex, within totalFrames: FrameIndex) -> Selection {
        guard !isEmpty else { return self }
        let lo = Swift.min(anchor, head)
        let hi = Swift.max(anchor, head)
        // How far it may move before an edge leaves the file. Computed as the
        // permitted *range of deltas* rather than by moving and then clamping,
        // because clamping the edges independently is exactly what would let a
        // selection shrink or invert at a boundary.
        let earliest = -lo
        let latest = totalFrames - hi
        // No legal position at all — a selection longer than the file, which
        // nothing in the app can produce but a decoded sidecar could. Leaving
        // it alone beats moving it somewhere arbitrary.
        guard latest >= earliest else { return self }
        let bounded = Swift.min(Swift.max(delta, earliest), latest)
        // Safe without overflow checks: `bounded` is inside `[-lo, totalFrames - hi]`,
        // so both sums are inside `[0, totalFrames]` by construction.
        return Selection(anchor: anchor + bounded, head: head + bounded)
    }
}
