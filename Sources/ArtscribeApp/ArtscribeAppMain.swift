import AppKit
import ArtscribeUI
import Playback
import SwiftUI

/// Receives the files Launch Services hands the app: "Open With" from Finder,
/// a double-clicked audio file once Artscripture is the chosen handler, and a file
/// dropped on the dock icon. `CFBundleDocumentTypes` in `App/Info.plist` is what
/// makes macOS offer Artscripture in the first place; this is what makes the offer
/// mean something.
///
/// Only reachable from a real bundle — an unbundled `swift run` binary is never
/// sent these events — which is exactly why it lives in the app shell.
@MainActor
final class ArtscribeAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the scene as soon as it appears. A file can arrive *before* that:
    /// launching by double-clicking a track delivers the open event during
    /// startup, so it is held here and replayed rather than dropped.
    var model: ViewerModel? {
        didSet {
            guard let pending, let model else { return }
            self.pending = nil
            ViewerActions.open(model, url: pending)
        }
    }

    private var pending: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        // One window, one track: if several files are dropped at once the first
        // is the one that opens. Silently loading the last would be worse.
        guard let url = urls.first else { return }
        if let model {
            ViewerActions.open(model, url: url)
        } else {
            pending = url
        }
    }

    /// ⌘Q. The third event that leaves a session behind, and the one AppKit
    /// gives no window-close notification for: without this, quitting with an
    /// unsaved loop would drop it silently, which is precisely what spec §7
    /// forbids.
    ///
    /// `.terminateLater` because the sheet is asynchronous; the reply comes
    /// back from its completion handler.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        switch model.closeAction {
        case .close:
            return .terminateNow
        case .saveThenClose:
            model.performClose()
            return .terminateNow
        case .ask:
            SessionPrompt.whenSafeToLeave(model) { proceed in
                // Deferred, always: `reply(toApplicationShouldTerminate:)` is
                // only legal *after* this method has returned `.terminateLater`,
                // and the completion can run synchronously.
                DispatchQueue.main.async {
                    NSApp.reply(toApplicationShouldTerminate: proceed)
                }
            }
            return .terminateLater
        }
    }
}

@main
struct ArtscribeAppMain: App {
    @NSApplicationDelegateAdaptor(ArtscribeAppDelegate.self) private var delegate
    @State private var model = ViewerModel()
    /// Owns the output-device selection for the whole app. It exists before any
    /// track is loaded and outlives every `AudioOutput`, which is why the
    /// selection lives here rather than inside the audio graph.
    @State private var devices = OutputDeviceController(source: PlatformAudio.makeDeviceSource())
    /// The Open Recent list. Application state, like the two above: it outlives
    /// every loaded track.
    @State private var recents = RecentFiles()
    /// Light / Dark / System, persisted. Owned here because it is a property of
    /// the application rather than of the loaded track; the Settings window
    /// binds to this object.
    @State private var theme = ThemeController()
    /// Where the nudge amounts are persisted. The applied values live on the
    /// model — this is only their backing tape (see `NudgeSettings`).
    @State private var nudge = NudgeSettings()
    /// The zoom direction and the selection-move amounts, persisted the same
    /// way and for the same reason (see `InteractionSettings`).
    @State private var interaction = InteractionSettings()
    /// How far a `Space` resume rolls back, persisted the same way again — its
    /// own store because its floor differs (see `PrerollSettings`).
    @State private var preroll = PrerollSettings()
    /// Reads and writes the `.artscribe` sidecar (spec §7). Application state
    /// like the rest of these: it outlives every loaded track, and it holds
    /// nothing but where the read-only-volume fallback lives.
    @State private var sessions = SessionStore()
    /// The shortcut window's filter and pinned layer, and the closure that
    /// opens it. Application state like the rest of these: the window outlives
    /// every loaded track and is closable independently of the document.
    @State private var shortcuts = ShortcutWindowController()
    /// Task 21's Practice window: the closure that opens it. Application state
    /// like the rest of these.
    @State private var practice = PracticeWindowController()
    /// The About panel's opener. Application state like the rest of these, and
    /// held here rather than defaulted inside `MenuContext` because `context`
    /// below is rebuilt on every access — a default would mint a fresh, unopened
    /// controller each time and the menu item would open nothing.
    @State private var about = AboutWindowController()
    /// Where the practice ramp's schedule is persisted. The applied schedule
    /// lives on the model — this is only its backing tape (see
    /// `PracticeSettings`), exactly as `nudge` is for the nudge amounts.
    @State private var practiceSettings = PracticeSettings()

