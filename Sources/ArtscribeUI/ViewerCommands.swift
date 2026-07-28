import SwiftUI

/// Actions the menu bar and the window share, so a command has exactly one
/// implementation regardless of how it was invoked.
public enum ViewerActions {
    @MainActor
    public static func open(_ model: ViewerModel) {
        guard let url = AudioFileTypes.runOpenPanel() else { return }
        open(model, url: url)
    }

    /// The one way into `ViewerModel.open(url:)` from the UI.
    ///
    /// Artscribe is a one-window, one-track app, so loading another file is the
    /// only other way to walk away from a session — and it has to ask the same
    /// question closing the window does, or a loop you set two minutes ago
    /// disappears because you reached for Open Recent. Every route in goes
    /// through here: the Open panel, Open Recent, a drop on the window, and a
    /// file handed over by Launch Services.
    @MainActor
    public static func open(_ model: ViewerModel, url: URL) {
        SessionPrompt.whenSafeToLeave(model) { proceed in
            guard proceed else { return }
            model.open(url: url)
        }
    }

    /// **File ▸ Save As…** — the panel, then the write. The decision about what
    /// saving somewhere other than the canonical sidecar *means* is
    /// `ViewerModel.saveSession(to:)`'s, and is tested there.
    @MainActor
    public static func saveAs(_ model: ViewerModel) {
        guard let suggestion = model.suggestedSessionSaveURL, model.canSaveSession else { return }
        guard let url = SessionPanels.runSavePanel(suggesting: suggestion) else { return }
        model.saveSession(to: url)
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
/// The View menu's plain letters (`E`, `R`) therefore sit in a nested
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

        // Session persistence (spec §7) in the place every Mac user looks for
        // it. `.saveItem` is the standard group, so these land under Open Recent
        // with the separator the system draws, and ⌘S / ⇧⌘S are the system's own
        // shortcuts rather than ones invented here.
        //
        // Always enabled, for the reason recorded above: a `Commands` body does
        // not re-evaluate when the model changes, so a state-dependent
        // `.disabled` goes stale and stops the shortcut firing for good. Both
        // actions are guarded no-ops with no track loaded.
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveSession() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { ViewerActions.saveAs(model) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
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
        }
        // A plain-letter key equivalent is claimed application-wide and offered
        // before the key window's first responder, so these must only be ours
        // while this window is the one taking keys. (`Clear Selection` and its
        // `Esc` moved to Edit in Task 18, under the same guard.)
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
                Button(url.lastPathComponent) { ViewerActions.open(model, url: url) }
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
