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

            if model.hasTrack {
                OverviewStripView(model: model)
                    .frame(height: 58)
                TimeRulerView(model: model)
                WaveformLanesView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView()
            }

            StatusBarView(model: model)
        }
        .background(Palette.of(appearance).background.color())
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
            model.open(url: url)
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
    /// menu bar, so anything carrying Command is passed straight through.
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
            || handleView(character, press: press)
            || handleSpeed(character, press: press)
            || handleLoop(character)
        return handled ? .handled : .ignored
    }

    private func handleTransport(_ press: KeyPress) -> Bool {
        switch press.key {
        case .space: model.togglePlayPause()
        case .return: model.playFromStart()
        case .escape: model.clearSelection()
        default: return false
        }
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
    /// `⇧←`/`⇧→` are deliberately left alone. On the arrows ⇧ extends the
    /// selection (spec §6.2 records why the two clusters differ), so a fine
    /// nudge there would take a binding that belongs to something else.
    private func handleNavigation(_ character: String, press: KeyPress) -> Bool {
        let option = press.modifiers.contains(.option)
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow, .rightArrow:
            guard !shift else { return false }
            model.nudge(
                option ? .coarse : .normal,
                direction: press.key == .leftArrow ? .backward : .forward)
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
