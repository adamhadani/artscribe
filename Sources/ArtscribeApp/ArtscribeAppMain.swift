import AppKit
import ArtscribeUI
import Playback
import SwiftUI

@main
struct ArtscribeAppMain: App {
    @State private var model = ViewerModel()
    /// Owns the output-device selection for the whole app. It exists before any
    /// track is loaded and outlives every `AudioOutput`, which is why the
    /// selection lives here rather than inside the audio graph.
    @State private var devices = OutputDeviceController(source: CoreAudioDeviceSource())
    /// The Open Recent list. Application state, like the two above: it outlives
    /// every loaded track.
    @State private var recents = RecentFiles()
    /// Light / Dark / System, persisted. Owned here because it is a property of
    /// the application rather than of the loaded track — and so the Settings
    /// window (Task 14) can bind to the same object the View menu does.
    @State private var theme = ThemeController()

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
            ViewerCommands(model: model, theme: theme, recents: recents)
            PlaybackCommands(model: model, devices: devices)
        }
    }

    @MainActor
    private func start() {
        // The model routes audio through the shared device controller, so a
        // device chosen before any track is loaded still applies to the first
        // one that is.
        model.attach(devices: devices)
        model.attach(recents: recents)
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}
