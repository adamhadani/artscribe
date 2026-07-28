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
    /// Both on their own defaults suite: an acceptance run must not rewrite the
    /// theme the user left the real app in, nor drop its test file into their
    /// Open Recent menu. The theme also needs a known starting point.
    @State private var recents = RecentFiles(defaults: Self.defaults)
    @State private var theme = ThemeController(defaults: Self.defaults)
    /// Also on the acceptance suite: the run edits the nudge amounts to check
    /// that a change applies live, and must not leave the user's real ones
    /// altered.
    @State private var nudge = NudgeSettings(defaults: Self.defaults)

    private static let defaults =
        UserDefaults(suiteName: "com.artscribe.acceptance") ?? .standard

    init() {
        // Before anything else, and before any audio graph can exist: an
        // automated run makes no sound. See `AcceptanceRun.silenceOutput`, which
        // does this a second time on the run path so a future entry point cannot
        // lose it.
        AcceptanceRun.silenceOutput()
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
            ViewerCommands(model: model, recents: recents)
            PlaybackCommands(model: model, devices: devices)
        }

        Settings {
            SettingsView(model: model, theme: theme)
        }
    }

    @MainActor
    private func start() async {
        model.attach(devices: devices)
        model.attach(recents: recents)
        model.attach(nudge: nudge)
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        await AcceptanceRun.runIfRequested(model: model, theme: theme)
    }
}
