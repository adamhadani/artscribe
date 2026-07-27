import AppKit
import ArtscribeUI
import Playback
import SwiftUI

/// A standalone acceptance-harness executable.
///
/// It hosts the same window shell as `ArtscribeApp`, but instead of waiting
/// for real input it drives itself through `AcceptanceRun`. This is its own
/// target — not code inside `ArtscribeApp` — so the shipping app binary
/// contains nothing but the app: no scripted `NSEvent` synthesis, no
/// `--acceptance` flag parsing, none of it. See `AcceptanceRun.swift` for why
/// the harness exists and how it drives the window.
///
/// Run with:
/// ```sh
/// swift run ArtscribeAcceptance --acceptance <audio-file> [--bad-file <file>] [--out <dir>]
/// ```
@main
struct AcceptanceMain: App {
    @State private var model = ViewerModel()
    @State private var devices = OutputDeviceController(source: CoreAudioDeviceSource())
    /// Its own defaults suite: an acceptance run must not rewrite the theme the
    /// user left the real app in, and it needs a known starting point anyway.
    @State private var recents = RecentFiles()
    @State private var theme = ThemeController(
        defaults: UserDefaults(suiteName: "com.artscribe.acceptance") ?? .standard)

    init() {
        // Same reasoning as `ArtscribeAppMain`: an unbundled SwiftPM executable
        // otherwise starts as an accessory with no menu bar and no keyboard focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Artscribe (acceptance)", id: "viewer") {
            ViewerWindow(model: model, theme: theme)
                .frame(minWidth: 720, minHeight: 420)
                .task { await start() }
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            ViewerCommands(model: model, theme: theme, recents: recents)
            PlaybackCommands(model: model, devices: devices)
        }
    }

    @MainActor
    private func start() async {
        model.attach(devices: devices)
        model.attach(recents: recents)
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        await AcceptanceRun.runIfRequested(model: model, theme: theme)
    }
}
