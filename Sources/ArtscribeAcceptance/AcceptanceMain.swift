import AppKit
import ArtscribeUI
import Foundation
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
    /// Also on the acceptance suite, and for the same reason: the run flips the
    /// zoom direction and edits the move amounts to check that each applies
    /// live, and must not leave the user's real preferences altered.
    @State private var interaction = InteractionSettings(defaults: Self.defaults)
    /// On its own fallback directory, for the same reason the four above are on
    /// their own defaults suite: the run deliberately makes a track's folder
    /// read-only to check the spec §7 fallback, and must not leave sessions in
    /// the user's real Application Support.
    @State private var sessions = SessionStore(fallbackDirectory: Self.sessionFallbackDirectory)
    /// Also on the acceptance suite: the filter and the pinned layer are not
    /// persisted, but the divider position is, and a run that drags it must not
    /// leave the user's real shortcut window resplit.
    @State private var shortcuts = ShortcutWindowController(defaults: Self.defaults)
    /// Task 21's Practice window. The controller holds no persisted state; the
    /// ramp schedule it edits is on the acceptance suite below, for the same
    /// reason as everything else here — a run must not leave the user's real
    /// practice ramp reconfigured.
    @State private var practice = PracticeWindowController()
    @State private var practiceSettings = PracticeSettings(defaults: Self.defaults)

    private var context: MenuContext {
        MenuContext(
            model: model, recents: recents, devices: devices, shortcuts: shortcuts,
            practice: practice)
    }

    static let sessionFallbackDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("artscribe-acceptance-sessions", isDirectory: true)

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
            ViewerWindow(context: context, theme: theme)
                .frame(minWidth: 720, minHeight: 420)
                .task { await start() }
                .openShortcutWindow(shortcuts)
                .openPracticeWindow(practice)
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

        Window("Keyboard Shortcuts", id: ShortcutWindowController.windowID) {
            ShortcutWindow(context: context, theme: theme)
                .openShortcutWindow(shortcuts)
                .openPracticeWindow(practice)
        }
        .defaultSize(width: 1320, height: 620)
        .windowResizability(.contentMinSize)

        Window("Practice", id: PracticeWindowController.windowID) {
            PracticeWindow(context: context, theme: theme)
                .openShortcutWindow(shortcuts)
                .openPracticeWindow(practice)
        }
        .defaultSize(width: 340, height: 400)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model, theme: theme)
        }
    }

    @MainActor
    private func start() async {
        model.attach(devices: devices)
        model.attach(recents: recents)
        model.attach(nudge: nudge)
        model.attach(interaction: interaction)
        model.attach(sessions: sessions)
        model.attach(practice: practiceSettings)
        NSApplication.shared.activate()
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        await AcceptanceRun.runIfRequested(model: model, theme: theme, context: context)
    }
}
