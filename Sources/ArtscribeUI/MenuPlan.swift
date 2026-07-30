/// One line of a menu.
public enum MenuEntry: Hashable, Sendable {
    case action(ActionID)
    case separator
    /// A submenu whose contents are a live list rather than a set of actions:
    /// **Open Recent** (the files you opened), **Output Device** (the devices
    /// attached right now) and **Developer** (which is not shipped to users and
    /// so must not appear in the shortcut reference).
    ///
    /// These are the declared exception to "no menu item exists outside the
    /// catalog". Their items are data — a file name, a device name — not
    /// commands with identities, so there is nothing for a catalog row to say
    /// about them and nothing for a shortcut to be bound to.
    case dynamicSubmenu(DynamicSubmenu)
}

public enum DynamicSubmenu: String, Hashable, Sendable, CaseIterable {
    case openRecent
    case outputDevice
    /// Developer-only controls (engine selection). Present in the plan always,
    /// rendered only when `DeveloperMenu.isEnabled`.
    case developer
}

/// **The shape of the menu bar**, as data.
///
/// The menu builders do not list their own items; they render this. That is
/// what makes the drift guard in `ActionCatalogTests` mean something: a menu
/// item cannot exist without a `MenuEntry`, a `MenuEntry` cannot name an action
/// that is not in `ActionCatalog`, and a catalog action cannot be placed in two
/// menus. Before this task each menu wrote its own titles and its own key
/// equivalents, and a shortcut changed in one place stayed stale in the other
/// two.
public enum MenuPlan {
    public static func entries(for section: MenuSection) -> [MenuEntry] {
        switch section {
        case .fileOpen: return fileOpen
        case .fileSave: return fileSave
        case .edit: return edit
        case .view: return view
        case .playback: return playback
        case .loop: return loop
        }
    }

    /// Every action any menu places, with the section that places it.
    public static var placements: [(id: ActionID, section: MenuSection)] {
        MenuSection.allCases.flatMap { section in
            entries(for: section).compactMap { entry in
                guard case .action(let id) = entry else { return nil }
                return (id, section)
            }
        }
    }

    static let fileOpen: [MenuEntry] = [
        .action(.fileOpen),
        .dynamicSubmenu(.openRecent)
    ]

    /// The standard `.saveItem` group, so these land under Open Recent with the
    /// separator the system draws and ⌘S / ⇧⌘S are the system's own shortcuts.
    static let fileSave: [MenuEntry] = [
        .action(.fileSave),
        .action(.fileSaveAs)
    ]

    /// The standard pasteboard group, **replaced** rather than appended to:
    /// appending left the menu with two Select All items, and it was the
    /// system's — disabled, since nothing here implements `selectAll:` — that
    /// kept ⌘A.
    static let edit: [MenuEntry] = [
        .action(.editCut),
        .action(.editCopy),
        .action(.editPaste),
        .separator,
        .action(.selectionSelectAll),
        .action(.selectionClear),
        .separator,
        .action(.selectionExtendLeft),
        .action(.selectionExtendRight),
        .separator,
        .action(.selectionMoveLeft),
        .action(.selectionMoveRight),
        .action(.selectionMoveLeftFar),
        .action(.selectionMoveRightFar)
    ]

    /// Into the *standard* View menu (`CommandGroup(after: .toolbar)`) rather
    /// than a second one of our own, which would sit beside it in the menu bar.
    static let view: [MenuEntry] = [
        .action(.zoomFit),
        .action(.zoomToSelection),
        .separator,
        .action(.zoomIn),
        .action(.zoomOut),
        .action(.viewScrollLeft),
        .action(.viewScrollRight),
        .separator,
        // Above the two window items rather than with them: this changes what
        // the waveform shows, like the zoom items it follows, while Practice and
        // Keyboard Shortcuts open windows.
        .action(.viewTrackMarksToggle),
        .separator,
        .action(.practiceShow),
        .action(.helpShortcuts)
    ]

    static let playback: [MenuEntry] = [
        .action(.transportPlayPause),
        .action(.transportStop),
        .action(.transportReturnToStart),
        .action(.transportPrerollToggle),
        .separator,
        .action(.nudgeBack),
        .action(.nudgeForward),
        .action(.nudgeBackFine),
        .action(.nudgeForwardFine),
        .action(.nudgeBackCoarse),
        .action(.nudgeForwardCoarse),
        .separator,
        .action(.speedUp),
        .action(.speedDown),
        .action(.speedUpFine),
        .action(.speedDownFine),
        .separator,
        .action(.speedPreset100),
        .action(.speedPreset75),
        .action(.speedPreset50),
        .action(.speedPreset33),
        .separator,
        // Its own group: pitch is not a speed setting, and the separator is what
        // says so in a menu that would otherwise imply they are one control.
        .action(.pitchDown),
        .action(.pitchUp),
        .action(.pitchDownFine),
        .action(.pitchUpFine),
        .action(.pitchReset),
        .separator,
        .action(.volumeUp),
        .action(.volumeDown),
        .action(.volumeUpFine),
        .action(.volumeDownFine),
        .action(.volumeMute),
        .separator,
        .dynamicSubmenu(.outputDevice),
        // Renders to nothing unless `ARTSCRIBE_DEV_MENU` is set. Listed here
        // unconditionally so this plan stays the same shape in every run — see
        // `DeveloperEngineMenu`.
        .dynamicSubmenu(.developer)
    ]

    static let loop: [MenuEntry] = [
        .action(.loopSetIn),
        .action(.loopSetOut),
        .action(.loopToggle),
        .action(.loopRestart),
        .separator,
        .action(.loopFromSelection),
        .action(.loopClear),
        .separator,
        // Task 21. Its own block: it is the only item here that runs over time
        // rather than editing the region, and it is set up in a window of its
        // own (View ▸ Practice).
        .action(.practiceRampToggle),
        .separator,
        .action(.loopMoveInLeft),
        .action(.loopMoveInRight),
        .action(.loopMoveInLeftFar),
        .action(.loopMoveInRightFar),
        .separator,
        .action(.loopMoveOutLeft),
        .action(.loopMoveOutRight),
        .action(.loopMoveOutLeftFar),
        .action(.loopMoveOutRightFar),
        .separator,
        .action(.loopMoveLeft),
        .action(.loopMoveRight),
        .action(.loopMoveLeftFar),
        .action(.loopMoveRightFar)
    ]
}
