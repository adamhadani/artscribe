import AppKit
import ArtscribeUI
import Playback
import SwiftUI

/// Receives the files Launch Services hands the app: "Open With" from Finder,
/// a double-clicked audio file once Artscribe is the chosen handler, and a file
/// dropped on the dock icon. `CFBundleDocumentTypes` in `App/Info.plist` is what
/// makes macOS offer Artscribe in the first place; this is what makes the offer
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
    @State private var devices = OutputDeviceController(source: CoreAudioDeviceSource())
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
    /// Reads and writes the `.artscribe` sidecar (spec §7). Application state
    /// like the rest of these: it outlives every loaded track, and it holds
    /// nothing but where the read-only-volume fallback lives.
    @State private var sessions = SessionStore()
    /// Whether the side panel is open and which page it is on (spec §2, §6.2).
    /// Application state like the rest of these: it outlives every loaded track.
    @State private var inspector = InspectorController()

    /// Everything the menus and the window dispatch through, built once. See
    /// `MenuContext` for why it is one value rather than four parameters.
    private var context: MenuContext {
        MenuContext(model: model, recents: recents, devices: devices, inspector: inspector)
    }

    init() {
        // A SwiftPM executable is not an app bundle, so AppKit starts it as an
        // accessory with no menu bar and no way to take keyboard focus. Asking
        // for the regular activation policy up front fixes both.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Artscribe", id: "viewer") {
            ViewerWindow(context: context, theme: theme)
                .frame(minWidth: 720, minHeight: 420)
                .task { start() }
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

        // The idiomatic route to **Artscribe ▸ Settings…**: this scene is what
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
        model.attach(nudge: nudge)
        model.attach(interaction: interaction)
        model.attach(sessions: sessions)
        // Hands the delegate somewhere to send a file, and replays one that
        // arrived before the scene existed — which is what happens when the app
        // is launched *by* opening a track.
        delegate.model = model
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}
