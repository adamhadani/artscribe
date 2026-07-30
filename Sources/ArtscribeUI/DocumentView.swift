import SwiftUI

/// The viewer window.
///
/// Keyboard handling lives here rather than in the lanes so the bindings work
/// wherever the pointer is. It resolves a press against `ActionCatalog` — the
/// same table the menu bar is built from — so a chord cannot mean one thing
/// here and another there. Spec §6.3's rebindable `BindingTable` replaces the
/// fixed table behind `KeyBindings`, and nothing else.
public struct DocumentView: View {
    private let context: MenuContext
    private var model: ViewerModel { context.model }
    @FocusState private var hasKeyboardFocus: Bool
    // Both are macOS window concepts. `TrackpadMonitor` is a global `NSEvent`
    // monitor for ⌘-scroll and pinch; `DocumentWindowChrome` owns the title
    // bar's modified dot, its proxy icon and the close prompt. On iPad the
    // gestures come from SwiftUI directly and there is no title bar at all —
    // both are part of the touch work in `#58`, not translations of these.
    #if os(macOS)
    @State private var trackpad = TrackpadMonitor()
    /// The window's modified dot, proxy icon and close prompt. Built once, from
    /// the same model this view draws — see `DocumentWindowChrome`.
    @State private var chrome: DocumentWindowChrome
    #endif
    /// The *resolved* scheme, after the window has applied the theme
    /// preference. Reading it here rather than the preference itself keeps this
    /// view out of the theme's business entirely — it draws whatever scheme it
    /// finds itself in.
    ///
    /// What it must *not* be asked to do is resolve `System`: this value is only
    /// as good as what `preferredColorScheme` was given, and SwiftUI leaves it
    /// on the last explicit scheme when handed a `nil`. `ThemeController` does
    /// the resolving and always passes something concrete.
    @Environment(\.colorScheme) private var colorScheme

    public init(context: MenuContext) {
        self.context = context
        #if os(macOS)
        _chrome = State(initialValue: DocumentWindowChrome(model: context.model))
        #endif
    }

    private var appearance: Appearance { colorScheme == .dark ? .dark : .light }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            TitleBarView(model: model) { ViewerActions.open(model) }
            #else
            // The iPad Open button needs a `.fileImporter` presented from
            // here rather than a call that returns a URL; until that lands
            // the button has nothing to do, so it is given nothing to do
            // rather than an action that silently fails. See `#58`.
            TitleBarView(model: model) {}
            #endif

            if let message = model.errorMessage {
                ErrorBannerView(message: message) { model.dismissError() }
            }

            // Spec §8: an output that could not be opened, a route change, a
            // render stall or a rejected command is shown here, inline and
            // dismissible — never as a modal, and never swallowed.
            if let message = model.playbackNotice {
                ErrorBannerView(message: message) { model.dismissPlaybackNotice() }
            }

            // The output device vanished, or refused a switch. Kept separate from
            // `playbackNotice` because its lifetime belongs to the device
            // controller, and because it must show even with no track loaded —
            // when there is no session and therefore no display link polling.
            if let message = model.deviceNotice {
                ErrorBannerView(message: message) { model.dismissDeviceNotice() }
            }

            // Spec §7: a damaged sidecar, a session that had to go into
            // Application Support because the track's folder is read-only, or a
            // Save As that went somewhere reopening will not look. All three are
            // cases where what is on disk is not what the user would assume, so
            // none of them is allowed to be silent.
            if let message = model.sessionNotice {
                ErrorBannerView(message: message) { model.dismissSessionNotice() }
            }

            // Spec §8's read-only-sidecar fallback, as a **standing** banner.
            //
            // Task 20 put it in the inspector's chrome, following spec §7 and
            // §8's wording; Task 25 removed the inspector, and this is where it
            // belongs anyway. What §8 requires is that the fallback be
            // *visible*, not that it live in a particular container — and the
            // inline banner stack is where this window already says "something
            // is not as you would assume", four notices deep. Undismissible,
            // unlike the four above it: it describes a condition rather than an
            // event, and dismissing it would leave nothing at all telling you
            // your loop points are not beside your music.
            SessionFallbackBanner(model: model)

            if model.hasTrack {
                OverviewStripView(model: model)
                    .frame(height: 58)
                TimeRulerView(model: model)
                // Only when the file has a cue sheet and the user has not put
                // the lane away, so a track with no markers costs no height at
                // all — which is most of them.
                if model.showsTrackMarks {
                    CueMarkerLaneView(model: model, appearance: appearance)
                }
                WaveformLanesView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView()
            }

