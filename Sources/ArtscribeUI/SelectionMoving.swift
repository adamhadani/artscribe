import ArtscribeKit

/// The two step sizes for moving a **region** into place — spec §6.2's
/// `selection.move` pair and, since Task 24, its `loop.move` actions too.
///
/// Two rather than three, unlike the nudge tiers: moving a region is a
/// nudging-into-place job, so what is wanted is "a touch" and "a lot", and a
/// third size in between would only cost a chord. The amounts are
/// user-configurable in Settings; the bindings are not, until the real
/// `BindingTable` lands (spec §6.3).
///
/// **`C` / `V`, and `⌥C` / `⌥V` for the bigger step.** They sit immediately to
/// the right of `Z`/`X` — the playhead nudges — on the same bottom row, so the
/// left hand moves the playhead and the selection without leaving the cluster,
/// and ⌥ means "the bigger step" exactly as it already does for `⌥Z`/`⌥X` and
/// `⌥←`/`⌥→`. `⌘C`/`⌘V` are untouched: nothing here binds a ⌘ chord.
///
/// **The loop shares these amounts** rather than carrying a third and fourth
/// preference of its own. Nudging a region into place is one job with one pair
/// of sizes, and it is the same job whether the region is the passage you are
/// looking at or the one you are hearing. Two more Settings rows would be two
/// more numbers to keep in agreement, and a user who tuned the selection step
/// and then found the loop step ignoring it would be right to call that a bug.
/// The type keeps its name because it is what the persisted keys are built from
/// (`InteractionSettings.key(for:)`), and renaming it would orphan every
/// preference a user has already set.
public enum SelectionMoveTier: String, CaseIterable, Identifiable, Sendable {
    case gentle
    case aggressive

    public var id: String { rawValue }

    /// What the tier ships as, and what Restore Defaults returns it to.
    ///
    /// 250 ms is about a half-beat at 120 bpm and repeats smoothly under a held
    /// key; 2 s matches the normal nudge, so the big step covers the same
    /// ground as `Z`/`X` does for the playhead.
    public var defaultSeconds: Double {
        switch self {
        case .gentle: return 0.25
        case .aggressive: return 2
        }
    }

    /// The Settings row's name. It says "or loop" because the amount really does
    /// govern both, and a row named only for the selection would be a lie the
    /// moment a user pressed `⇧A`.
    public var label: String {
        switch self {
        case .gentle: return "Move selection or loop"
        case .aggressive: return "Move selection or loop (far)"
        }
    }

    /// The keys the row is talking about, so the field is not an unlabelled
    /// number. Fixed until the binding table lands — only the amounts are
    /// editable.
    public var keys: String {
        switch self {
        case .gentle: return "C / V · ⇧A ⇧S, ⇧D ⇧F, ⇧C ⇧V"
        case .aggressive: return "⌥C / ⌥V · ⌥⇧A ⌥⇧S, ⌥⇧D ⌥⇧F, ⌥⇧C ⌥⇧V"
        }
    }

    /// How the Edit menu names the two items for this tier.
    ///
    /// The amount goes in the title for the same two reasons the nudge items
    /// carry theirs: the menu is where you look to find out what a key does,
    /// and it is the only place a Settings change is visible without pressing
    /// the key and guessing.
    public func menuTitle(direction: NudgeDirection, seconds: Double) -> String {
        let way = direction == .backward ? "Left" : "Right"
        let far = self == .aggressive ? " (Far)" : ""
        return "Move Selection \(way)\(far) \(NudgeAmounts.label(seconds: seconds))"
    }
}

/// The two amounts, in seconds, with the validation on the way in.
///
/// Validation lives in the subscript for the same reason `NudgeAmounts`' does:
/// there are three ways in — the Settings field, the defaults loader and
/// Restore Defaults — and a move of 0 s does nothing at all while looking
/// perfectly healthy, which is the silent degradation spec §8 forbids.
///
/// The bounds are deliberately `NudgeAmounts`': one definition of "an amount of
/// time this app will accept", so a millisecond is the floor here too and 20 ms
/// is expressible.
public struct SelectionMoveAmounts: Equatable, Sendable {

    public static let defaults = SelectionMoveAmounts()

    private var gentle: Double
    private var aggressive: Double

    public init() {
        gentle = SelectionMoveTier.gentle.defaultSeconds
        aggressive = SelectionMoveTier.aggressive.defaultSeconds
    }

    public subscript(tier: SelectionMoveTier) -> Double {
        get {
            switch tier {
            case .gentle: return gentle
            case .aggressive: return aggressive
            }
        }
        set {
            let checked = Self.validated(newValue, for: tier)
            switch tier {
            case .gentle: gentle = checked
            case .aggressive: aggressive = checked
            }
        }
    }

    /// Clamps into the allowed range; a value that is not a number at all falls
    /// back to the tier's default rather than to an arbitrary end of the range.
    public static func validated(_ seconds: Double, for tier: SelectionMoveTier) -> Double {
        guard seconds.isFinite else { return tier.defaultSeconds }
        return Swift.min(
            Swift.max(seconds, NudgeAmounts.minimumSeconds), NudgeAmounts.maximumSeconds)
    }
}

/// Everything `InteractionSettings` persists, as one value.
///
/// A struct rather than two loose properties so the store has exactly one
/// `load` and one `save`, and so a future preference is added in one place
/// instead of three.
public struct InteractionPreferences: Equatable, Sendable {
    /// `false` — the shipped default — means a downward drag zooms in.
    public var invertZoomDrag: Bool
    public var selectionMove: SelectionMoveAmounts

    public init(
        invertZoomDrag: Bool = false, selectionMove: SelectionMoveAmounts = .defaults
    ) {
        self.invertZoomDrag = invertZoomDrag
        self.selectionMove = selectionMove
    }

    public static let defaults = InteractionPreferences()
}
