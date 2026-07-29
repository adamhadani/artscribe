import SwiftUI

/// **Edit** — the pasteboard chords, and the selection actions.
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
/// re-declared in `MenuPlan.edit`.
public struct EditCommands: Commands {
    private let context: MenuContext

    public init(context: MenuContext) {
        self.context = context
    }

    public var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            MenuItems(section: .edit, context: context)
        }
    }
}
