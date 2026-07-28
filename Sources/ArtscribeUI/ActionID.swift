/// Every command Artscribe can be asked to perform, as a stable identifier.
///
/// Spec §6.1: *"Every action has a stable `ActionID`. Menus, keyboard, and later
/// MIDI all dispatch the same identifiers, and the help sheet is rendered from
/// the live binding table so it cannot drift."* The raw values are the spec
/// §6.2 identifiers verbatim, so the table in the design document and this enum
/// can be diffed by eye.
///
/// This is the foundation spec §6.3's rebindable `BindingTable` needs — the
/// stable left-hand side a persisted binding points at. Rebinding itself is
/// deliberately **not** built yet.
public enum ActionID: String, CaseIterable, Hashable, Sendable {
    // Transport
    case transportPlayPause = "transport.playPause"
    case transportStop = "transport.stop"
    case transportReturnToStart = "transport.returnToStart"

    // Navigation — the three nudge tiers
    case nudgeBack = "transport.nudge.back"
    case nudgeForward = "transport.nudge.forward"
    case nudgeBackFine = "transport.nudge.back.fine"
    case nudgeForwardFine = "transport.nudge.forward.fine"
    case nudgeBackCoarse = "transport.nudge.back.coarse"
    case nudgeForwardCoarse = "transport.nudge.forward.coarse"

    // Loop
    case loopSetIn = "loop.setIn"
    case loopSetOut = "loop.setOut"
    case loopToggle = "loop.toggle"
    case loopRestart = "loop.restart"
    case loopFromSelection = "loop.fromSelection"
    case loopClear = "loop.clear"
    case loopMoveInLeft = "loop.moveIn.left"
    case loopMoveInRight = "loop.moveIn.right"
    case loopMoveInLeftFar = "loop.moveIn.left.far"
    case loopMoveInRightFar = "loop.moveIn.right.far"
    case loopMoveOutLeft = "loop.moveOut.left"
    case loopMoveOutRight = "loop.moveOut.right"
    case loopMoveOutLeftFar = "loop.moveOut.left.far"
    case loopMoveOutRightFar = "loop.moveOut.right.far"
    case loopMoveLeft = "loop.move.left"
    case loopMoveRight = "loop.move.right"
    case loopMoveLeftFar = "loop.move.left.far"
    case loopMoveRightFar = "loop.move.right.far"

    // Speed
    case speedDown = "speed.down"
    case speedUp = "speed.up"
    case speedDownFine = "speed.down.fine"
    case speedUpFine = "speed.up.fine"
    case speedPreset100 = "speed.preset.100"
    case speedPreset75 = "speed.preset.75"
    case speedPreset50 = "speed.preset.50"
    case speedPreset33 = "speed.preset.33"
    case speedEngineToggle = "speed.engineToggle"

    // Volume
    case volumeUp = "volume.up"
    case volumeDown = "volume.down"
    case volumeUpFine = "volume.up.fine"
    case volumeDownFine = "volume.down.fine"
    case volumeMute = "volume.mute"

    // Selection
    case selectionExtendLeft = "selection.extendLeft"
    case selectionExtendRight = "selection.extendRight"
    case selectionMoveLeft = "selection.moveLeft"
    case selectionMoveRight = "selection.moveRight"
    case selectionMoveLeftFar = "selection.moveLeft.far"
    case selectionMoveRightFar = "selection.moveRight.far"
    case selectionSelectAll = "selection.selectAll"
    case selectionClear = "selection.clear"

    // View
    case zoomIn = "zoom.in"
    case zoomOut = "zoom.out"
    case zoomFit = "zoom.fit"
    case zoomToSelection = "zoom.toSelection"
    case viewScrollLeft = "view.scrollLeft"
    case viewScrollRight = "view.scrollRight"
    case helpShortcuts = "help.shortcuts"

    // File and session
    case fileOpen = "file.open"
    case fileSave = "file.save"
    case fileSaveAs = "file.saveAs"

    // Application — the three pasteboard chords, and Settings
    case editCut = "edit.cut"
    case editCopy = "edit.copy"
    case editPaste = "edit.paste"
    case appSettings = "app.settings"
}

/// How the shortcut reference groups the catalog, and the order it groups it in.
///
/// Grouped by *what you are doing*, not by which menu the item happens to live
/// in: the reference is read while working, and nobody looking for "how do I
/// move the loop" thinks first about which menu bar title it sits under.
public enum ActionCategory: String, CaseIterable, Hashable, Sendable, Identifiable {
    case transport
    case navigation
    case loop
    case selection
    case speed
    case volume
    case view
    case file
    case application

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .transport: return "Transport"
        case .navigation: return "Navigation"
        case .loop: return "Loop"
        case .selection: return "Selection"
        case .speed: return "Speed"
        case .volume: return "Volume"
        case .view: return "View"
        case .file: return "File & Session"
        case .application: return "Application"
        }
    }
}

/// Which menu-bar group an action is placed in.
///
/// A *group*, not a menu title: File is assembled from two standard
/// `CommandGroup`s that SwiftUI keeps apart (Open above Open Recent, Save below
/// it), and an action has to name the one it belongs to for `MenuPlan` to be
/// able to describe the menu bar faithfully.
public enum MenuSection: String, CaseIterable, Hashable, Sendable {
    case fileOpen
    case fileSave
    case edit
    case view
    case playback
    case loop

    /// The menu-bar title this group appears under, for the reference and for
    /// the drift guard's failure messages.
    public var menuTitle: String {
        switch self {
        case .fileOpen, .fileSave: return "File"
        case .edit: return "Edit"
        case .view: return "View"
        case .playback: return "Playback"
        case .loop: return "Loop"
        }
    }
}
