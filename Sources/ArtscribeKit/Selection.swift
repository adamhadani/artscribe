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
}
