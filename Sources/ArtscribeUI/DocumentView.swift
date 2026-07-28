import ArtscribeKit
import SwiftUI

/// The viewer window.
///
/// Keyboard handling lives here rather than in the lanes so the bindings work
/// wherever the pointer is. It is deliberately a flat `switch` for now: Plan 2
/// replaces it with the real `BindingTable`.
public struct DocumentView: View {
    private let model: ViewerModel
    @FocusState private var hasKeyboardFocus: Bool
    @State private var trackpad = TrackpadMonitor()
    /// The window's modified dot, proxy icon and close prompt. Built once, from
    /// the same model this view draws — see `DocumentWindowChrome`.
    @State private var chrome: DocumentWindowChrome
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

    public init(model: ViewerModel) {
        self.model = model
        _chrome = State(initialValue: DocumentWindowChrome(model: model))
    }

    private var appearance: Appearance { colorScheme == .dark ? .dark : .light }

    public var body: some View {
        VStack(spacing: 0) {
            TitleBarView(model: model) { ViewerActions.open(model) }

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

            if model.hasTrack {
                OverviewStripView(model: model)
                    .frame(height: 58)
                TimeRulerView(model: model)
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
        .background(
            WindowReader { window in
                KeyWindowTracker.shared.adopt(document: window)
                // And which window carries the modified dot and answers ⌘W.
                chrome.adopt(window)
            }
        )
        // The window's title, so the proxy icon and the ⌘-click path menu both
        // name the track rather than the app.
        .navigationTitle(model.windowTitle)
        // AppKit has no SwiftUI equivalent for the close button's modified dot,
        // so it is pushed across whenever the model's answer moves.
        .onChange(of: model.isDirty, initial: true) { _, _ in chrome.refresh() }
        .onChange(of: model.fileName) { _, _ in chrome.refresh() }
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
            trackpad.start(model: model)
        }
        .onDisappear {
            trackpad.stop()
            // Closing the window must not leave the audio graph running or the
            // display link ticking against a window nobody can see.
            model.teardownPlayback()
        }
    }

    // MARK: - Commands

    /// The agreed left-hand cluster (spec §6.2). `⌘`-modified keys belong to the
    /// menu bar, so anything carrying Command is passed straight through —
    /// including `⌘C`/`⌘V`, which stay the standard Edit menu's.
    ///
    /// This is the **only** handler for the unmodified keys. The Playback menu
    /// lists them in its titles rather than claiming them as menu key
    /// equivalents, for the reason `ViewerCommands` records: a plain-letter key
    /// equivalent is claimed application-wide and flashes the menu bar on every
    /// keystroke, which during a `Q`/`W` speed sweep or an `E`/`R` zoom sweep is
    /// a strobe. The modifier-bearing shortcuts (`⇧Q`, `⇧W`, `⌥E`, and the nudge
    /// cluster's `⇧Z`, `⇧X`, `⌥Z`, `⌥X`) are also real menu key equivalents, and
    /// AppKit offers an event to the menu bar before the window — a claimed
    /// event never arrives here, so no action fires twice. `⌥←` and `⌥→` are the
    /// chords no menu item could carry, since an `NSMenuItem` holds exactly one.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.command) else { return .ignored }
        // `press.key.character`, not `press.characters`: with Option held the
        // latter is the dead-key composition ("´" for ⌥E on a US layout), which
        // no switch over letters could match. Lowercased so a shifted letter
        // still matches its own case.
        let character = String(press.key.character).lowercased()
        let handled =
            handleTransport(press)
            || handleVolume(character, press: press)
            || handleNavigation(character, press: press)
            || handleSelection(character, press: press)
            || handleView(character, press: press)
            || handleSpeed(character, press: press)
            || handleLoop(character)
        return handled ? .handled : .ignored
    }

    /// `Space` plays and pauses; `⇧Space` plays from the start of the selection.
    ///
    /// `⇧Space` rather than `Return` since Task 18: it puts the whole transport
    /// under the left hand, and it says what it does — a variant of the key
    /// beside it rather than an unrelated one across the keyboard.
    ///
    /// **`Return` is now bound to nothing, deliberately.** Leaving it as a
    /// synonym would mean a live binding that no menu, tooltip or README names,
    /// which is precisely the drift this project has been bitten by twice. It
    /// is also the key a future "commit this value" — a go-to-time field, a
    /// rename — will want, and it is easier to hand out a free key than to take
    /// back a used one.
    private func handleTransport(_ press: KeyPress) -> Bool {
        switch press.key {
        case .space:
            if press.modifiers.contains(.shift) {
                model.playFromStart()
            } else {
                model.togglePlayPause()
            }
        case .escape: model.clearSelection()
        default: return false
        }
        return true
    }

