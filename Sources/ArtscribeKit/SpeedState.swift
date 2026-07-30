/// Which time-stretching backend renders the audio.
///
/// **This is a developer setting, not a user-facing one.** It used to be half of
/// one — Playback ▸ "Use Fast Engine", `⌥E` — offering a choice between Rubber
/// Band R3 and R2. That item is gone: R2 drifts pitch by up to 26 cents at half
/// speed and 108 at the extremes, which is not a trade a transcription app
/// should invite anyone to make, and it means nothing on iOS where Rubber Band
/// cannot be linked at all. Engine selection now lives behind
/// `DeveloperMenu`, for A/B listening.
///
/// The raw values are persisted in `.artscribe` sidecars (spec §7), so **do not
/// rename existing cases**. Adding is safe: `SpeedState.init(from:)` answers
/// `.studio` for any engine name it does not recognise, so a sidecar written by
/// a newer build stays readable by an older one — it simply plays on the
/// default engine, which is the accurate one.
public enum StretchEngine: String, Sendable, Codable, CaseIterable {
    case studio  // Rubber Band R3 "Finer"
    case fast  // Rubber Band R2 "Faster"
    case signalsmith  // Signalsmith Stretch, `presetDefault`
    case signalsmithCheaper  // Signalsmith Stretch, `presetCheaper`

    /// Whether this engine needs Rubber Band, which exists on macOS only.
    ///
    /// Asked rather than pattern-matched at call sites so that "is this engine
    /// reachable on this platform" has one answer. `PlatformStretcher` is where
    /// the consequence lives.
    public var usesRubberBand: Bool {
        switch self {
        case .studio, .fast: return true
        case .signalsmith, .signalsmithCheaper: return false
        }
    }

    /// The name to show a developer picking between these.
    ///
    /// Here rather than in `ArtscribeUI` so that adding a case forces you to
    /// name it in the same edit — the alternative is a menu that silently grows
    /// an entry labelled by its raw value. Both the developer submenu and
    /// `artscribe-cli --engine` read this.
    public var displayName: String {
        switch self {
        case .studio: return "Rubber Band R3 (Studio)"
        case .fast: return "Rubber Band R2 (Fast)"
        case .signalsmith: return "Signalsmith"
        case .signalsmithCheaper: return "Signalsmith (Cheaper)"
        }
    }

    /// The name for the status bar, which has one fixed-width slot for
    /// `"100% · studio"` and no room for a sentence.
    ///
    /// A `switch`, like everything else here, and the reason is a bug this
    /// replaced: the status bar computed its label as
    /// `engine == .studio ? "studio" : "fast"`. That was true while there were
    /// exactly two engines and silently wrong the moment there were four —
    /// selecting Signalsmith displayed "fast", so the one readout that says what
    /// you are listening to was lying during the exact activity it exists for.
    public var shortName: String {
        switch self {
        case .studio: return "studio"
        case .fast: return "fast"
        case .signalsmith: return "signalsmith"
        case .signalsmithCheaper: return "signalsmith·c"
        }
    }
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
