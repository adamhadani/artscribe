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
/// **On key equivalents.** Every item carries a real one, including the
/// unmodified cluster — `Space`, `Return`, `Q`, `W`, `Z`, `X`, `1`–`4`, `A`–`G`.
/// `.keyboardShortcut(_:modifiers: [])` is the documented way to declare one
/// without ⌘, which SwiftUI would otherwise add.
///
/// This replaces a split in which the plain keys were spelled into the titles
/// (`"Play  (Space)"`) and handled only by `DocumentView`. The reason recorded
/// for that split was that a plain-letter menu key equivalent "flashes the menu
/// bar on every keystroke, which during a held `Q`/`W` speed sweep is a strobe".
/// Task 15 measured it in the running app (see `AcceptanceShortcutChecks`): a
/// plain letter behaves exactly as `⇧W` and `⌥E` — which have been real key
/// equivalents since Task 11 — already did, and neither highlights a menu nor
/// begins menu tracking. The claim did not reproduce, so the convention is now
/// uniform.
///
/// **Nothing fires twice.** AppKit offers a key event to the menu bar *before*
/// the window, and a claimed event never reaches `DocumentView.onKeyPress`. The
/// window keeps its handlers as the path for whatever the menu does not claim —
/// a disabled item claims nothing, and `NSMenu` matches a shifted letter only
/// against a lowercase `charactersIgnoringModifiers`, so `⇧Z` reported as "Z"
/// reaches the window instead. Single-fire is asserted per key in the
/// acceptance run rather than assumed.
///
/// **A text field is why enablement matters.** A key equivalent is offered
/// before the first responder sees the event, so a live plain `Q` would step the
/// speed instead of typing into Settings' numeric fields. `KeyWindowTracker`
/// disables this whole menu whenever the document window is not the key window,
/// which is what keeps that from happening; the acceptance run types into a real
/// text field to check it.
struct PlaybackMenu: View {
    let model: ViewerModel
    /// Read inside this `View` body, so the items re-evaluate when the key
    /// window changes — a `Commands` body would not (see `ViewerCommands`).
    private let keyWindow = KeyWindowTracker.shared

    var body: some View {
        Group {
            Button(model.isPlaying ? "Pause" : "Play") {
                model.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("Stop") { model.pause() }
                .disabled(!model.isPlaying)
            Button("Play from Start") { model.playFromStart() }
                .keyboardShortcut(.return, modifiers: [])

            Divider()

            navigationItems

            Divider()

            Button("Faster") { model.faster(fine: false) }
                .keyboardShortcut("w", modifiers: [])
            Button("Slower") { model.slower(fine: false) }
                .keyboardShortcut("q", modifiers: [])
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
        //
        // `documentIsKey` is the second half, and it is what makes the plain
        // letters safe: a menu key equivalent is offered before the first
        // responder, so with Settings open a live `Q` would step the speed
        // instead of typing a digit into a nudge field. A disabled item claims
        // nothing, so the field gets the keystroke.
        .disabled(!model.hasTrack || !keyWindow.documentIsKey)
    }

    /// Spec §6.2's three nudge tiers, with their live amounts in the titles.
    ///
    /// The amounts are in the titles rather than only in Settings for two
    /// reasons: the menu is where you look to find out what a key does, and it
    /// is the only place a Settings change is visible without pressing the key
    /// and guessing. They track `model.nudgeAmounts` because this is a `View`.
    ///
    /// Each tier now carries its own real key equivalent, `Z`/`X` included. An
    /// `NSMenuItem` holds exactly one, so the arrow alternates (`←`/`→` and
    /// `⌥←`/`⌥→`) are not named here — spelling a second chord into the title is
    /// precisely the mixed convention Task 15 removed, and Settings ▸ Playback
    /// already lists every key each tier answers to, beside the amount it moves.
    /// `DocumentView` still handles the arrows.
    @ViewBuilder
    private var navigationItems: some View {
        let fine = NudgeAmounts.label(seconds: model.nudgeAmounts[.fine])
        let normal = NudgeAmounts.label(seconds: model.nudgeAmounts[.normal])
        let coarse = NudgeAmounts.label(seconds: model.nudgeAmounts[.coarse])

        Button("Nudge Back \(normal)") { model.nudge(.normal, direction: .backward) }
            .keyboardShortcut("z", modifiers: [])
        Button("Nudge Forward \(normal)") { model.nudge(.normal, direction: .forward) }
            .keyboardShortcut("x", modifiers: [])
        Button("Nudge Back (Fine) \(fine)") { model.nudge(.fine, direction: .backward) }
            .keyboardShortcut("Z", modifiers: .shift)
        Button("Nudge Forward (Fine) \(fine)") { model.nudge(.fine, direction: .forward) }
            .keyboardShortcut("X", modifiers: .shift)
        Button("Rewind \(coarse)") { model.nudge(.coarse, direction: .backward) }
            .keyboardShortcut("z", modifiers: .option)
        Button("Skip \(coarse)") { model.nudge(.coarse, direction: .forward) }
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
                "\(SpeedStepping.percentLabel(preset)) Speed",
                isOn: Binding(
                    get: { SpeedStepping.isActive(preset: preset, ratio: model.speed.ratio) },
                    set: { isOn in if isOn { model.setSpeedPreset(preset) } })
            )
            .keyboardShortcut(Self.presetKey(index), modifiers: [])
        }
    }

