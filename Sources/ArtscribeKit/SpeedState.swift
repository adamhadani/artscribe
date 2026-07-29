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
    ///
    /// `ratio` is required and `engine` is not, for the same reason
    /// `LoopRegion` treats its two fields differently: a payload with no ratio
    /// says nothing about speed and is reported as missing, whereas a misspelt
    /// or absent engine name has an obviously right answer — Studio, the
    /// default, which is the accurate one. Falling back to it costs CPU;
    /// throwing the whole payload away would cost the user their loop points.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRatio = try container.decode(Double.self, forKey: .ratio)
        self.ratio = Self.clamp(decodedRatio)
        self.engine =
            (try? container.decodeIfPresent(StretchEngine.self, forKey: .engine)) ?? .studio
    }

    public var timeRatio: Double { 1.0 / ratio }

    public mutating func setRatio(_ newValue: Double) {
        ratio = Self.clamp(newValue)
    }

    public mutating func step(by delta: Double) {
        setRatio(ratio + delta)
    }

    /// The range invariant, reachable from outside.
    ///
    /// Public so `RampSchedule` can enforce *this* type's bounds rather than
    /// restating 0.10 and 2.00 a second time: the practice ramp's endpoints are
    /// speeds, and a ramp that could be built out of speeds the transport cannot
    /// hold would be a second definition of the range waiting to drift from this
    /// one. A non-finite value answers 1.0, exactly as it does on the way in
    /// through `init` and `setRatio`.
    public static func clamped(_ ratio: Double) -> Double { clamp(ratio) }

    private static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 1.0 }
        return Swift.min(maxRatio, Swift.max(minRatio, v))
    }
}
