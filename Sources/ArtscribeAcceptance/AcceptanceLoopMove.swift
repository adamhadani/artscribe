import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// Task 24 B in the running window: moving the loop's edges and its body by
/// keyboard — spec §6.2's `loop.move` actions.
///
/// Every one is driven by a real keystroke through `press(…)` — `NSApp.sendEvent`,
/// the same route a real key takes, menu bar first. That matters more here than
/// usual: `NSMenu` matches a key equivalent against a **lowercase**
/// `charactersIgnoringModifiers`, so a `⇧A` arriving as "A" is never claimed by
/// the menu, and only a real press proves the twelve chords reach the model at
/// all rather than merely drawing a shortcut nobody can fire. It also proves
/// single-fire: an action wired to both the menu and `DocumentView` that moved
/// the loop twice per press would fail these checks rather than pass quietly.
extension AcceptanceRun {

    @MainActor
    static func checkLoopMovement(model: ViewerModel, log: inout Logger) async {
        model.pause()
        model.fitWholeFile()
        let step = { (seconds: Double) in FrameIndex((seconds * model.sampleRate).rounded()) }
        let gentle = step(model.prefs.selectionMoveAmounts[.gentle])
        let aggressive = step(model.prefs.selectionMoveAmounts[.aggressive])

        // A loop well clear of both ends, wide enough that a far step does not
        // cross it — the crossings get their own check below.
        func setLoop() -> FrameRange {
            model.clearLoop()
            model.seek(to: model.totalFrames / 4)
            press(.a)
            model.seek(to: model.totalFrames * 3 / 4)
            press(.s)
            return model.loop.range
        }

        let before = setLoop()
        guard !before.isEmpty else {
            log.check("the loop-move check could set a loop to move", false)
            return
        }

        press(.shiftS)
        var after = model.loop.range
        log.check(
            "Shift-S moves the loop in point right by exactly one gentle step "
                + "(\(after.start - before.start) frames, one step is \(gentle))",
            after.start - before.start == gentle && after.end == before.end)
        press(.shiftA)
        log.check("Shift-A moves it back, once", model.loop.range == before)

        press(.shiftD)
        after = model.loop.range
        log.check(
            "Shift-D moves the loop out point left by one gentle step "
                + "(\(before.end - after.end) frames)",
            before.end - after.end == gentle && after.start == before.start)
        press(.shiftF)
        log.check("Shift-F moves it back, once", model.loop.range == before)

        press(.optionShiftA)
        after = model.loop.range
        log.check(
            "Option-Shift-A moves the in point left by the far step "
                + "(\(before.start - after.start) frames, one step is \(aggressive))",
            before.start - after.start == aggressive && after.end == before.end)
        press(.optionShiftS)
        log.check("Option-Shift-S moves it back, once", model.loop.range == before)

        press(.optionShiftF)
        after = model.loop.range
        log.check(
            "Option-Shift-F moves the out point right by the far step "
                + "(\(after.end - before.end) frames)",
            after.end - before.end == aggressive && after.start == before.start)
        press(.optionShiftD)
        log.check("Option-Shift-D moves it back, once", model.loop.range == before)

        // The whole loop, length preserved exactly.
        press(.shiftV)
        after = model.loop.range
        log.check(
            "Shift-V moves the whole loop right, keeping its length "
                + "(\(after.start - before.start) frames, length \(after.count) vs "
                + "\(before.count))",
            after.start - before.start == gentle && after.count == before.count)
        press(.shiftC)
        log.check("Shift-C moves it back, once", model.loop.range == before)

        press(.optionShiftC)
        after = model.loop.range
        log.check(
            "Option-Shift-C moves the whole loop left by the far step, keeping its length",
            before.start - after.start == aggressive && after.count == before.count)
        press(.optionShiftV)
        log.check("Option-Shift-V moves it back, once", model.loop.range == before)

        checkLoopMoveWalls(model: model, before: before, aggressive: aggressive, log: &log)
        checkLoopMoveInversion(model: model, log: &log)
        checkTheOtherKeysAreUnharmed(model: model, log: &log)
        model.clearLoop()
        model.seek(to: 0)
    }

