import ArtscribeKit
import Playback
import SwiftUI

/// The **Playback** menu: transport, speed, loop, and output device.
///
/// It exists because a help sheet is not enough — these belong in the menu where
/// macOS users look for them, and where their key equivalents are legible without
/// having to be memorised first.
///
/// Everything dynamic lives in a nested `View`, never directly in this `Commands`
/// body. A `Commands` body is **not** re-evaluated when an `@Observable` model
/// changes, so `.disabled(…)` written here goes stale — ⌘9 measurably stopped
/// firing in Task 10 because the item was still marked disabled from launch. A
/// `View` nested inside a `CommandMenu` tracks its own observation and updates
/// while the menu is open, which is what makes the greying-out below real.
public struct PlaybackCommands: Commands {
    private let model: ViewerModel
    private let devices: OutputDeviceController

    public init(model: ViewerModel, devices: OutputDeviceController) {
        self.model = model
        self.devices = devices
    }

    public var body: some Commands {
        CommandMenu("Playback") {
            PlaybackMenu(model: model)
            Divider()
            OutputDeviceMenu(devices: devices)
        }
    }
}

/// The transport, speed and loop items.
///
/// **On key equivalents.** Only the modifier-bearing shortcuts (`⇧Q`, `⇧W`, `⌥E`,
/// and the navigation cluster's `⇧Z`, `⇧X`, `⌥Z`, `⌥X`) are declared as real key
/// equivalents. The unmodified cluster — `Space`,
/// `Return`, `Q`, `W`, `Z`, `X`, `1`–`4`, `A`–`G` — is shown in the titles instead and
/// handled by `DocumentView`, following the convention `ViewerCommands` set: a
/// plain-letter menu key equivalent is claimed application-wide and flashes the
/// menu bar on every keystroke, which during a held `Q`/`W` speed sweep is a
/// strobe. Splitting it this way also means no action can ever fire twice: the
/// menu consumes the modified chords before the window sees them, and the window
/// only ever sees the ones the menu did not claim.
struct PlaybackMenu: View {
    let model: ViewerModel

    var body: some View {
        Group {
            Button(model.isPlaying ? "Pause  (Space)" : "Play  (Space)") {
                model.togglePlayPause()
            }
            Button("Stop") { model.pause() }
                .disabled(!model.isPlaying)
            Button("Play from Start  (Return)") { model.playFromStart() }

            Divider()

            navigationItems

            Divider()

            Button("Faster  (W)") { model.faster(fine: false) }
            Button("Slower  (Q)") { model.slower(fine: false) }
            Button("Faster (Fine)") { model.faster(fine: true) }
                .keyboardShortcut("W", modifiers: .shift)
            Button("Slower (Fine)") { model.slower(fine: true) }
                .keyboardShortcut("Q", modifiers: .shift)

            Divider()

            speedPresets
            Button(engineTitle) { model.toggleStretchEngine() }
                .keyboardShortcut("e", modifiers: .option)

            Divider()

            volumeItems

            Divider()

            loopItems
        }
        // One `.disabled` on the group, evaluated inside a `View` body so it
        // actually tracks `hasTrack`. Every action underneath is a guarded no-op
        // as well, so this is belt and braces rather than the only defence.
        .disabled(!model.hasTrack)
    }

    /// Spec §6.2's three nudge tiers, with their live amounts in the titles.
    ///
    /// The amounts are in the titles rather than only in Settings for two
    /// reasons: the menu is where you look to find out what a key does, and it
    /// is the only place a Settings change is visible without pressing the key
    /// and guessing. They track `model.nudgeAmounts` because this is a `View`.
    ///
    /// The same key-equivalent split as the rest of the menu: `⇧Z`/`⇧X` and
    /// `⌥Z`/`⌥X` are real menu key equivalents, while the unmodified `Z`/`X` and
    /// the arrows are shown in the titles and handled by `DocumentView`. `⌥←` and
    /// `⌥→` are named as alternates because an `NSMenuItem` carries exactly one
    /// key equivalent; the window handles those two.
    @ViewBuilder
    private var navigationItems: some View {
        let fine = NudgeAmounts.label(seconds: model.nudgeAmounts[.fine])
        let normal = NudgeAmounts.label(seconds: model.nudgeAmounts[.normal])
        let coarse = NudgeAmounts.label(seconds: model.nudgeAmounts[.coarse])

        Button("Nudge Back \(normal)  (Z / ←)") { model.nudge(.normal, direction: .backward) }
        Button("Nudge Forward \(normal)  (X / →)") { model.nudge(.normal, direction: .forward) }
        Button("Nudge Back (Fine) \(fine)") { model.nudge(.fine, direction: .backward) }
            .keyboardShortcut("Z", modifiers: .shift)
        Button("Nudge Forward (Fine) \(fine)") { model.nudge(.fine, direction: .forward) }
            .keyboardShortcut("X", modifiers: .shift)
        Button("Rewind \(coarse)  (also ⌥←)") { model.nudge(.coarse, direction: .backward) }
            .keyboardShortcut("z", modifiers: .option)
        Button("Skip \(coarse)  (also ⌥→)") { model.nudge(.coarse, direction: .forward) }
            .keyboardShortcut("x", modifiers: .option)
    }

