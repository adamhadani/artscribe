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
            guard let pending else { return }
            self.pending = nil
            model?.open(url: pending)
        }
    }

    private var pending: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        // One window, one track: if several files are dropped at once the first
        // is the one that opens. Silently loading the last would be worse.
        guard let url = urls.first else { return }
        if let model {
            model.open(url: url)
        } else {
            pending = url
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

    init() {
        // A SwiftPM executable is not an app bundle, so AppKit starts it as an
        // accessory with no menu bar and no way to take keyboard focus. Asking
        // for the regular activation policy up front fixes both.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Artscribe", id: "viewer") {
            ViewerWindow(model: model, theme: theme)
                .frame(minWidth: 720, minHeight: 420)
                .task { start() }
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            ViewerCommands(model: model, recents: recents)
            PlaybackCommands(model: model, devices: devices)
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
        // Hands the delegate somewhere to send a file, and replays one that
        // arrived before the scene existed — which is what happens when the app
        // is launched *by* opening a track.
        delegate.model = model
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}
