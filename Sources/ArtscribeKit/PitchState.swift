/// Transposition, independent of speed.
///
/// The two are separate controls on purpose. Slowing a passage down to learn it
/// must not move it off the instrument's pitch, and transposing a horn part into
/// a guitar-friendly key must not change its tempo. Rubber Band models them as
/// two independent ratios — `timeRatio` and `pitchScale` — so keeping them apart
/// here costs nothing and conflating them would be a lie about the engine.
///
/// Stored in **cents**, one hundredth of a semitone, because that is the finest
/// unit anybody adjusts by and it makes the semitone case exact: 3 semitones is
/// 300, not 2.9999999. A `Double` of semitones would accumulate error across
/// repeated key presses in a way an integer cannot.
public struct PitchState: Equatable, Sendable, Codable {

    /// ±12 semitones. Beyond an octave a phase vocoder stops sounding like the
    /// instrument and starts sounding like an effect, which is not what a
    /// transcription tool is for. It is also the range every comparable app
    /// offers, so it is what a user expects to find.
    public static let minCents = -1200
    public static let maxCents = 1200

    /// One semitone, in cents. Named rather than spelled `100` at each use so
    /// the arithmetic below reads as music rather than as arbitrary constants.
    public static let centsPerSemitone = 100

    public private(set) var cents: Int

    public init(cents: Int = 0) {
        self.cents = Self.clamp(cents)
    }

    /// Whole semitones, rounded toward zero, and the leftover cents.
    ///
    /// For display only — `-3` semitones and `-50` cents reads as "−3 semitones,
    /// −50 cents", which is how a musician says it. The stored value stays the
    /// single source of truth.
    public var semitones: Int { cents / Self.centsPerSemitone }
    public var centsRemainder: Int { cents % Self.centsPerSemitone }

    /// Whether anything is transposed. What the UI emphasises on, the same way
    /// an altered speed is emphasised.
    public var isAltered: Bool { cents != 0 }

    /// The multiplier Rubber Band wants: an equal-tempered ratio, `2^(cents/1200)`.
    ///
    /// A pitch *scale*, not a time ratio, and it is deliberately **not** the
    /// reciprocal of anything — unlike `SpeedState`, where the user-facing ratio
    /// and the engine's `timeRatio` are inverses of each other and mixing them
    /// up is the easiest audible bug in the project. Here up is up: +1200 cents
    /// gives 2.0, an octave higher.
    public var scale: Double {
        cents == 0 ? 1.0 : exp2(Double(cents) / Double(Self.maxCents))
    }

    public mutating func setCents(_ value: Int) {
        cents = Self.clamp(value)
    }

    /// Moves by `delta` cents and reports whether it actually moved, so a caller
    /// at the end of the range does not push a redundant command at the render
    /// thread on every key repeat.
    @discardableResult
    public mutating func adjust(byCents delta: Int) -> Bool {
        let next = Self.clamp(cents + delta)
        guard next != cents else { return false }
        cents = next
        return true
    }

    public mutating func reset() {
        cents = 0
    }

    static func clamp(_ value: Int) -> Int {
        Swift.max(minCents, Swift.min(maxCents, value))
    }

    private enum CodingKeys: String, CodingKey {
        case cents
    }

    /// Clamped on the way in, for the reason `SpeedState` records: the sidecar
    /// is a visible, hand-editable file (spec §7), so a decoder that trusted its
    /// input could smuggle a value past the invariant that every other path
    /// enforces. A missing `cents` means "not transposed", which is the honest
    /// reading of a file that says nothing about pitch — unlike a missing
    /// speed, which `SpeedState` treats as a damaged payload because a session
    /// that recorded no speed at all is malformed rather than merely quiet.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cents = Self.clamp(try container.decodeIfPresent(Int.self, forKey: .cents) ?? 0)
    }
}

/// `exp2` without importing Foundation — `ArtscribeKit` imports nothing.
///
/// The Swift standard library has no free `exp2`, so this is the identity
/// `2^x == e^(x ln 2)` expressed with the builtins that are available. Accurate
/// to well under a cent across the ±1200 range, which is far finer than the ear
/// resolves and finer than the control can express.
func exp2(_ value: Double) -> Double {
    var result = 1.0
    var term = 1.0
    let scaled = value * 0.693_147_180_559_945_309_4  // ln 2
    // Maclaurin series for e^x. Twenty terms is comfortably convergent for
    // |x| <= ln 2, the widest this is ever called with.
    for index in 1...20 {
        term *= scaled / Double(index)
        result += term
    }
    return result
}