    /// `C`/`V` move the whole selection, `⌥C`/`⌥V` move it further — spec
    /// §6.2's `selection.move` pair.
    ///
    /// Handled here as well as on the Edit menu for the reason
    /// `handleNavigation` records: `NSMenu` matches a key equivalent against
    /// `charactersIgnoringModifiers`, and what the menu does not claim has to
    /// have somewhere to land. AppKit offers the event to the menu bar first,
    /// so a claimed chord never reaches this method and nothing fires twice.
    private func handleSelection(_ character: String, press: KeyPress) -> Bool {
        guard character == "c" || character == "v" else { return false }
        // ⌘C / ⌘V belong to the standard Edit menu; `handle(_:)` has already
        // passed those through, so this only ever sees the bare and ⌥ forms.
        let tier: SelectionMoveTier = press.modifiers.contains(.option) ? .aggressive : .gentle
        model.moveSelection(tier, direction: character == "c" ? .backward : .forward)
        return true
    }

    /// `↑`/`↓` ∓5%, `⇧↑`/`⇧↓` ∓1%, `M` mute.
    ///
    /// The vertical arrows are free: spec §6.2 binds only `←`/`→` (nudge) and
    /// `⇧←`/`⇧→` (extend selection), so this creates no double-binding and
    /// leaves the whole left-hand cluster alone.
    private func handleVolume(_ character: String, press: KeyPress) -> Bool {
        let fine = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow: model.volumeUp(fine: fine)
        case .downArrow: model.volumeDown(fine: fine)
        default:
            guard character == "m" else { return false }
            model.toggleMute()
        }
        return true
    }

    /// The three nudge tiers (spec §6.2): `Z`/`X` and `←`/`→` by the normal
    /// amount, `⇧`-modified by the fine one, `⌥`-modified by the coarse one.
    ///
    /// The whole cluster is handled here, including the four chords the Playback
    /// menu also declares as key equivalents — deliberately, and following what
    /// `⇧Q`/`⇧W`/`⌥E` already do. AppKit offers a key event to the menu bar
    /// *before* the window, and a claimed event never reaches `onKeyPress`, so
    /// there is still exactly one fire; what this adds is a path when the menu
    /// does not claim it. That case is real: measured in the acceptance run,
    /// `NSMenu` matches these items only against a **lowercase**
    /// `charactersIgnoringModifiers`, so a `⇧Z` reported as "Z" is not claimed
    /// by the menu at all. `⇧Z` is menu-only otherwise, and an unreachable fine
    /// nudge is precisely the silent degradation the spec forbids.
    ///
    /// `⇧←`/`⇧→` are **not** a fine nudge: on the arrows ⇧ extends the
    /// selection (spec §6.2 records why the two clusters differ), and as of
    /// Task 18 that action exists — it had been documented and unimplemented
    /// since the design was approved, so the two chords fell through to
    /// nothing at all.
    private func handleNavigation(_ character: String, press: KeyPress) -> Bool {
        let option = press.modifiers.contains(.option)
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow, .rightArrow:
            let direction: NudgeDirection = press.key == .leftArrow ? .backward : .forward
            guard !shift else {
                model.extendSelection(direction)
                return true
            }
            model.nudge(option ? .coarse : .normal, direction: direction)
            return true
        default:
            break
        }
        guard character == "z" || character == "x" else { return false }
        // ⌥ before ⇧: the two are separate tiers, and holding both is a typo
        // rather than a fourth tier.
        let tier: NudgeTier = option ? .coarse : (shift ? .fine : .normal)
        model.nudge(tier, direction: character == "z" ? .backward : .forward)
        return true
    }

    private func handleView(_ character: String, press: KeyPress) -> Bool {
        // ⌥E is the engine toggle, not a zoom — checked before the bare `e`.
        guard !(character == "e" && press.modifiers.contains(.option)) else { return false }
        switch character {
        case "e": model.zoomOut()
        case "r": model.zoomIn()
        default: return false
        }
        return true
    }

    private func handleSpeed(_ character: String, press: KeyPress) -> Bool {
        let fine = press.modifiers.contains(.shift)
        switch character {
        case "q": model.slower(fine: fine)
        case "w": model.faster(fine: fine)
        case "e" where press.modifiers.contains(.option): model.toggleStretchEngine()
        case "1", "2", "3", "4":
            guard let index = Int(character) else { return false }
            model.setSpeedPreset(SpeedStepping.presets[index - 1])
        default: return false
        }
        return true
    }

    private func handleLoop(_ character: String) -> Bool {
        switch character {
        case "a": model.setLoopIn()
        case "s": model.setLoopOut()
        case "d": model.toggleLoop()
        case "f": model.restartLoop()
        case "g": model.loopFromSelection()
        default: return false
        }
        return true
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
