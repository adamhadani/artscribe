import SwiftUI

/// Actions the menu bar and the window share, so a command has exactly one
/// implementation regardless of how it was invoked.
///
/// The two that need a panel live here; everything else dispatches through
/// `ActionInvoker`.
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

/// **File** and **View**.
///
/// Neither this menu nor any other lists its own items any more: every title,
/// key equivalent and enablement comes from `ActionCatalog` by way of
/// `MenuPlan`, so a shortcut cannot be changed here and left stale in the
/// window's key handler or in the inspector's shortcut reference. See
/// `ActionCatalogTests` for the guard.
///
/// Both groups are `CommandGroup`s into menus macOS already builds, never
/// `CommandMenu`s of the same name: a `CommandMenu("View")` sits *beside* the
/// View menu SwiftUI creates for the window, and the menu bar ends up with two.
public struct ViewerCommands: Commands {
    private let context: MenuContext

    public init(context: MenuContext) {
        self.context = context
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            MenuItems(section: .fileOpen, context: context)
        }

        // Session persistence (spec §7) in the place every Mac user looks for
        // it. `.saveItem` is the standard group, so these land under Open Recent
        // with the separator the system draws, and ⌘S / ⇧⌘S are the system's own
        // shortcuts rather than ones invented here.
        CommandGroup(replacing: .saveItem) {
            MenuItems(section: .fileSave, context: context)
        }

        CommandGroup(after: .toolbar) {
            MenuItems(section: .view, context: context)
        }
    }
}

/// **File ▸ Open Recent**, where macOS users look for it, with the "Clear Menu"
/// item the system menu has.
///
/// A nested `View` for the same reason as the theme and device menus: a
/// `Commands` body does not re-evaluate when an `@Observable` changes, so a list
/// written straight into one would still show whatever was recent at launch.
///
/// Its items are file names rather than actions, which is why `MenuPlan` calls
/// it a `dynamicSubmenu` and the drift guard does not ask the catalog about it.
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
