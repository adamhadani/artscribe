import Playback
import SwiftUI

/// The **Playback** menu, whose only content today is output-device selection.
///
/// There is no stock Apple picker for audio output devices on macOS, so the
/// idiomatic shape is a menu of radio-style items — which is what this is: a
/// real menu-bar menu wired to the real HAL, not a bespoke panel.
public struct PlaybackCommands: Commands {
    private let devices: OutputDeviceController

    public init(devices: OutputDeviceController) {
        self.devices = devices
    }

    public var body: some Commands {
        CommandMenu("Playback") {
            // The dynamic part lives in a `View`, not directly in this
            // `Commands` body: a `Commands` body is not re-evaluated when an
            // `@Observable` model changes (see `ViewerCommands`), but a `View`
            // nested inside one tracks its own observation and so updates while
            // the menu is open — which is what "the menu must update live when a
            // device is plugged in" requires.
            OutputDeviceMenu(devices: devices)
        }
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
        // visible. The transport bar is the eventual home for this (Task 11);
        // until it exists, the menu that caused it is the honest place for it.
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
