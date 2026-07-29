import Playback

/// Everything an action might need to reach.
///
/// One value rather than four initialiser parameters threaded through five
/// `Commands` structs. The app shell builds it once and hands the same one to
/// every menu and to the window, which is also what makes "the menu and the
/// keyboard run the same code" true rather than aspirational.
@MainActor
public struct MenuContext {
    public let model: ViewerModel
    public let recents: RecentFiles
    public let devices: OutputDeviceController
    /// The shortcut window's state, and the one way to open it. Both routes to
    /// it — the View menu item and `⌘/` — arrive through `ActionInvoker`, so it
    /// has to be reachable from here.
    public let shortcuts: ShortcutWindowController
    /// The Practice window's opener, here for exactly the same reason as
    /// `shortcuts`: `View ▸ Practice` and `⌘P` both arrive through
    /// `ActionInvoker`, which is not a view and so cannot reach `openWindow`.
    public let practice: PracticeWindowController

    public init(
        model: ViewerModel,
        recents: RecentFiles,
        devices: OutputDeviceController,
        shortcuts: ShortcutWindowController,
        practice: PracticeWindowController
    ) {
        self.model = model
        self.recents = recents
        self.devices = devices
        self.shortcuts = shortcuts
        self.practice = practice
    }
}

/// The one implementation of every action, reached by `ActionID`.
///
/// Spec §6.1: *"Menus, keyboard, and later MIDI all dispatch the same
/// identifiers."* A menu item, a key press and — later — a MIDI note all arrive
/// here, so an action cannot behave one way from the menu and another from the
/// keyboard.
///
/// **A dictionary rather than a `switch`.** A `switch` would give compile-time
/// exhaustiveness, which is what one would want; a sixty-case one also scores
/// sixty on SwiftLint's cyclomatic complexity, which is a build error here.
/// `everyActionIsInvocable` buys the exhaustiveness back at test time instead.
@MainActor
public enum ActionInvoker {

    public static func perform(_ id: ActionID, _ context: MenuContext) {
        table[id]?(context)
    }

    /// The actions this app does not implement, and why.
    ///
    /// Checked by `everyActionIsInvocable` rather than allowed to be a missing
    /// key: a lookup that quietly finds nothing would turn a forgotten
    /// implementation into a menu item that does nothing when clicked.
    public static let handledElsewhere: Set<ActionID> = [
        // SwiftUI's `Settings` scene owns both the menu item and ⌘,. The
        // catalog carries it so the shortcut reference lists it.
        .appSettings
    ]

    /// The speed presets, in `SpeedStepping.presets` order. The pairing is
    /// asserted rather than assumed — see `presetsLineUpWithTheirRatios`.
    static let presetIDs: [ActionID] = [
        .speedPreset100, .speedPreset75, .speedPreset50, .speedPreset33
    ]

    static func presetRatio(_ id: ActionID) -> Double? {
        guard let index = presetIDs.firstIndex(of: id) else { return nil }
        return SpeedStepping.presets[index]
    }

    /// Whether a `.toggle` action's checkmark is on. `nil` for a button.
    public static func isOn(_ id: ActionID, _ context: MenuContext) -> Bool? {
        let model = context.model
        switch id {
        case .loopToggle: return model.loop.isEnabled
        case .volumeMute: return model.volume.isMuted
        case .transportPrerollToggle: return model.prefs.prerollEnabled
        // Checked while a ramp is *running*. A completed one is unchecked, which
        // is the right reading: the ramp is over, and clicking the item starts a
        // fresh one from the top.
        case .practiceRampToggle: return model.ramp.isRunning
        default:
            guard let ratio = presetRatio(id) else { return nil }
            return SpeedStepping.isActive(preset: ratio, ratio: model.speed.ratio)
        }
    }

    /// What a checkmark being clicked means.
    ///
    /// Compared rather than blindly toggled: a `Binding` set to the value it
    /// already holds must be a no-op, or the item inverts the state it was
    /// asked to confirm. Turning a radio item *off* would leave nothing
    /// selected, so it is ignored.
    public static func setOn(_ id: ActionID, _ wanted: Bool, _ context: MenuContext) {
        guard wanted != isOn(id, context) else { return }
        guard wanted || presetRatio(id) == nil else { return }
        perform(id, context)
    }

    static let table: [ActionID: @MainActor (MenuContext) -> Void] =
        transportActions
        .merging(loopActions) { first, _ in first }
        .merging(speedActions) { first, _ in first }
        .merging(selectionActions) { first, _ in first }
        .merging(viewActions) { first, _ in first }
        .merging(applicationActions) { first, _ in first }
}
