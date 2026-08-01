import ArtscribeKit
import Observation

/// The working preferences: the amounts the keys move by, the preroll, and
/// which way a drag zooms.
///
/// **What makes these one group.** Every value here is a setting the user
/// chooses in Settings, is persisted to `UserDefaults`, and is *applied* to the
/// model — as opposed to track state (which arrives with a file) or view state
/// (which the user manipulates directly). They also share one lifecycle: each is
/// seeded from the shipped default and replaced once by `adopt(...)` at launch,
/// so a `ViewerModel` built by a unit test never reads what the developer last
/// typed into the real Settings window.
///
/// **A child `@Observable` class, for the reason `WaveformCache` records.**
/// Observation tracks per property access, so a view reading only
/// `invertZoomDrag` is not woken when the preroll changes; a nested *struct*
/// would route every write through the parent's `_modify` and notify even when
/// the value did not change.
///
/// The `Settings` types stay separate from this: each is the backing tape for
/// one preference, and this is the applied state. Keeping them apart is what
/// keeps `UserDefaults` out of `ViewerModel()`.
@MainActor
@Observable
public final class Preferences {

    /// How far `Z`/`X`, `⇧Z`/`⇧X` and `⌥Z`/`⌥X` move the playhead (spec §6.2's
    /// three nudge tiers). The menu titles and the nudge actions both read this,
    /// so there is one source of truth.
    public internal(set) var nudgeAmounts = NudgeAmounts.defaults

    /// How far `C`/`V` and `⌥C`/`⌥V` slide the whole selection (spec §6.2).
    public internal(set) var selectionMoveAmounts = SelectionMoveAmounts.defaults

    /// How far a `Space` resume rolls back, and whether it applies at all.
    /// `0` seconds means off permanently; `prerollEnabled` is the mode flipped
    /// while working, which is why both exist — see `Preroll`.
    public internal(set) var prerollSeconds = Preroll.defaultSeconds
    public internal(set) var prerollEnabled = true

    /// Whether pressing down in the lanes moves the playhead before the gesture
    /// has said whether it is a click or a selection. True with a pointer, false
    /// under a finger — the rule and the reasons are `LaneDragPolicy`'s.
    ///
    /// Here rather than on `ViewerModel` for the reason the rest of this type
    /// exists: it is an *applied* interaction value, seeded once at launch. It
    /// is settable so a test can drive both readings on whichever platform it
    /// happens to be running on, which is the only way the touch answer is
    /// checkable from a Mac.
    public var seeksOnSelectionPress = LaneDragPolicy.seeksOnPress(on: EmptyStatePrompt.current)

    /// Whether a vertical drag *up* zooms in. `false` — the shipped default —
    /// means down zooms in, the direction the user asked for after driving Task
    /// 16's. Governs both vertical drags and the wheel zoom, so one window never
    /// holds two zoom conventions at once.
    public internal(set) var invertZoomDrag = false

    // MARK: - Backing stores
    //
    // `@ObservationIgnored` throughout: these are plumbing installed once at
    // launch, and observing them would make every view that reads a preference
    // depend on the act of installing its store.

    @ObservationIgnored private var nudgeStore: NudgeSettings?
    @ObservationIgnored private var interactionStore: InteractionSettings?
    @ObservationIgnored private var prerollStore: PrerollSettings?

    public init() {}

    // MARK: - Adopting what was persisted
    //
    // Each `adopt` is called once, from the app shell. The stored values are
    // read *here* rather than in `init` so a `ViewerModel` built by a unit test
    // stays on the shipped defaults and never reads whatever the developer last
    // typed into the real Settings window.

    public func adopt(nudge settings: NudgeSettings) {
        nudgeStore = settings
        let loaded = settings.load()
        if loaded != nudgeAmounts { nudgeAmounts = loaded }
    }

    public func adopt(interaction settings: InteractionSettings) {
        interactionStore = settings
        let loaded = settings.load()
        if loaded.invertZoomDrag != invertZoomDrag { invertZoomDrag = loaded.invertZoomDrag }
        if loaded.selectionMove != selectionMoveAmounts {
            selectionMoveAmounts = loaded.selectionMove
        }
    }

