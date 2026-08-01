/// Output level and mute.
///
/// Lives beside `SpeedState` because it is the same kind of thing: a small
/// clamped value that the UI edits, the audio graph consumes, and session
/// persistence (spec §7) will eventually write to the sidecar.
///
/// **Taper: linear in amplitude.** `level` *is* the mixer gain, so 50% means
/// half of full scale and the readout, the slider position and
/// `AVAudioEngine.mainMixerNode.outputVolume` all agree on one number. A dB or
/// power taper spreads the useful range better across a slider, but it makes
/// "50%" mean −12 dB or −18 dB depending on the exponent chosen, which
/// contradicts the requirement this type was written for and makes the readout
/// something you have to interpret rather than read. Loudness is judged by ear
/// against the material anyway, and there is a fine step for the last 1%.
public struct VolumeState: Equatable, Sendable, Codable {
    public static let minLevel: Double = 0.0
    public static let maxLevel: Double = 1.0
    /// Half scale. A transcription tool that opens at full scale and plays into
    /// headphones is hostile, so the default is deliberately not 1.0.
    public static let defaultLevel: Double = 0.5

    /// `↑` / `↓`, in points of full scale.
    public static let coarseStep: Double = 0.05
    /// `⇧↑` / `⇧↓`.
    public static let fineStep: Double = 0.01

    /// The grid every reachable level sits on, and the resolution the readout
    /// shows. Finer than `fineStep`, so quantising can never move a level the
    /// user deliberately set.
    private static let grid = 1000.0

    /// What the slider shows. Unaffected by mute, so muting does not make the
    /// control jump to the bottom and lose your place.
    public private(set) var level: Double
    public private(set) var isMuted: Bool
    /// The level at the moment of muting, so unmuting restores what you had
    /// rather than jumping to full scale.
    private var levelBeforeMute: Double

    public init(level: Double = defaultLevel) {
        let clamped = Self.clamp(level)
        self.level = clamped
        self.isMuted = false
        self.levelBeforeMute = clamped
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case isMuted
        case levelBeforeMute
    }

    /// Custom decoding for the same reason `SpeedState` has one: a hand-edited or
    /// corrupted `.artscripture` sidecar must not be able to smuggle an
    /// out-of-range or non-finite level past the clamp that every other path
    /// enforces — here that would mean handing `outputVolume` a NaN.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = Self.clamp(try container.decode(Double.self, forKey: .level))
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        levelBeforeMute = Self.clamp(try container.decode(Double.self, forKey: .levelBeforeMute))
    }

    /// What the mixer is set to. The only place mute has an effect.
    public var amplitude: Double { isMuted ? 0 : level }

    /// Dragging the slider unmutes: adjusting a control you cannot hear and
    /// having nothing happen is the kind of dead-end this project keeps out.
    public mutating func setLevel(_ newValue: Double) {
        level = Self.clamp(newValue)
        isMuted = false
        levelBeforeMute = level
    }

    /// Also unmutes, matching every hardware and OS volume control: pressing
    /// volume-up while muted makes sound.
    public mutating func step(by delta: Double) {
        setLevel(Self.quantise(level + delta))
    }

    /// Muting at silence and unmuting again gives back silence — it restores what
    /// was there, and what was there was nothing.
    public mutating func toggleMute() {
        if isMuted {
            level = levelBeforeMute
            isMuted = false
        } else {
            levelBeforeMute = level
            isMuted = true
        }
    }

    private static func quantise(_ value: Double) -> Double {
        guard value.isFinite else { return defaultLevel }
        return (value * grid).rounded() / grid
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultLevel }
        return Swift.min(maxLevel, Swift.max(minLevel, value))
    }
}