    /// `1`–`4`, as a `KeyEquivalent`. Derived from the index rather than written
    /// out, so a fifth preset cannot arrive without a key.
    private static func presetKey(_ index: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(index + 1)"))
    }

    /// Names the engine you would switch *to*, and says which one is running now,
    /// because "Studio / Fast" alone leaves you guessing which half is current.
    ///
    /// Set off with a dash rather than the old `"  (now: Studio)"`. The state is
    /// still there; what went is the double-space-parenthesis, which is now
    /// reserved for nothing at all — "no menu title contains `  (`" is the
    /// one-line rule the acceptance run uses to prove no shortcut is spelled
    /// into a title, and it is only worth having if it has no exceptions.
    private var engineTitle: String {
        model.speed.engine == .studio
            ? "Use Fast Engine — now: Studio" : "Use Studio Engine — now: Fast"
    }

    @ViewBuilder
    private var volumeItems: some View {
        Button("Volume Up") { model.volumeUp(fine: false) }
            .keyboardShortcut(.upArrow, modifiers: [])
        Button("Volume Down") { model.volumeDown(fine: false) }
            .keyboardShortcut(.downArrow, modifiers: [])
        Button("Volume Up (Fine)") { model.volumeUp(fine: true) }
            .keyboardShortcut(.upArrow, modifiers: .shift)
        Button("Volume Down (Fine)") { model.volumeDown(fine: true) }
            .keyboardShortcut(.downArrow, modifiers: .shift)
        Toggle(
            "Mute",
            isOn: Binding(
                get: { model.volume.isMuted },
                set: { isOn in if isOn != model.volume.isMuted { model.toggleMute() } })
        )
        .keyboardShortcut("m", modifiers: [])
    }

    @ViewBuilder
    private var loopItems: some View {
        Button("Set Loop In") { model.setLoopIn() }
            .keyboardShortcut("a", modifiers: [])
        Button("Set Loop Out") { model.setLoopOut() }
            .keyboardShortcut("s", modifiers: [])
        Toggle(
            "Loop",
            isOn: Binding(
                get: { model.loop.isEnabled },
                // Compared rather than blindly toggled: a `Binding` set to the
                // value it already holds must be a no-op, or the item inverts
                // the state it was asked to confirm.
                set: { isOn in if isOn != model.loop.isEnabled { model.toggleLoop() } })
        )
        .keyboardShortcut("d", modifiers: [])
        .disabled(model.loop.range.isEmpty && !model.loop.isEnabled)
        Button("Restart Loop") { model.restartLoop() }
            .keyboardShortcut("f", modifiers: [])
            .disabled(model.loop.range.isEmpty)
        Button("Selection → Loop") { model.loopFromSelection() }
            .keyboardShortcut("g", modifiers: [])
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
