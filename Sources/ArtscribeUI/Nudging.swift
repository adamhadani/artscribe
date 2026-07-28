import ArtscribeKit

/// The three navigation tiers behind `Z`/`X`, `⇧Z`/`⇧X` and `⌥Z`/`⌥X` — spec
/// §6.2's `transport.nudge` actions.
///
/// Three tiers rather than one because the three jobs are different: `⇧Z`/`⇧X`
/// walks a transient into place, `Z`/`X` steps a phrase, and `⌥Z`/`⌥X` gets you
/// across the song. The amounts are user-configurable in Settings (Task 14); the
/// bindings are not, until the real `BindingTable` lands (spec §6.3).
public enum NudgeTier: String, CaseIterable, Identifiable, Sendable {
    case fine
    case normal
    case coarse

    public var id: String { rawValue }

    /// What the tier ships as, and what Restore Defaults returns it to.
    public var defaultSeconds: Double {
        switch self {
        case .fine: return 0.05
        case .normal: return 2
        case .coarse: return 10
        }
    }

    /// The Settings row's name.
    public var label: String {
        switch self {
        case .fine: return "Fine nudge"
        case .normal: return "Nudge"
        case .coarse: return "Rewind / skip"
        }
    }

    /// The keys the row is talking about, so the field is not an unlabelled
    /// number. These are fixed in this task — only the amounts are editable.
    public var keys: String {
        switch self {
        case .fine: return "⇧Z / ⇧X"
        case .normal: return "Z / X, ← / →"
        case .coarse: return "⌥Z / ⌥X, ⌥← / ⌥→"
        }
    }

    /// Milliseconds for the fine tier, seconds for the other two: "50" beats
    /// "0.05" in a field you are typing into, and "10" beats "10.0".
    public var unit: NudgeUnit {
        self == .fine ? .milliseconds : .seconds
    }
}

/// The unit a tier is *edited* in. Everything is **stored** in seconds — one
/// internal unit, so there is exactly one place a conversion can be wrong.
public enum NudgeUnit: Sendable {
    case milliseconds
    case seconds

    public var suffix: String {
        switch self {
        case .milliseconds: return "ms"
        case .seconds: return "s"
        }
    }

    /// How many decimal places the field should offer. A millisecond is the
    /// finest amount that is allowed, so neither unit needs more than this.
    public var fractionDigits: Int {
        switch self {
        case .milliseconds: return 0
        case .seconds: return 3
        }
    }

    public func display(seconds: Double) -> Double {
        switch self {
        case .milliseconds: return seconds * 1000
        case .seconds: return seconds
        }
    }

    public func seconds(from display: Double) -> Double {
        switch self {
        case .milliseconds: return display / 1000
        case .seconds: return display
        }
    }
}

/// The three amounts, in seconds, with the validation on the way in.
///
/// Validation lives in the subscript rather than at the call sites because there
/// are three of those already — the Settings field, the defaults loader, and
/// Restore Defaults — and a nudge of 0 s does nothing at all while looking
/// perfectly healthy. That is the silent degradation the spec forbids (§8), so
/// there is no route into this type that skips the check.
public struct NudgeAmounts: Equatable, Sendable {

    /// A millisecond. Below this an amount is indistinguishable from "no
    /// movement" at any sample rate a music file uses, and zero is exactly the
    /// value that must never be storable.
    public static let minimumSeconds = 0.001
    /// Ten minutes. Longer than the reference track, and long enough that any
    /// larger value is a typo or a corrupted preference rather than an intent.
    public static let maximumSeconds = 600.0

    public static let defaults = NudgeAmounts()

    private var fine: Double
    private var normal: Double
    private var coarse: Double

    public init() {
        fine = NudgeTier.fine.defaultSeconds
        normal = NudgeTier.normal.defaultSeconds
        coarse = NudgeTier.coarse.defaultSeconds
    }

    public subscript(tier: NudgeTier) -> Double {
        get {
            switch tier {
            case .fine: return fine
            case .normal: return normal
            case .coarse: return coarse
            }
        }
        set {
            let checked = Self.validated(newValue, for: tier)
            switch tier {
            case .fine: fine = checked
            case .normal: normal = checked
            case .coarse: coarse = checked
            }
        }
    }

    /// Clamps into the allowed range; a value that is not a number at all falls
    /// back to the tier's default rather than to an arbitrary end of the range.
    public static func validated(_ seconds: Double, for tier: NudgeTier) -> Double {
        guard seconds.isFinite else { return tier.defaultSeconds }
        return Swift.min(Swift.max(seconds, minimumSeconds), maximumSeconds)
    }

    /// How an amount reads in a menu title: `50 ms`, `2 s`, `1.5 s`.
    ///
    /// The rounding happens *before* the unit is chosen, so an amount a hair
    /// under a second reads "1 s" rather than "1000 ms".
    public static func label(seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds >= 1000 else { return "\(Int(milliseconds)) ms" }
        let whole = milliseconds / 1000
        return whole == whole.rounded() ? "\(Int(whole)) s" : "\(whole) s"
    }
}

/// Which way a nudge goes. An enum rather than a signed amount so the amount
/// itself can stay unsigned everywhere it is stored and edited.
public enum NudgeDirection: Sendable {
    case backward
    case forward

    public var sign: Double {
        switch self {
        case .backward: return -1
        case .forward: return 1
        }
    }
}

/// Seconds → frames, and the clamp at both ends of the file.
///
/// Pure and separate from `ViewerModel` for the reason the project keeps
/// repeating: the interesting behaviour is at the boundaries, and a boundary is
/// far easier to test than to observe.
public enum NudgeStepping {

    /// A signed frame count. Zero — i.e. "do not move" — for any input that
    /// cannot produce a meaningful answer, which the caller turns into a no-op
    /// rather than a seek to nowhere.
    public static func frames(seconds: Double, sampleRate: Double) -> FrameIndex {
        guard seconds.isFinite, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let raw = (seconds * sampleRate).rounded()
        // `FrameIndex(_:)` traps on a `Double` outside `Int64`'s range, and a
        // corrupted preference is exactly where such a value would come from.
        guard raw > -9.2e18 else { return FrameIndex.min }
        guard raw < 9.2e18 else { return FrameIndex.max }
        return FrameIndex(raw)
    }

    /// Where a nudge lands: `playhead + seconds`, clamped to `[0, totalFrames]`.
    ///
    /// The upper bound is `totalFrames`, not the last frame, matching
    /// `ViewerModel.seek(to:)` — parking exactly on the end is what tells the
    /// next `play()` to rewind instead of restarting a finished stream.
    ///
    /// - Parameter seconds: signed; negative moves back.
    public static func target(
        from playhead: FrameIndex, bySeconds seconds: Double, sampleRate: Double,
        totalFrames: FrameIndex
    ) -> FrameIndex {
        guard totalFrames > 0 else { return 0 }
        let delta = frames(seconds: seconds, sampleRate: sampleRate)
        let moved = playhead.addingReportingOverflow(delta)
        // Saturating, not trapping: both operands can be attacker-grade values
        // arriving from storage, and the clamp below makes the saturated result
        // indistinguishable from any other out-of-range one.
        let saturated: FrameIndex = delta < 0 ? .min : .max
        let target = moved.overflow ? saturated : moved.partialValue
        return Swift.max(0, Swift.min(target, totalFrames))
    }
}
