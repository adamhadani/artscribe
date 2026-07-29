import Playback
import SwiftUI

/// The **Playback** menu: transport, navigation, speed, volume and output
/// device.
///
/// The loop items moved out to `LoopCommands` and the selection items to
/// `EditCommands` in Task 18. This menu had grown to 36 items and become the
/// place anything went that had nowhere else; what is left is one identity —
/// *what is playing, how fast, and where it comes out*.
///
/// It exists because a shortcut reference is not enough — these belong in the
/// menu where macOS users look for them, and where their key equivalents are
/// legible without having to be memorised first.
///
/// **On key equivalents.** Every item carries a real one, including the
/// unmodified cluster — `Space`, `Q`, `W`, `Z`, `X`, `1`–`4`. A plain-letter key
/// equivalent was once believed to flash the menu bar on every keystroke, which
/// during a held `Q`/`W` speed sweep would be a strobe; Task 15 measured it in
/// the running app and the claim did not reproduce, so the convention is
/// uniform.
///
/// **Nothing fires twice.** AppKit offers a key event to the menu bar *before*
/// the window, and a claimed event never reaches `DocumentView.onKeyPress`. The
/// window keeps `KeyBindings` as the path for whatever the menu does not claim
/// — a disabled item claims nothing, and `NSMenu` matches a shifted letter only
/// against a lowercase `charactersIgnoringModifiers`, so `⇧Z` reported as "Z"
/// reaches the window instead. Single-fire is asserted per key in the
/// acceptance run rather than assumed.
///
/// **A text field is why enablement matters.** A key equivalent is offered
/// before the first responder sees the event, so a live plain `Q` would step the
/// speed instead of typing into Settings' numeric fields. Every item's
/// enablement policy is on its catalog row and applied in `ActionMenuItem`,
/// which reads `KeyWindowTracker` inside a `View` body so it stays live.
public struct PlaybackCommands: Commands {
    private let context: MenuContext

    public init(context: MenuContext) {
        self.context = context
    }

    public var body: some Commands {
        CommandMenu("Playback") {
            MenuItems(section: .playback, context: context)
            // Not a menu item: a device notice with no track loaded has nowhere
            // else to go, since the in-window banner needs a window with
            // something in it.
            DeviceNoticeItem(devices: context.devices)
        }
    }
}

/// The **Output Device** submenu. Its items are the devices attached right now,
/// which is why `MenuPlan` calls it a `dynamicSubmenu`: a device is data, not
/// an action with an identity a shortcut could be bound to.
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

/// Spec §8: a device disappearing, or a switch being refused, must be visible.
/// It is also surfaced as a banner in the window while a track is loaded; this
/// is the case where none is.
struct DeviceNoticeItem: View {
    let devices: OutputDeviceController

    var body: some View {
        if let notice = devices.notice {
            Divider()
            Text(notice)
        }
    }
}
