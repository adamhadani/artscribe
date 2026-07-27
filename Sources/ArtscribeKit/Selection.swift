/// A selection expressed as an anchor and a moving head, so backward drags
/// and shift-extension normalise for free.
public struct Selection: Equatable, Sendable, Codable {
    public private(set) var anchor: FrameIndex
    public private(set) var head: FrameIndex
    public private(set) var isEmpty: Bool

    public init() {
        anchor = 0
        head = 0
        isEmpty = true
    }

    public init(anchor: FrameIndex, head: FrameIndex) {
        self.anchor = anchor
        self.head = head
        self.isEmpty = anchor == head
    }

    public var range: FrameRange {
        guard !isEmpty else { return FrameRange(start: anchor, count: 0) }
        let lo = Swift.min(anchor, head)
        let hi = Swift.max(anchor, head)
        return FrameRange(start: lo, count: hi - lo)
    }

    public mutating func begin(at frame: FrameIndex) {
        anchor = frame
        head = frame
        isEmpty = true
    }

    public mutating func extend(to frame: FrameIndex) {
        head = frame
        isEmpty = (frame == anchor)
    }

    public mutating func clear() {
        self = Selection()
    }
}
