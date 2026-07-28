import AppKit
import SwiftUI

/// **Edit ▸ the selection actions** — Select All, Clear Selection, extending it
/// and moving it.
///
/// Selection belongs in Edit by long-standing macOS convention, and `Select All`
/// is already expected there; before Task 18 it sat in View, next to the zoom
/// items, because View was where the app happened to have room.
///
/// **A `CommandGroup`, not a `CommandMenu("Edit")`.** SwiftUI already builds an
/// Edit menu for every macOS app — measured on this one: `Undo, Redo | Cut,
/// Copy, Paste, Delete, Select All | Writing Tools, AutoFill, …` — and a
/// `CommandMenu` of the same name sits *beside* it rather than merging, leaving
/// the menu bar with two. That is exactly the trap `ViewerCommands` records for
/// View.
///
/// **And the standard pasteboard group is replaced, not appended to.** Adding
/// after it was tried first and measured through the accessibility API: the
/// menu came back with *two* `Select All` items, and it was the system's —
/// disabled, since nothing in this app implements `selectAll:` — that kept ⌘A,
/// while ours was left with no key equivalent at all. A shortcut silently
/// moving to a dead item is precisely the failure this task exists to prevent,
/// so the group is replaced and its three items that are worth having are
/// re-declared below.
public struct EditCommands: Commands {
    private let model: ViewerModel

    public init(model: ViewerModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            PasteboardItems()
            Divider()
            SelectionItems(model: model)
        }
    }
}

/// Cut, Copy and Paste, sent down the responder chain by hand.
///
/// They exist for exactly one place: the numeric fields in Settings. AppKit
/// gives a text field's field editor those three chords through the *menu*, so
/// replacing the standard group without putting them back would quietly stop
/// ⌘C and ⌘V working while typing an amount.
///
/// Always enabled, unlike the system's, which validate against the first
/// responder. Nothing in this app implements them itself, so an invocation with
/// no field focused reaches no responder and does nothing — the cost is a menu
/// item that looks available in a window where it is not, which is a smaller
/// lie than a ⌘V that has stopped working.
struct PasteboardItems: View {
    var body: some View {
        Button("Cut") { send(#selector(NSText.cut(_:))) }
            .keyboardShortcut("x", modifiers: .command)
        Button("Copy") { send(#selector(NSText.copy(_:))) }
            .keyboardShortcut("c", modifiers: .command)
        Button("Paste") { send(#selector(NSText.paste(_:))) }
            .keyboardShortcut("v", modifiers: .command)
    }

    private func send(_ action: Selector) {
        NSApp?.sendAction(action, to: nil, from: nil)
    }
}

/// The selection items, in a `View` so their enablement is live.
///
/// A `Commands` body is not re-evaluated when an `@Observable` model changes —
/// the trap that silently disabled ⌘9 in Task 10 — and this group has two
/// reasons to need live enablement:
///
/// * `hasTrack`, so the items grey out with nothing loaded; and
/// * `documentIsKey`, which is not optional here. `C`, `V` and `Esc` are
///   claimed application-wide as menu key equivalents, and a key equivalent is
///   offered *before* the key window's first responder — so with Settings open,
///   typing `c` into a nudge field would move the selection instead. A disabled
///   item claims nothing, which is what hands the keystroke back to the field.
struct SelectionItems: View {
    let model: ViewerModel
    private let keyWindow = KeyWindowTracker.shared

    var body: some View {
        Group {
            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Clear Selection") { model.clearSelection() }
                .keyboardShortcut(.escape, modifiers: [])

            Divider()

            // Spec §6.2's `selection.extendLeft` / `.extendRight`. Documented
            // since the design was approved and never built until Task 18 —
            // `⇧←`/`⇧→` fell through to nothing at all.
            Button("Extend Selection Left") { model.extendSelection(.backward) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("Extend Selection Right") { model.extendSelection(.forward) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)

            Divider()

            moveItems
        }
        .disabled(!model.hasTrack || !keyWindow.documentIsKey)
    }

    /// The four `selection.move` items, with their live amounts in the titles —
    /// the convention the nudge items already follow, and the only place a
    /// Settings change is visible without pressing the key and guessing.
    @ViewBuilder
    private var moveItems: some View {
        ForEach(SelectionMoveTier.allCases) { tier in
            let seconds = model.selectionMoveAmounts[tier]
            Button(tier.menuTitle(direction: .backward, seconds: seconds)) {
                model.moveSelection(tier, direction: .backward)
            }
            .keyboardShortcut("c", modifiers: Self.modifiers(for: tier))
            Button(tier.menuTitle(direction: .forward, seconds: seconds)) {
                model.moveSelection(tier, direction: .forward)
            }
            .keyboardShortcut("v", modifiers: Self.modifiers(for: tier))
        }
    }

    /// ⌥ means "the bigger step", exactly as it already does for `⌥Z`/`⌥X` and
    /// `⌥←`/`⌥→`. Derived from the tier rather than written out twice, so a
    /// third tier cannot arrive without a modifier.
    private static func modifiers(for tier: SelectionMoveTier) -> EventModifiers {
        tier == .aggressive ? .option : []
    }
}
