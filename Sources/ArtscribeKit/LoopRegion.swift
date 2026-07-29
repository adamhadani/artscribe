public struct LoopRegion: Equatable, Sendable, Codable {
    public var range: FrameRange
    public var isEnabled: Bool

    public init(range: FrameRange = FrameRange(start: 0, count: 0), isEnabled: Bool = false) {
        self.range = range
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case range
        case isEnabled
    }

    /// `range` is required; `isEnabled` is not.
    ///
    /// The asymmetry is the point. A sidecar with no loop range has nothing to
    /// say about looping and is reported as a missing field, but one that
    /// records a range and omits the flag is readable — off is the safe reading,
    /// because a loop that silently engages changes what the user hears the
    /// moment they press play. `FrameRange`'s own validating decoder does the
    /// rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        range = try container.decode(FrameRange.self, forKey: .range)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    }

    /// Only loop when enabled and the region is long enough to be meaningful.
    public var isActive: Bool { isEnabled && range.count > 0 }
}
