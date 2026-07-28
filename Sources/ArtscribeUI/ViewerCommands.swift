import SwiftUI

/// Actions the menu bar and the window share, so a command has exactly one
/// implementation regardless of how it was invoked.
public enum ViewerActions {
    @MainActor
    public static func open(_ model: ViewerModel) {
        guard let url = AudioFileTypes.runOpenPanel() else { return }
        model.open(url: url)
    }
}

/// The menu bar. Every item carries a real key equivalent, right-aligned and
/// drawn by the system — including the unmodified ones, which Task 15 stopped
/// spelling into titles (`"Zoom In  (R)"`). `DocumentView` keeps its handlers
/// for the keys the menu does not claim; AppKit offers an event to the menu bar
/// first, so nothing fires twice.
///
/// Nothing here uses `.disabled(…)`. A `Commands` body is not re-evaluated when
/// an `@Observable` model changes the way a `View` body is, so a state-dependent
/// enablement goes stale: ⌘9 measurably stopped firing after a selection was
/// made because the item was still marked disabled from launch. Every action
/// below is already a guarded no-op in `ViewerModel`, so an always-enabled item
/// is both correct and honest. Greying out returns in Plan 2 with the real
/// binding table behind it.
///
/// The View menu's plain letters (`E`, `R`, `Esc`) therefore sit in a nested
/// `View` — `ViewItems` — for the one enablement that is not optional: a menu
/// key equivalent is offered before the key window's first responder, so these
/// must go quiet while another window (Settings, with its editable fields) is
/// key. See `KeyWindowTracker`.
public struct ViewerCommands: Commands {
    private let model: ViewerModel
    private let recents: RecentFiles

    public init(model: ViewerModel, recents: RecentFiles) {
        self.model = model
        self.recents = recents
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { ViewerActions.open(model) }
                .keyboardShortcut("o", modifiers: .command)
            RecentFilesMenu(model: model, recents: recents)
        }

        // Into the *standard* View menu rather than a second one of our own: a
        // `CommandMenu("View")` sits beside the menu SwiftUI already creates for
        // the window, and the menu bar ends up with two of them.
        CommandGroup(after: .toolbar) {
            Button("Fit Whole File") { model.fitWholeFile() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom to Selection") { model.zoomToSelection() }
                .keyboardShortcut("9", modifiers: .command)

            Divider()

            ViewItems(model: model)

            Divider()

            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
        }
    }
}

/// The View menu's unmodified keys, in a `View` so their enablement is live.
///
/// `⌘`-modified items stay in the `Commands` body above, always enabled: they
/// cannot collide with typing, so they need nothing from here.
struct ViewItems: View {
    let model: ViewerModel
    private let keyWindow = KeyWindowTracker.shared

    var body: some View {
        Group {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("r", modifiers: [])
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("e", modifiers: [])
            // No key equivalents: `Z`/`X` are spec §6.2's nudge keys, and a
            // nudge brings the view with it through the same page-flip rule
            // that follows playback, so moving the *view* on its own is left to
            // these items, the trackpad, and the overview strip.
            Button("Scroll Left") { model.scrollLeft() }
            Button("Scroll Right") { model.scrollRight() }
            Button("Clear Selection") { model.clearSelection() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        // Escape especially: it dismisses a sheet, cancels a field edit and
        // closes a menu, and a menu key equivalent would claim it before any of
        // those. It must only be ours while this window is the one taking keys.
        .disabled(!keyWindow.documentIsKey)
    }
}

/// **File ▸ Open Recent**, where macOS users look for it, with the "Clear Menu"
/// item the system menu has.
///
/// A nested `View` for the same reason as the theme and device menus: a
/// `Commands` body does not re-evaluate when an `@Observable` changes, so a list
/// written straight into one would still show whatever was recent at launch.
struct RecentFilesMenu: View {
    let model: ViewerModel
    let recents: RecentFiles

    var body: some View {
        Menu("Open Recent") {
            ForEach(recents.urls, id: \.self) { url in
                // The file name, not the path: the menu is for recognising a
                // track, and the full path is what the tooltip-free menu bar
                // truncates worst.
                Button(url.lastPathComponent) { model.open(url: url) }
            }
            if !recents.urls.isEmpty {
                Divider()
            }
            Button("Clear Menu") { recents.clear() }
                .disabled(recents.urls.isEmpty)
        }
    }
}

// The theme control used to live here, as `View ▸ Theme`. Task 13 parked it
// there because the app had no Settings window yet; Task 14 built one and moved
// it, which is what it was parked for. No state moved with it — it always lived
// in `ThemeController`, and `SettingsView` points a `@Bindable` at the same
// object this menu was reading.
