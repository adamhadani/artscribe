import SwiftUI

/// The **Loop** menu — the app's signature feature, given its own place in the
/// menu bar.
///
/// It was the last block of a 36-item Playback menu, which is where a feature
/// goes to be undiscoverable: looping a passage is the reason this app exists,
/// and `A`/`S`/`D`/`F`/`G` are the five keys a new user most needs to find. It
/// is also where the Practice hub (speed-ramping repetitions) lands later, so
/// the menu has somewhere to grow that is not "the bottom of Playback".
///
/// A `CommandMenu`, unlike `EditCommands`: macOS builds no Loop menu of its
/// own, so there is nothing to merge with and nothing to duplicate.
public struct LoopCommands: Commands {
    private let model: ViewerModel

    public init(model: ViewerModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandMenu("Loop") {
            LoopItems(model: model)
        }
    }
}

/// The loop items, in a `View` for the two reasons `PlaybackMenu` records: a
/// `Commands` body does not re-evaluate when an `@Observable` changes, so both
/// the `Loop` checkmark and every `.disabled(…)` here would go stale in one;
/// and the plain letters must stand down while another window holds the
/// keyboard, or `A` typed into Settings sets a loop point.
struct LoopItems: View {
    let model: ViewerModel
    private let keyWindow = KeyWindowTracker.shared

    var body: some View {
        Group {
            coreItems

            Divider()

            moveItems(for: .inPoint, backward: "a", forward: "s")

            Divider()

            moveItems(for: .outPoint, backward: "d", forward: "f")

            Divider()

            moveItems(for: .whole, backward: "c", forward: "v")
        }
        .disabled(!model.hasTrack || !keyWindow.documentIsKey)
    }

    @ViewBuilder
    private var coreItems: some View {
        Button("Set Loop In") { model.setLoopIn() }
            .keyboardShortcut("a", modifiers: [])
        Button("Set Loop Out") { model.setLoopOut() }
            .keyboardShortcut("s", modifiers: [])
        Toggle(
            "Loop",
            isOn: Binding(
                get: { model.loop.isEnabled },
                // Compared rather than blindly toggled: a `Binding` set to
                // the value it already holds must be a no-op, or the item
                // inverts the state it was asked to confirm.
                set: { isOn in if isOn != model.loop.isEnabled { model.toggleLoop() } })
        )
        .keyboardShortcut("d", modifiers: [])
        .disabled(model.loop.range.isEmpty && !model.loop.isEnabled)
        Button("Restart Loop") { model.restartLoop() }
            .keyboardShortcut("f", modifiers: [])
            .disabled(model.loop.range.isEmpty)

        Divider()

        Button("Selection → Loop") { model.loopFromSelection() }
            .keyboardShortcut("g", modifiers: [])
            .disabled(model.selection.isEmpty)
        Button("Clear Loop") { model.clearLoop() }
            .disabled(model.loop.range.isEmpty)
    }

    /// The four items for one move target — spec §6.2's `loop.move` actions —
    /// with their live amounts in the titles, the convention the nudge and
    /// selection-move items already follow.
    ///
    /// **The keys.** `A S D F` is the loop row and already reads left to right:
    /// the *left* pair drives the loop's *left* (in) edge and the *right* pair
    /// its *right* (out) edge, and within each pair the left key moves left. `⇧`
    /// is what turns "set this edge at the playhead" into "nudge it from where it
    /// is". `⇧C`/`⇧V` then move the whole loop, on the very keys that already
    /// move the whole selection — the keyboard equivalent of the loop body Task
    /// 23 made draggable, and of the selection body it deliberately did not.
    ///
    /// `⌥` still means "the bigger step", exactly as it does for `⌥Z`/`⌥X`,
    /// `⌥←`/`⌥→` and `⌥C`/`⌥V`, so it *adds* to the chord rather than replacing
    /// the `⇧`.
    ///
    /// These are declared here for the menu's sake — the right-aligned,
    /// system-drawn shortcut is how a user finds them — but `NSMenu` matches a
    /// key equivalent against a **lowercase** `charactersIgnoringModifiers`, so a
    /// `⇧A` arriving as "A" is not claimed by the menu at all. `DocumentView`
    /// handles every one of them for that reason, exactly as it already does for
    /// `⇧Z`/`⇧X` and `⇧Q`/`⇧W`.
    @ViewBuilder
    private func moveItems(
        for target: LoopMoveTarget, backward: KeyEquivalent, forward: KeyEquivalent
    ) -> some View {
        ForEach(SelectionMoveTier.allCases) { tier in
            let seconds = model.selectionMoveAmounts[tier]
            Button(target.menuTitle(direction: .backward, tier: tier, seconds: seconds)) {
                model.moveLoop(target, tier, direction: .backward)
            }
            .keyboardShortcut(backward, modifiers: Self.modifiers(for: tier))
            Button(target.menuTitle(direction: .forward, tier: tier, seconds: seconds)) {
                model.moveLoop(target, tier, direction: .forward)
            }
            .keyboardShortcut(forward, modifiers: Self.modifiers(for: tier))
        }
        .disabled(model.loop.range.isEmpty)
    }

    /// Derived from the tier rather than written out six times, so a third tier
    /// cannot arrive without a modifier.
    private static func modifiers(for tier: SelectionMoveTier) -> EventModifiers {
        tier == .aggressive ? [.shift, .option] : .shift
    }
}