    /// Both walls. A loop pushed against an end of the file must stop there —
    /// with its length intact for a body move, and without inverting for an edge.
    @MainActor
    private static func checkLoopMoveWalls(
        model: ViewerModel, before: FrameRange, aggressive: FrameIndex, log: inout Logger
    ) {
        // Enough presses to cross the whole file from anywhere in it, whatever
        // the file and the configured amount are.
        let crossings = Int(model.totalFrames / Swift.max(aggressive, 1)) + 3

        for _ in 0..<crossings { press(.optionShiftC) }
        var after = model.loop.range
        log.check(
            "the whole loop pushed against the start stops there, keeping its length "
                + "(\(after.start)…\(after.end), length \(after.count) vs \(before.count))",
            after.start == 0 && after.count == before.count)
        for _ in 0..<(2 * crossings) { press(.optionShiftV) }
        after = model.loop.range
        log.check(
            "and pushed against the end it stops there too, keeping its length "
                + "(\(after.start)…\(after.end) of \(model.totalFrames))",
            after.end == model.totalFrames && after.count == before.count)

        for _ in 0..<crossings { press(.optionShiftA) }
        after = model.loop.range
        log.check(
            "the in point pushed against the start of the file stops at zero (\(after.start))",
            after.start == 0)
        for _ in 0..<crossings { press(.optionShiftF) }
        after = model.loop.range
        log.check(
            "the out point pushed against the end stops at the end "
                + "(\(after.end) of \(model.totalFrames))",
            after.end == model.totalFrames)
    }

    /// Inversion **swaps**, matching what a dragged edge does — Task 23 chose
    /// that structurally in `TimelineHandles.resized`, and the keyboard calls the
    /// same function, so the two cannot disagree.
    @MainActor
    private static func checkLoopMoveInversion(model: ViewerModel, log: inout Logger) {
        // A loop deliberately shorter than one far step, so one press crosses.
        model.clearLoop()
        let anchor = model.totalFrames / 2
        model.seek(to: anchor)
        press(.a)
        model.seek(to: anchor + FrameIndex(model.sampleRate / 4))
        press(.s)
        let before = model.loop.range
        guard !before.isEmpty else {
            log.check("the inversion check could set a short loop", false)
            return
        }

        press(.optionShiftS)
        let after = model.loop.range
        log.check(
            "pushing the in point past the out point swaps instead of inverting "
                + "(\(after.start)…\(after.end), was \(before.start)…\(before.end))",
            after.start == before.end && after.end > after.start)
    }

    /// The plain letters must still do what they always did, and `⇧` must no
    /// longer be a silent synonym for them. `handleLoop` used to ignore modifiers
    /// entirely, which made `⇧A` a live "set loop in" that nothing documented.
    @MainActor
    private static func checkTheOtherKeysAreUnharmed(model: ViewerModel, log: inout Logger) {
        model.clearLoop()
        model.seek(to: model.totalFrames / 4)
        press(.a)
        model.seek(to: model.totalFrames * 3 / 4)
        press(.s)
        log.check(
            "A and S still set the loop points at the playhead",
            model.loop.range.start == model.totalFrames / 4
                && model.loop.range.end == model.totalFrames * 3 / 4)

        // ⇧C / ⇧V now belong to the loop, so the selection must not move with
        // them — the one binding this task took away from something else.
        model.clearSelection()
        let lanes = model.laneFrame
        guard !lanes.isEmpty else { return }
        let from = CGPoint(x: lanes.width * 0.3, y: lanes.height / 2)
        let to = CGPoint(x: lanes.width * 0.45, y: lanes.height / 2)
        model.laneDragChanged(start: from, current: from, option: false, shift: false)
        model.laneDragChanged(start: from, current: to, option: false, shift: false)
        model.laneDragEnded(start: from, end: to, now: ProcessInfo.processInfo.systemUptime)
        let selection = model.selection.range
        let loop = model.loop.range
        press(.shiftV)
        log.check(
            "Shift-V moves the loop and leaves the selection exactly where it was",
            model.selection.range == selection && model.loop.range != loop)
        press(.v)
        log.check(
            "and plain V still moves the selection, not the loop",
            model.selection.range != selection)
        model.clearSelection()
    }
}