    /// Everything the menus and the window dispatch through, built once. See
    /// `MenuContext` for why it is one value rather than five parameters.
    private var context: MenuContext {
        MenuContext(
            model: model, recents: recents, devices: devices, shortcuts: shortcuts,
            practice: practice, about: about, theme: theme)
    }

    init() {
        // A SwiftPM executable is not an app bundle, so AppKit starts it as an
        // accessory with no menu bar and no way to take keyboard focus. Asking
        // for the regular activation policy up front fixes both.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Artscripture", id: "viewer") {
            ViewerWindow(context: context, theme: theme)
                .frame(minWidth: 720, minHeight: 420)
                .task { start() }
                .openShortcutWindow(shortcuts)
                .openPracticeWindow(practice)
                .openAboutWindow(about)
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            ViewerCommands(context: context)
            // Edit ▸ the selection actions, Playback ▸ the transport, and Loop
            // ▸ the signature feature. Declaration order is menu-bar order for
            // the two `CommandMenu`s, so Loop sits next to Playback.
            EditCommands(context: context)
            PlaybackCommands(context: context)
            LoopCommands(context: context)
        }

        // Task 25's shortcut reference: a **separate** window, not a panel
        // inside the document. Resizable, its frame remembered by name (see
        // `ShortcutWindow.configure`), opened by `⌘/` and by View ▸ Keyboard
        // Shortcuts, and closable on its own without disturbing the track.
        Window("Keyboard Shortcuts", id: ShortcutWindowController.windowID) {
            ShortcutWindow(context: context, theme: theme)
                .openShortcutWindow(shortcuts)
                .openPracticeWindow(practice)
                .openAboutWindow(about)
        }
        // Wider and shorter than the 1100×660 it opened at first. The keyboard
        // is a 2.7:1 object that can only grow taller by growing wider, so a
        // tall default spent a third of the left pane on nothing; at this shape
        // the board very nearly fills its half. See `ShortcutSplit`.
        .defaultSize(width: 1320, height: 620)
        .windowResizability(.contentMinSize)

        // Task 21's Practice hub — the ramping loop. A window of its own for a
        // sharper version of Task 25's reason: this is a thing you watch the
        // waveform while using, and a panel inside the document could only exist
        // by taking width from the surface the loop is drawn on.
        Window("Practice", id: PracticeWindowController.windowID) {
            PracticeWindow(context: context, theme: theme)
                .openShortcutWindow(shortcuts)
                .openPracticeWindow(practice)
                .openAboutWindow(about)
        }
        // A tall, narrow utility window: three fields and a readout, meant to
        // sit beside the document rather than in front of it.
        .defaultSize(width: 340, height: 400)
        .windowResizability(.contentMinSize)

        // The About panel (App Store guideline 5.1.1(i), and Rubber Band's GPL
        // attribution). A `Window` rather than AppKit's standard About panel,
        // which can only show what `Info.plist` gives it — not a privacy link,
        // and not a licence list that has to differ between the macOS and
        // iPadOS builds.
        //
        // It carries the two openers as well, so a command chosen while the
        // panel is the frontmost window still reaches the other windows.
        Window("About Artscripture", id: AboutWindowController.windowID) {
            AboutWindow(about: about, theme: theme)
                .openShortcutWindow(shortcuts)
                .openPracticeWindow(practice)
                .openAboutWindow(about)
        }
        // A panel, not a workspace: it opens at the size of its contents and
        // grows only when the licence list is disclosed.
        .defaultSize(width: AboutWindow.minimumWidth, height: AboutWindow.minimumHeight)
        .windowResizability(.contentMinSize)

        // The idiomatic route to **Artscripture ▸ Settings…**: this scene is what
        // puts the item in the app menu and wires ⌘, to it, so neither is
        // hand-rolled here.
        Settings {
            SettingsView(model: model, theme: theme)
        }
    }

    @MainActor
    private func start() {
        // The model routes audio through the shared device controller, so a
        // device chosen before any track is loaded still applies to the first
        // one that is.
        model.attach(devices: devices)
        model.attach(recents: recents)
        model.prefs.adopt(nudge: nudge)
        model.prefs.adopt(interaction: interaction)
        model.prefs.adopt(preroll: preroll)
        model.attach(sessions: sessions)
        model.attach(practice: practiceSettings)
        // Hands the delegate somewhere to send a file, and replays one that
        // arrived before the scene existed — which is what happens when the app
        // is launched *by* opening a track.
        delegate.model = model
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}
