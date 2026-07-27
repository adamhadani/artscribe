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
    /// preference. Reading it here rather than the preference itself is what
    /// makes `System` follow macOS with no notification plumbing: SwiftUI
    /// republishes this environment value when the system appearance changes,
    /// and `preferredColorScheme` overrides it when the user has chosen.
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
    /// a strobe. Only the modifier-bearing shortcuts (`⇧Q`, `⇧W`, `⌥E`) are real
    /// menu key equivalents, and those the menu consumes before this ever sees
    /// them — so no action can fire twice.
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

    private func handleView(_ character: String, press: KeyPress) -> Bool {
        // ⌥E is the engine toggle, not a zoom — checked before the bare `e`.
        guard !(character == "e" && press.modifiers.contains(.option)) else { return false }
        switch character {
        case "e": model.zoomOut()
        case "r": model.zoomIn()
        case "z": model.scrollLeft()
        case "x": model.scrollRight()
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