            // Directly above the status bar, and given the keyboard back after
            // every press: see `TransportBarView` for why that second half is
            // not optional in a keyboard-first app.
            TransportBarView(model: model) { hasKeyboardFocus = true }
            StatusBarView(model: model)
        }
        .background(Palette.of(appearance).background.color())
        // Tells `KeyWindowTracker` which window the transport belongs to. That
        // is what lets the menus' plain-letter key equivalents stand down while
        // Settings — which has editable fields — is the key window.
        #if os(macOS)
        .background(
            WindowReader { window in
                KeyWindowTracker.shared.adopt(document: window)
                // And which window carries the modified dot and answers ⌘W.
                chrome.adopt(window)
            }
        )
        #endif
        // The window's title, so the proxy icon and the ⌘-click path menu both
        // name the track rather than the app.
        .navigationTitle(model.windowTitle)
        // AppKit has no SwiftUI equivalent for the close button's modified dot,
        // so it is pushed across whenever the model's answer moves.
        #if os(macOS)
        .onChange(of: model.isDirty, initial: true) { _, _ in chrome.refresh() }
        .onChange(of: model.fileName) { _, _ in chrome.refresh() }
        #endif
        // One place sets the palette, so no view can draw half of one theme.
        .environment(\.palette, Palette.of(appearance))
        // And one place tells the model, because the cached waveform bitmap has
        // its colours baked in: without this the lanes keep the old theme's
        // pixels until the viewport happens to move. `initial: true` covers the
        // launch case, where the window may already be in light mode.
        .onChange(of: appearance, initial: true) { _, appearance in
            model.setAppearance(appearance)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(phases: [.down, .repeat], action: handle)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            ViewerActions.open(model, url: url)
            return true
        }
        .onAppear {
            hasKeyboardFocus = true
            #if os(macOS)
            trackpad.start(model: model)
            #endif
        }
        .onDisappear {
            #if os(macOS)
            trackpad.stop()
            #endif
            // Closing the window must not leave the audio graph running or the
            // display link ticking against a window nobody can see.
            model.teardownPlayback()
        }
    }

    // MARK: - Commands

    /// The agreed left-hand cluster (spec §6.2), resolved through the one
    /// catalog the menus are also built from.
    ///
    /// This used to be eight `handle…` methods whose `switch`es spelled out
    /// `"z"`, `"x"`, `"a"`…`"g"` beside the menus that declared the same keys —
    /// the second of three places a shortcut lived, and the one no test could
    /// see. It is now a lookup: `KeyBindings` reverses `ActionCatalog`, and
    /// `ActionInvoker` runs the same closure the menu item runs.
    ///
    /// `⌘`-modified keys belong to the menu bar, so anything carrying Command
    /// is passed straight through — including `⌘C`/`⌘V`, which stay the
    /// standard Edit menu's. AppKit offers an event to the menu bar before the
    /// window, so a claimed event never arrives here and no action fires twice;
    /// what this provides is a path for the chords `NSMenu` refuses to match,
    /// which is every ⇧-letter and the `⌥←`/`⌥→` alternates no `NSMenuItem`
    /// could carry alongside `⌥Z`/`⌥X`.
    ///
    /// **`Return` is bound to nothing, deliberately.** Leaving it as a synonym
    /// for `⇧Space` would mean a live binding that no menu, tooltip or README
    /// names, which is precisely the drift this project has been bitten by. It
    /// is also the key a future "commit this value" — a go-to-time field, a
    /// rename — will want, and it is easier to hand out a free key than to take
    /// back a used one.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // `press.key.character`, not `press.characters`: with Option held the
        // latter is the dead-key composition ("´" for ⌥E on a US layout), which
        // no binding could match.
        let chord = KeyChord.fromPress(character: press.key.character, modifiers: press.modifiers)
        guard let action = KeyBindings.windowAction(for: chord) else { return .ignored }
        ActionInvoker.perform(action, context)
        return .handled
    }
}

/// What the window says before anything is loaded. An empty screen is an
/// invitation to act, so it names both ways in.
struct EmptyStateView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            Text("Drop an audio file here")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.text.color())
            Text("or press ⌘O to choose one")
                .font(Typography.readout)
                .foregroundStyle(palette.dimmed.color())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.panel.color())
    }
}
