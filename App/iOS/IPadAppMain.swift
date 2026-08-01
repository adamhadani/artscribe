import ArtscribeUI
import Playback
import SwiftUI

/// The iPad app shell.
///
/// The counterpart to `Sources/ArtscribeApp/ArtscribeAppMain.swift`, and
/// deliberately a separate file rather than that one under `#if`: the two
/// differ in almost every line that matters — one `WindowGroup` against four
/// `Window` scenes, no `NSApplicationDelegateAdaptor`, no activation policy, no
/// `Settings` scene — and interleaving them would make both harder to read than
/// either is apart. Everything below the shell is the *same* `ArtscribeUI`
/// product, so there is one copy of the actual application.
///
/// Lives under `App/` rather than `Sources/` on purpose: SwiftPM cannot build an
/// iOS application, so this is compiled only by the Xcode target in
/// `project.yml`, and a directory under `Sources/` that no SwiftPM target claims
/// draws warnings.
///
/// ## What this build can and cannot do
///
/// It opens a track, draws the waveform, selects, loops, plays — and, as of the
/// Signalsmith backend, **changes speed for real**. That last one was the gap
/// that made this build a demonstration rather than a product: Rubber Band is a
/// macOS dylib from Homebrew, so `PlatformStretcher` used to hand back an
/// `IdentityStretcher` here and the speed control moved without affecting
/// anything at all. Signalsmith is vendored source compiled into the app, so it
/// exists on iOS, and it is measured to hold pitch within 0.05 cents at half and
/// double speed. See `PlatformStretcher`.
///
/// The Keyboard Shortcuts and Practice windows are absent rather than broken —
/// their views are still macOS-only, and they become sheets in the next piece of
/// work.
@main
struct IPadAppMain: App {
    @State private var model = ViewerModel()
    /// Present for the same reason it is on macOS — it owns the output-device
    /// selection and outlives every `AudioOutput`. On iPad it resolves to
    /// `CurrentRouteDeviceSource`, which reports the one route the system chose;
    /// there is nothing to pick, and that is correct rather than a limitation.
    @State private var devices = OutputDeviceController(source: PlatformAudio.makeDeviceSource())
    @State private var recents = RecentFiles()
    @State private var theme = ThemeController()
    @State private var nudge = NudgeSettings()
    @State private var interaction = InteractionSettings()
    @State private var preroll = PrerollSettings()
    @State private var sessions = SessionStore()
    @State private var shortcuts = ShortcutWindowController()
    @State private var practice = PracticeWindowController()
    @State private var practiceSettings = PracticeSettings()
    /// The About panel — a sheet here rather than a window. It is the only place
    /// this build states its privacy policy and its licences, which App Store
    /// guideline 5.1.1(i) requires to be reachable from inside the app, so on
    /// iPad it is reached without a hardware keyboard: `EmptyStateView` carries
    /// a button, and `DocumentView` presents the sheet.
    @State private var about = AboutWindowController()
    @State private var settingsSheet = SettingsWindowController()
    @State private var welcome = WelcomeState()

    private var context: MenuContext {
        MenuContext(
            model: model, recents: recents, devices: devices, shortcuts: shortcuts,
            practice: practice, about: about, settings: settingsSheet, welcome: welcome,
            theme: theme)
    }

    var body: some Scene {
        WindowGroup {
            ViewerWindow(context: context, theme: theme)
                .task { start() }
                // **What makes `CFBundleDocumentTypes` mean anything.** Declaring
                // the audio UTIs puts Artscripture in Files ▸ Share ▸ Open With
                // and in the "Open in…" sheet from Mail, Dropbox and AirDrop —
                // and for one release it did exactly that and nothing else:
                // iPadOS handed the app a URL, no scene handled it, and the app
                // launched to its resting screen with the file silently
                // dropped. Advertising a route that dead-ends is worse than not
                // appearing in the menu at all.
                .onOpenURL(perform: openIncoming)
        }
        // iPadOS builds a real menu bar from these when a hardware keyboard is
        // attached, and — the part that matters more — it is what makes the
        // catalog's key equivalents live. Without it none of the ~90 shortcuts
        // would reach `ActionInvoker`, which is the whole interface on this
        // platform until the touch vocabulary lands.
        .commands {
            ViewerCommands(context: context)
            EditCommands(context: context)
            PlaybackCommands(context: context)
            LoopCommands(context: context)
        }
    }

    /// A file handed over by the system — Files ▸ Open With, AirDrop, Mail.
    ///
    /// The same three steps the document picker takes in `DocumentView`, and for
    /// the same reasons:
    ///
    /// 1. **Start scoped access before anything reads the file.** It lives
    ///    outside the container, and reading it without the grant fails with a
    ///    permission error that looks exactly like a corrupt file.
    /// 2. **Mint the bookmark here.** A bookmark can only be made while the
    ///    process is allowed to read the file, and this closure is the one
    ///    moment that is true — `RecentFiles.note` runs when the decode
    ///    *finishes*, long after a launch-time grant would have gone.
    /// 3. **Hand the grant to the model**, never release it here. `open` starts
    ///    an async load and returns immediately, so releasing on the way out
    ///    drops access before the decode has read a byte. That exact `defer` was
    ///    the picker's bug once already.
    ///
    /// `recents` is used directly rather than through `model.recents`, which
    /// `start()` attaches: a URL delivered at launch can arrive before `.task`
    /// has run. Routing through `ViewerActions.open` keeps the outgoing
    /// session's safety check — on iPad that means an unsaved session is written
    /// rather than discarded — instead of a second way to open a track.
    @MainActor
    private func openIncoming(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped { recents.rememberBookmark(for: url) }
        ViewerActions.open(model, url: url, securityScoped: scoped)
    }

    @MainActor
    private func start() {
        model.attach(devices: devices)
        model.attach(recents: recents)
        model.prefs.adopt(nudge: nudge)
        model.prefs.adopt(interaction: interaction)
        model.prefs.adopt(preroll: preroll)
        model.attach(sessions: sessions)
        model.attach(practice: practiceSettings)
    }
}