    @ViewBuilder
    private var speedPresets: some View {
        // `Toggle`, not `Button`: a checkmark is how macOS shows which of a set
        // of mutually exclusive values is active, and it updates live because
        // this is a `View`.
        // The status bar bolds an altered speed; the matching emphasis here was
        // tried and does not exist to be had. A SwiftUI menu item on macOS
        // renders a plain title: `Text(…).fontWeight(.bold)` inside the label
        // produced an `NSMenuItem` whose `attributedTitle` was still nil, so
        // nothing reached the screen. The checkmark carries the state instead.
        ForEach(Array(SpeedStepping.presets.enumerated()), id: \.offset) { index, preset in
            Toggle(
                "\(SpeedStepping.percentLabel(preset)) Speed  (\(index + 1))",
                isOn: Binding(
                    get: { SpeedStepping.isActive(preset: preset, ratio: model.speed.ratio) },
                    set: { isOn in if isOn { model.setSpeedPreset(preset) } }))
        }
    }

    /// Names the engine you would switch *to*, and says which one is running now,
    /// because "Studio / Fast" alone leaves you guessing which half is current.
    private var engineTitle: String {
        model.speed.engine == .studio
            ? "Use Fast Engine  (now: Studio)" : "Use Studio Engine  (now: Fast)"
    }

    /// `↑`/`↓` are shown in the titles and `⇧↑`/`⇧↓` are real key equivalents,
    /// the same split as the speed cluster and for the same reason.
    @ViewBuilder
    private var volumeItems: some View {
        Button("Volume Up  (↑)") { model.volumeUp(fine: false) }
        Button("Volume Down  (↓)") { model.volumeDown(fine: false) }
        Button("Volume Up (Fine)") { model.volumeUp(fine: true) }
            .keyboardShortcut(.upArrow, modifiers: .shift)
        Button("Volume Down (Fine)") { model.volumeDown(fine: true) }
            .keyboardShortcut(.downArrow, modifiers: .shift)
        Toggle(
            "Mute  (M)",
            isOn: Binding(
                get: { model.volume.isMuted },
                set: { isOn in if isOn != model.volume.isMuted { model.toggleMute() } })
        )
    }

    @ViewBuilder
    private var loopItems: some View {
        Button("Set Loop In  (A)") { model.setLoopIn() }
        Button("Set Loop Out  (S)") { model.setLoopOut() }
        Toggle(
            "Loop  (D)",
            isOn: Binding(
                get: { model.loop.isEnabled },
                // Compared rather than blindly toggled: a `Binding` set to the
                // value it already holds must be a no-op, or the item inverts
                // the state it was asked to confirm.
                set: { isOn in if isOn != model.loop.isEnabled { model.toggleLoop() } })
        )
        .disabled(model.loop.range.isEmpty && !model.loop.isEnabled)
        Button("Restart Loop  (F)") { model.restartLoop() }
            .disabled(model.loop.range.isEmpty)
        Button("Selection → Loop  (G)") { model.loopFromSelection() }
            .disabled(model.selection.isEmpty)
        Button("Clear Loop") { model.clearLoop() }
            .disabled(model.loop.range.isEmpty)
    }
}

struct OutputDeviceMenu: View {
    let devices: OutputDeviceController

    var body: some View {
        Menu("Output Device") {
            Toggle(systemDefaultLabel, isOn: selection(for: .systemDefault))
            Divider()
            ForEach(devices.devices) { device in
                Toggle(label(for: device), isOn: selection(for: .device(device.id)))
            }
        }
        // Spec §8: a device disappearing, or a switch being refused, must be
        // visible. It is now also surfaced as a banner in the window while a
        // track is loaded; this stays for the case where none is.
        if let notice = devices.notice {
            Divider()
            Text(notice)
        }
    }

    private var systemDefaultLabel: String {
        guard let name = devices.systemDefaultName else { return "System Default" }
        return "System Default (\(name))"
    }

    private func label(for device: AudioDevice) -> String {
        guard device.nominalSampleRate > 0 else { return device.name }
        return "\(device.name) — \(Int(device.nominalSampleRate)) Hz"
    }

    /// Radio behaviour: turning an item on selects it; turning the current one
    /// off would leave nothing selected, so it is ignored.
    private func selection(for target: OutputDeviceSelection) -> Binding<Bool> {
        Binding(
            get: { devices.selection == target },
            set: { isOn in if isOn { devices.select(target) } })
    }
}
