import SwiftUI

/// Actions the menu bar and the window share, so a command has exactly one
/// implementation regardless of how it was invoked.
///
/// The two that need a panel live here; everything else dispatches through
/// `ActionInvoker`.
public enum ViewerActions {
    /// macOS only, for the reason `AudioFileTypes.runOpenPanel` gives: a modal
    /// panel can *return* a choice, and iPad's document picker cannot — it is a
    /// presentation with a callback, so File ▸ Open on iPad is a `.fileImporter`
    /// on a view rather than a function. `open(_:url:)` below, which is the one
    /// way into `ViewerModel.open(url:)`, is shared by both and is what that
    /// importer will call.
    #if os(macOS)
    @MainActor
    public static func open(_ model: ViewerModel) {
        guard let url = AudioFileTypes.runOpenPanel() else { return }
        open(model, url: url)
    }
    #endif

    /// The one way into `ViewerModel.open(url:)` from the UI.
    ///
    /// Artscribe is a one-window, one-track app, so loading another file is the
    /// only other way to walk away from a session — and it has to ask the same
    /// question closing the window does, or a loop you set two minutes ago
    /// disappears because you reached for Open Recent. Every route in goes
    /// through here: the Open panel, Open Recent, a drop on the window, and a
    /// file handed over by Launch Services.
    ///
    /// `securityScoped` is passed straight through to `ViewerModel.open`, which
    /// owns the grant for the life of the document. Callers that did not start
    /// scoped access — every macOS route, and the Recent menu — leave it false
    /// and let the resolution below do the work.
    @MainActor
    public static func open(_ model: ViewerModel, url: URL, securityScoped: Bool = false) {
        #if os(macOS)
        SessionPrompt.whenSafeToLeave(model) { proceed in
            guard proceed else { return }
            model.open(url: url)
        }
        #else
        // **Open Recent, on iPad.** The stored URL is a path, and a path to a
        // file outside the container stops being readable the moment the app
        // relaunches — so the list would show eight tracks and open none of
        // them. `resolveBookmark` returns a URL that already has scoped access
        // started, or nil when there is nothing remembered, in which case the
        // original is tried unchanged and behaves exactly as it did before.
        let resolved = model.recents?.resolveBookmark(for: url)
        let target = resolved ?? url
        // iPad has no sheet for this question yet. Rather than ask nothing and
        // discard the outgoing session — which is precisely the silent data loss
        // spec §7 exists to prevent — the unsaved case is *saved* and then
        // opened. Nobody loses a loop they set two minutes ago; the cost is that
        // a session they would have chosen to abandon is written instead, which
        // is the recoverable direction to be wrong in.
        //
        // Replace with the real confirmation sheet when the sheets land.
        if case .ask = model.closeAction { model.performClose() }
        model.open(url: target, securityScoped: securityScoped || resolved != nil)
        #endif
    }

    /// **File ▸ Save As…** — the panel, then the write. The decision about what
    /// saving somewhere other than the canonical sidecar *means* is
    /// `ViewerModel.saveSession(to:)`'s, and is tested there.
    ///
    /// macOS only. Save As needs somewhere to *ask* — an `NSSavePanel` here, a
    /// document picker on iPad — and the picker has to be presented from a view,
    /// which this deliberately is not. Left unimplemented rather than quietly
    /// redirected to the canonical sidecar, because "Save As…" that saves
    /// somewhere else without saying so is worse than one that is absent.
    ///
    /// Unreachable on iPad today: there is no iPad app target, and no menu or
    /// control invokes it. It must not stay that way once one exists — see `#58`.
    #if os(macOS)
    @MainActor
    public static func saveAs(_ model: ViewerModel) {
        guard let suggestion = model.suggestedSessionSaveURL, model.canSaveSession else { return }
        guard let url = SessionPanels.runSavePanel(suggesting: suggestion) else { return }
        model.saveSession(to: url)
    }
    #endif
}

/// **File** and **View**.
///
/// Neither this menu nor any other lists its own items any more: every title,
/// key equivalent and enablement comes from `ActionCatalog` by way of
/// `MenuPlan`, so a shortcut cannot be changed here and left stale in the
/// window's key handler or in the shortcut window. See
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

        // **Artscribe ▸ About Artscribe**, *replacing* the standard item rather
        // than adding to it. `.appInfo` is AppKit's own About command, which
        // opens a panel assembled from `Info.plist`; leaving it in place and
        // adding ours would give the app menu two About items, one of which
        // knows nothing about the privacy policy or the licences.
        CommandGroup(replacing: .appInfo) {
            AboutMenuItem(context: context)
        }

        // **Help ▸ About Artscribe.** `.help` is the standard "Artscribe Help"
        // item, and it is replaced rather than joined for a blunter reason than
        // the one above: this app ships no help book, so the item macOS puts
        // there opens a sheet saying help is not available. A second route to
        // the About panel is worth more than that, and the Help menu is the
        // other place a reader looks for a privacy policy — which guideline
        // 5.1.1(i) requires them to be able to find from inside the app.
        CommandGroup(replacing: .help) {
            AboutMenuItem(context: context)
        }
    }
}

/// **About Artscribe**, in both of the menus macOS builds for it.
///
/// A `View` rather than a bare `Button` in the `Commands` body, like every other
/// item in this app: a `Commands` body is not re-evaluated when an `@Observable`
/// changes, and while this particular item is never disabled, an item that is
/// built the other way is the one nobody notices going stale later.
///
/// It carries no key equivalent. About is not something you reach for mid-take,
/// and every free chord in this app is worth more to the transport than to a
/// panel opened once.
private struct AboutMenuItem: View {
    let context: MenuContext

    var body: some View {
        Button(ActionCatalog.entry(.appAbout).title) {
            ActionInvoker.perform(.appAbout, context)
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
