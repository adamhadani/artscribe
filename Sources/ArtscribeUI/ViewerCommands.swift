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

/// The menu bar. ⌘-shortcuts live here because menu key equivalents work even
/// when nothing in the window has focus; the unmodified left-hand cluster is
/// handled by `DocumentView` and only *listed* here, so it stays discoverable
/// without the menu swallowing plain letter keys.
///
/// Nothing here uses `.disabled(…)`. A `Commands` body is not re-evaluated when
/// an `@Observable` model changes the way a `View` body is, so a state-dependent
/// enablement goes stale: ⌘9 measurably stopped firing after a selection was
/// made because the item was still marked disabled from launch. Every action
/// below is already a guarded no-op in `ViewerModel`, so an always-enabled item
/// is both correct and honest. Greying out returns in Plan 2 with the real
/// binding table behind it.
public struct ViewerCommands: Commands {
    private let model: ViewerModel
    private let theme: ThemeController
    private let recents: RecentFiles

    public init(model: ViewerModel, theme: ThemeController, recents: RecentFiles) {
        self.model = model
        self.theme = theme
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

            Button("Zoom In  (R)") { model.zoomIn() }
            Button("Zoom Out  (E)") { model.zoomOut() }
            Button("Scroll Left  (Z)") { model.scrollLeft() }
            Button("Scroll Right  (X)") { model.scrollRight() }

            Divider()

            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Clear Selection  (Esc)") { model.clearSelection() }

            Divider()

            ThemeMenu(theme: theme)
        }
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

/// Light / Dark / System.
///
/// In the **View** menu rather than in Settings, for now: it changes how this
/// window looks, which is what the View menu is for, and the app has no Settings
/// scene yet. When one arrives (Task 14) the control moves by pointing a
/// `@Bindable` at the same `ThemeController` and deleting this — no state moves
/// with it, because none of it lives here.
///
/// A nested `View`, not items written straight into the `Commands` body, for the
/// reason `PlaybackCommands` documents at length: a `Commands` body is not
/// re-evaluated when an `@Observable` changes, so the checkmarks would go stale.
struct ThemeMenu: View {
    let theme: ThemeController

    var body: some View {
        Menu("Theme") {
            ForEach(ThemePreference.allCases) { option in
                // Radio behaviour, as in the output-device menu: turning an item
                // on selects it, and turning the current one off would leave
                // nothing selected, so it is ignored.
                Toggle(
                    option.label,
                    isOn: Binding(
                        get: { theme.preference == option },
                        set: { isOn in if isOn { theme.preference = option } }))
            }
        }
    }
}
