import AppKit
import SwiftUI

/// The dispatch table itself, split from `ActionInvoker` for file length and
/// grouped the way the catalog is.
///
/// Every closure here is the *only* implementation of its action. Nothing else
/// in the app calls `model.nudge(…)` or `model.setLoopIn()` from a menu item or
/// a key handler.
extension ActionInvoker {

    static let transportActions: [ActionID: @MainActor (MenuContext) -> Void] = [
        .transportPlayPause: { $0.model.togglePlayPause() },
        .transportStop: { $0.model.pause() },
        .transportReturnToStart: { $0.model.playFromStart() },
        .nudgeBack: { $0.model.nudge(.normal, direction: .backward) },
        .nudgeForward: { $0.model.nudge(.normal, direction: .forward) },
        .nudgeBackFine: { $0.model.nudge(.fine, direction: .backward) },
        .nudgeForwardFine: { $0.model.nudge(.fine, direction: .forward) },
        .nudgeBackCoarse: { $0.model.nudge(.coarse, direction: .backward) },
        .nudgeForwardCoarse: { $0.model.nudge(.coarse, direction: .forward) },
        .volumeUp: { $0.model.volumeUp(fine: false) },
        .volumeDown: { $0.model.volumeDown(fine: false) },
        .volumeUpFine: { $0.model.volumeUp(fine: true) },
        .volumeDownFine: { $0.model.volumeDown(fine: true) },
        .volumeMute: { $0.model.toggleMute() }
    ]

    static let loopActions: [ActionID: @MainActor (MenuContext) -> Void] = [
        .loopSetIn: { $0.model.setLoopIn() },
        .loopSetOut: { $0.model.setLoopOut() },
        .loopToggle: { $0.model.toggleLoop() },
        .loopRestart: { $0.model.restartLoop() },
        .loopFromSelection: { $0.model.loopFromSelection() },
        .loopClear: { $0.model.clearLoop() },
        .loopMoveInLeft: loopMove(.inPoint, .gentle, .backward),
        .loopMoveInRight: loopMove(.inPoint, .gentle, .forward),
        .loopMoveInLeftFar: loopMove(.inPoint, .aggressive, .backward),
        .loopMoveInRightFar: loopMove(.inPoint, .aggressive, .forward),
        .loopMoveOutLeft: loopMove(.outPoint, .gentle, .backward),
        .loopMoveOutRight: loopMove(.outPoint, .gentle, .forward),
        .loopMoveOutLeftFar: loopMove(.outPoint, .aggressive, .backward),
        .loopMoveOutRightFar: loopMove(.outPoint, .aggressive, .forward),
        .loopMoveLeft: loopMove(.whole, .gentle, .backward),
        .loopMoveRight: loopMove(.whole, .gentle, .forward),
        .loopMoveLeftFar: loopMove(.whole, .aggressive, .backward),
        .loopMoveRightFar: loopMove(.whole, .aggressive, .forward)
    ]

    private static func loopMove(
        _ target: LoopMoveTarget, _ tier: SelectionMoveTier, _ direction: NudgeDirection
    ) -> @MainActor (MenuContext) -> Void {
        { $0.model.moveLoop(target, tier, direction: direction) }
    }

    static let speedActions: [ActionID: @MainActor (MenuContext) -> Void] = [
        .speedUp: { $0.model.faster(fine: false) },
        .speedDown: { $0.model.slower(fine: false) },
        .speedUpFine: { $0.model.faster(fine: true) },
        .speedDownFine: { $0.model.slower(fine: true) },
        .speedPreset100: preset(0),
        .speedPreset75: preset(1),
        .speedPreset50: preset(2),
        .speedPreset33: preset(3),
        .speedEngineToggle: { $0.model.toggleStretchEngine() }
    ]

    private static func preset(_ index: Int) -> @MainActor (MenuContext) -> Void {
        { $0.model.setSpeedPreset(SpeedStepping.presets[index]) }
    }

    static let selectionActions: [ActionID: @MainActor (MenuContext) -> Void] = [
        .selectionSelectAll: { $0.model.selectAll() },
        .selectionClear: { $0.model.clearSelection() },
        .selectionExtendLeft: { $0.model.extendSelection(.backward) },
        .selectionExtendRight: { $0.model.extendSelection(.forward) },
        .selectionMoveLeft: selectionMove(.gentle, .backward),
        .selectionMoveRight: selectionMove(.gentle, .forward),
        .selectionMoveLeftFar: selectionMove(.aggressive, .backward),
        .selectionMoveRightFar: selectionMove(.aggressive, .forward)
    ]

    private static func selectionMove(
        _ tier: SelectionMoveTier, _ direction: NudgeDirection
    ) -> @MainActor (MenuContext) -> Void {
        { $0.model.moveSelection(tier, direction: direction) }
    }

    static let viewActions: [ActionID: @MainActor (MenuContext) -> Void] = [
        .zoomIn: { $0.model.zoomIn() },
        .zoomOut: { $0.model.zoomOut() },
        .zoomFit: { $0.model.fitWholeFile() },
        .zoomToSelection: { $0.model.zoomToSelection() },
        .viewScrollLeft: { $0.model.scrollLeft() },
        .viewScrollRight: { $0.model.scrollRight() },
        .viewToggleInspector: { $0.inspector.toggle() },
        .helpShortcuts: { $0.inspector.show(.shortcuts) }
    ]

    /// Cut, Copy and Paste are sent down the responder chain by hand, because
    /// this app replaces the standard pasteboard group and nothing here
    /// implements them itself. With no field focused they reach no responder and
    /// do nothing — a smaller lie than a ⌘V that has stopped working in
    /// Settings' numeric fields.
    ///
    /// `app.settings` is absent on purpose: SwiftUI's `Settings` scene owns both
    /// the menu item and ⌘,. It is in the catalog so the reference lists it.
    static let applicationActions: [ActionID: @MainActor (MenuContext) -> Void] = [
        .fileOpen: { ViewerActions.open($0.model) },
        .fileSave: { $0.model.saveSession() },
        .fileSaveAs: { ViewerActions.saveAs($0.model) },
        .editCut: { _ in send(#selector(NSText.cut(_:))) },
        .editCopy: { _ in send(#selector(NSText.copy(_:))) },
        .editPaste: { _ in send(#selector(NSText.paste(_:))) }
    ]

    private static func send(_ action: Selector) {
        NSApp?.sendAction(action, to: nil, from: nil)
    }
}