    public func adopt(preroll settings: PrerollSettings) {
        prerollStore = settings
        let loaded = settings.load()
        if loaded != prerollSeconds { prerollSeconds = loaded }
        let enabled = settings.loadEnabled()
        if enabled != prerollEnabled { prerollEnabled = enabled }
    }

    // MARK: - Editing, from the Settings window
    //
    // Each guards on the value actually changing. Not an optimisation: writing
    // an equal value would still wake every observer, and a redundant `save` is
    // a `UserDefaults` round trip for nothing.

    /// The amount is validated by `NudgeAmounts`, so a zero, a negative or an
    /// absurd value cannot get in here (spec §8).
    public func setNudgeAmount(_ seconds: Double, for tier: NudgeTier) {
        var next = nudgeAmounts
        next[tier] = seconds
        applyNudgeAmounts(next)
    }

    /// Applies to both vertical drags — the ruler's and the lanes' ⌥-drag — and
    /// to the scroll-wheel zoom, so one window never holds two zoom conventions
    /// at once.
    public func setInvertZoomDrag(_ inverted: Bool) {
        guard inverted != invertZoomDrag else { return }
        invertZoomDrag = inverted
        saveInteraction()
    }

    /// Validated by `SelectionMoveAmounts` (spec §8), as `setNudgeAmount` is.
    public func setSelectionMoveAmount(_ seconds: Double, for tier: SelectionMoveTier) {
        var next = selectionMoveAmounts
        next[tier] = seconds
        guard next != selectionMoveAmounts else { return }
        selectionMoveAmounts = next
        saveInteraction()
    }

    /// Validated by `Preroll`, so a negative or an absurd value cannot get in —
    /// but a **zero can**, and means off (spec §8 forbids degrading silently,
    /// not choosing to).
    public func setPrerollSeconds(_ seconds: Double) {
        applyPreroll(Preroll.validated(seconds))
    }

    /// Leaves `prerollSeconds` alone, which is the whole point of having a mode
    /// as well as an amount.
    func togglePreroll() {
        prerollEnabled.toggle()
        prerollStore?.saveEnabled(prerollEnabled)
    }

    // MARK: - Restoring defaults

    /// Settings ▸ Restore Defaults. One button for the whole tab, because one
    /// per section is three ways to ask the same question — and because a user
    /// who wants "put it back as it came" should not have to find all of them.
    public func restoreDefaults() {
        restoreDefaultNudgeAmounts()
        restoreDefaultSelectionMoveAmounts()
        restoreDefaultPreroll()
        setInvertZoomDrag(false)
    }

    /// 50 ms / 2 s / 10 s.
    public func restoreDefaultNudgeAmounts() {
        applyNudgeAmounts(.defaults)
    }

    /// 250 ms / 2 s.
    public func restoreDefaultSelectionMoveAmounts() {
        guard selectionMoveAmounts != .defaults else { return }
        selectionMoveAmounts = .defaults
        saveInteraction()
    }

    /// 2 s.
    public func restoreDefaultPreroll() {
        applyPreroll(Preroll.defaultSeconds)
    }

    /// Whether anything on the Settings tab has been moved off its default,
    /// which is what the button greys out on.
    public var hasNonDefaultPreferences: Bool {
        nudgeAmounts != NudgeAmounts.defaults || selectionMoveAmounts != .defaults
            || prerollSeconds != Preroll.defaultSeconds || invertZoomDrag
    }

    // MARK: - Writing through

    private func applyNudgeAmounts(_ next: NudgeAmounts) {
        guard next != nudgeAmounts else { return }
        nudgeAmounts = next
        nudgeStore?.save(next)
    }

    private func applyPreroll(_ next: Double) {
        guard next != prerollSeconds else { return }
        prerollSeconds = next
        prerollStore?.save(next)
    }

    private func saveInteraction() {
        interactionStore?.save(
            InteractionPreferences(
                invertZoomDrag: invertZoomDrag, selectionMove: selectionMoveAmounts))
    }
}
