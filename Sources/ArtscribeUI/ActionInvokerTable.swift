import SwiftUI

#if os(macOS)
import AppKit
#endif

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
        .transportPrerollToggle: { $0.model.togglePreroll() },
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
        .loopMoveRightFar: loopMove(.whole, .aggressive, .forward),
        // Task 21. Start/stop only — the schedule is edited in the Practice
        // window, and the ramp itself lives on the model (`ViewerModel+Practice`).
        .practiceRampToggle: { $0.model.toggleRamp() },
        .pitchUp: { $0.model.adjustPitch(byCents: ViewerModel.semitoneStep) },
        .pitchDown: { $0.model.adjustPitch(byCents: -ViewerModel.semitoneStep) },
        .pitchUpFine: { $0.model.adjustPitch(byCents: ViewerModel.centStep) },
        .pitchDownFine: { $0.model.adjustPitch(byCents: -ViewerModel.centStep) },
        .pitchReset: { $0.model.resetPitch() },
        .viewTrackMarksToggle: { $0.model.toggleTrackMarks() }
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
        .speedPreset33: preset(3)
    ]

    private static func preset(_ index: Int) -> @MainActor (MenuContext) -> Void {
        { $0.model.setSpeedPreset(SpeedStepping.presets[index]) }
    }

    /// **`⌘A` and `⎋` mean the text when text is being edited.**
    ///
    /// Not an embellishment — the measured cause of *"copy paste still doesn't
    /// work in that search textarea"*. `⌘C` and `⌘V` were fine all along: driven
    /// for real against the shortcut window's filter, `⌘V` pastes and `copy:`
    /// reaches the field editor. What did not work was **selecting** the text to
    /// copy: `⌘A` is this app's `Select All`, its menu item is live, and it was
    /// selecting the whole *track* — leaving the field's selection empty, so the
    /// `⌘C` that followed copied nothing and read as a broken Copy.
    ///
    /// The remedy is the one the standard Edit menu already uses for Cut, Copy
    /// and Paste below: send the selector down the key window's responder chain
    /// and let the field editor have it. Enablement cannot be the remedy —
    /// `KeyWindowTracker` already says the document is not key, and SwiftUI's
    /// menu items were measured *still enabled* several seconds later, so a
    /// guard that depends on when SwiftUI re-evaluates a `Commands` body is a
    /// guard that is sometimes not there.
    static let selectionActions: [ActionID: @MainActor (MenuContext) -> Void] = [
        // The two `#if`s below are the same difference stated twice: on macOS the
        // app sees the keystroke first and has to hand it back to a field editor;
        // on iOS SwiftUI delivers to the focused view first, so by the time these
        // run no field wanted it.
        //
        // **That is an assumption, and it is written here rather than assumed
        // silently.** It matches how `onKeyPress` and `.keyboardShortcut` are
        // documented to route on iPadOS, but nothing in this repository has
        // exercised it — there is no iPad target yet to exercise it with. The
        // check to run first, once there is one: focus the shortcut sheet's
        // filter field, type ⌘A, and confirm the *text* is selected rather than
        // the whole track.
        .selectionSelectAll: { context in
            #if os(macOS)
            guard !TextFocus.isEditingText else { return send(#selector(NSText.selectAll(_:))) }
            #endif
            context.model.selectAll()
        },
        .selectionClear: { context in
            // `⎋` in a text field ends the edit, which is what the platform
            // means by it; clearing the audio selection from under a field the
            // reader is typing in is not.
            #if os(macOS)
            guard !TextFocus.isEditingText else {
                return send(#selector(NSResponder.cancelOperation(_:)))
            }
            #endif
            context.model.clearSelection()
        },
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
        // Toggles rather than shows: ⌘/ pressed at a window already in front of
        // you did nothing at all, which reads as a dead key. See
        // `ShortcutWindowController.toggle`.
        .helpShortcuts: { $0.shortcuts.toggle() },
        .practiceShow: { $0.practice.toggle() }
    ]

    /// Cut, Copy and Paste are sent down the responder chain by hand, because
    /// this app replaces the standard pasteboard group and nothing here
    /// implements them itself. With no field focused they reach no responder and
    /// do nothing — a smaller lie than a ⌘V that has stopped working in
    /// Settings' numeric fields.
    ///
    /// `app.settings` is absent **on macOS** on purpose: SwiftUI's `Settings`
    /// scene owns both the menu item and ⌘,, so an entry here would be a second
    /// opener competing with it. It is in the catalog either way so the
    /// reference lists it.
    ///
    /// On iPad there is no such scene — and the `Settings…` the system offers
    /// goes to the app's page in the Settings app, which is empty because this
    /// app ships no `Settings.bundle`. So iPad wires it to a sheet, and it is
    /// added below with the other conditional entry.
    /// Built in a closure rather than written as a literal because one entry is
    /// conditional and `#if` is not allowed between a dictionary's elements.
    static let applicationActions: [ActionID: @MainActor (MenuContext) -> Void] = {
        var actions: [ActionID: @MainActor (MenuContext) -> Void] = [
            .fileSave: { $0.model.saveSession() },
            // Through the session guard, not straight to `closeTrack`: putting a
            // track away is walking away from its session, and has to ask the
            // same question that opening another one does. Without it, closing
            // would be the one route that silently discarded a loop.
            .fileClose: { ViewerActions.closeTrack($0.model) },
            .editCut: { _ in send(#selector(TextResponder.cut(_:))) },
            .editCopy: { _ in send(#selector(TextResponder.copy(_:))) },
            .editPaste: { _ in send(#selector(TextResponder.paste(_:))) },
            // Toggles rather than shows, as `⌘/` and `⌘P` do: chosen from a menu
            // while the panel is already in front of you, a show-only command
            // does nothing at all. See `AuxiliaryWindow.action`.
            .appAbout: { $0.about.toggle() }
        ]
        // Save As needs somewhere to ask — a save panel, or a document picker on
        // iPad — and there is no iPad picker yet. Absent from the table there
        // rather than present and inert, so nothing offers a Save As… that
        // silently does nothing.
        //
        // File ▸ Open is here for the same reason: iPad's document picker is a
        // presentation on a view, not a function that returns a URL, so on that
        // platform Open belongs to the view rather than to this table.
        #if os(macOS)
        actions[.fileOpen] = { ViewerActions.open($0.model) }
        actions[.fileSaveAs] = { ViewerActions.saveAs($0.model) }
        #else
        // The mirror image of the macOS omission above: there is no `Settings`
        // scene on iPadOS, so nothing owns ⌘, and the system's own Settings item
        // goes to an empty page in the Settings app. Wired to a sheet here, and
        // toggling for the same reason `.appAbout` is.
        actions[.appSettings] = { $0.settings.toggle() }
        #endif
        return actions
    }()

    /// Whichever class declares `cut:`/`copy:`/`paste:` on this platform.
    ///
    /// The selectors are identical — they are the same Objective-C names the
    /// responder chain has used since before either framework existed — so only
    /// the type the `#selector` is spelled against differs.
    #if os(macOS)
    private typealias TextResponder = NSText
    #else
    private typealias TextResponder = UIResponder
    #endif

    private static func send(_ action: Selector) {
        #if os(macOS)
        NSApp?.sendAction(action, to: nil, from: nil)
        #else
        UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
        #endif
    }
}
