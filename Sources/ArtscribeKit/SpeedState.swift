public enum StretchEngine: String, Sendable, Codable, CaseIterable {
    case studio  // Rubber Band R3 "Finer"
    case fast  // Rubber Band R2 "Faster"
}

/// Playback speed. `ratio` is user-facing (0.5 == half speed); `timeRatio` is what
/// Rubber Band consumes and is its reciprocal. See Global Constraints.
public struct SpeedState: Equatable, Sendable, Codable {
    public static let minRatio: Double = 0.10
    public static let maxRatio: Double = 2.00

    public private(set) var ratio: Double
    public var engine: StretchEngine

    public init(ratio: Double = 1.0, engine: StretchEngine = .studio) {
        self.ratio = Self.clamp(ratio)
        self.engine = engine
    }

    private enum CodingKeys: String, CodingKey {
        case ratio
        case engine
    }

    /// Custom decoding so a hand-edited or corrupted `.artscribe` file (design
    /// spec §7 persists this type in a visible, user-editable sidecar) cannot
    /// smuggle an out-of-range or non-finite `ratio` past the clamp invariant
    /// that `init(ratio:engine:)` and `setRatio` both enforce.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRatio = try container.decode(Double.self, forKey: .ratio)
        self.ratio = Self.clamp(decodedRatio)
        self.engine = try container.decode(StretchEngine.self, forKey: .engine)
    }

    public var timeRatio: Double { 1.0 / ratio }

    public mutating func setRatio(_ newValue: Double) {
        ratio = Self.clamp(newValue)
    }

    public mutating func step(by delta: Double) {
        setRatio(ratio + delta)
    }

    private static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 1.0 }
        return Swift.min(maxRatio, Swift.max(minRatio, v))
    }
}
