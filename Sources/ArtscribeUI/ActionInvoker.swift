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
    /// The About panel's opener, here for the third time and the same reason:
    /// **Artscripture ▸ About Artscripture**, **Help ▸ About Artscripture** and the
    /// resting screen's button on iPad all arrive through `ActionInvoker`.
    public let about: AboutWindowController
    /// The Settings sheet's opener. **iPad only in effect** — macOS's `Settings`
    /// scene owns `⌘,` and the menu item, so nothing calls this there. Carried
    /// unconditionally so `MenuContext` is one shape on both platforms; see
    /// `SettingsWindowController` for why it is inert rather than absent.
    public let settings: SettingsWindowController
    /// The first-run sheet's state. Carried here so `DocumentView` can present
    /// it and the About panel can ask for it again — the two ends of the HIG's
    /// "never twice, but easy to find later".
    public let welcome: WelcomeState
    /// The theme, carried here for the same reason the controllers are: on iPad
    /// the auxiliary windows are sheets presented from `DocumentView`, which
    /// therefore has to be able to build them — and they take a theme. On macOS
    /// the scenes still pass it directly.
    public let theme: ThemeController

    public init(
        model: ViewerModel,
        recents: RecentFiles,
        devices: OutputDeviceController,
        shortcuts: ShortcutWindowController,
        practice: PracticeWindowController,
        about: AboutWindowController,
        settings: SettingsWindowController,
        welcome: WelcomeState,
        theme: ThemeController
    ) {
        self.model = model
        self.recents = recents
        self.devices = devices
        self.shortcuts = shortcuts
        self.practice = practice
        self.about = about
        self.settings = settings
        self.welcome = welcome
        self.theme = theme
    }

    #if !os(macOS)
    /// Whether any auxiliary sheet is up — and therefore whether the document
    /// has stopped being what the keyboard is aimed at.
    ///
    /// The iPad answer to what `KeyWindowTracker` answers on macOS. It is here,
    /// on the context, rather than inside the menu item because the *set* of
    /// auxiliary surfaces is a fact about the app, and a new sheet added to
    /// `DocumentView` without being added here would silently reintroduce the
    /// bug this fixes: plain-letter key equivalents firing while a text field
    /// has focus, so that typing `1` sets the speed instead of entering a digit.
    ///
    /// Deliberately **all four**, including About, which has no text fields at
    /// all. A sheet over the document is the keyboard's target whether or not it
    /// wants characters, and a uniform rule is one fewer thing to get wrong.
    public var anyAuxiliarySheetIsPresented: Bool {
        !SheetFocus.documentHasKeyboard(
            shortcutsPresented: shortcuts.windowState.isPresented,
            practicePresented: practice.windowState.isPresented,
            aboutPresented: about.windowState.isPresented,
            settingsPresented: settings.windowState.isPresented)
    }
    #endif
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
        case .viewTrackMarksToggle: return model.markers.isVisible
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
