import ArtscribeKit
import ArtscribeUI
import Foundation

/// The transport half of the `playback` group: what `Space` and `⇧Space` do,
/// driven through `NSApp.sendEvent` so the menu bar's key equivalents and the
/// window's `onKeyPress` are both exercised.
///
/// Split out of `AcceptancePlayback` when Task 28's key swap pushed that file
/// past the project's length limit, and kept when Task 29 reverted the swap: it
/// is the same run — `checkPlayback` calls this first — and it is the check to
/// read most carefully after any rebinding, because both transport keys are
/// asserted here by name.
///
/// Task 29's **preroll** is driven here too. It is the one behaviour in the app
/// where the position after a keystroke is not the position before it, so it is
/// measured against `model.prerollSeconds` rather than against a hard-coded 2 s
/// — a check that agreed with a literal would go on passing if the preference
/// stopped being read.
extension AcceptanceRun {

    @MainActor
    static func checkTransport(
        model: ViewerModel, log: inout Logger, stalled: String?
    ) async {
        press(.space)
        // The trap: `isPlaying` on the engine is not observable until the render
        // thread drains the ring, so the *button* must be true immediately.
        log.check("Space is handled and the transport latches immediately", model.isPlaying)

        await settle(seconds: 0.6)
        let moved = model.playhead
        log.check(
            "the playhead advances during playback (\(moved) frames)", moved > 0, unless: stalled)
        await settle(seconds: 0.6)
        let later = model.playhead
        log.check(
            "the playhead keeps advancing (\(moved) → \(later))", later > moved, unless: stalled)

        // Real time against source time: at 1.0x they must agree to well within
        // the poll interval. This is the objective form of "the playhead stays
        // synchronised with what you hear".
        let elapsed = Double(later - moved) / model.sampleRate
        log.note("playhead advance over ~0.6 s of wall clock", String(format: "%.3f s", elapsed))
        log.check(
            "the playhead tracks real time at 1.0x", abs(elapsed - 0.6) < 0.15, unless: stalled)

        press(.space)
        log.check("Space pauses", !model.isPlaying)
        await settle(seconds: 0.3)
        let paused = model.playhead
        await settle(seconds: 0.4)
        log.check("the playhead stops when paused", model.playhead == paused)

        await checkPreroll(model: model, log: &log)
        await checkPlayFromStart(model: model, log: &log)
    }

    // MARK: - Preroll (Task 29)

    /// `Space` from a pause resumes slightly *before* where it stopped, which is
    /// the whole point of the feature: you stop on a note, and to hear it in
    /// context you have to start a moment earlier.
    ///
    /// Every position here is read **immediately** after the press. `seek` moves
    /// the model's own playhead synchronously, so that read is the resume point
    /// itself rather than wherever the render thread has since carried it —
    /// which is why none of these carry `unless: stalled`.
    @MainActor
    private static func checkPreroll(model: ViewerModel, log: inout Logger) async {
        model.clearLoop()
        model.clearSelection()
        model.pause()
        await settle(seconds: 0.2)

        model.seek(to: FrameIndex(model.sampleRate * 10))
        let stoppedAt = model.playhead
        press(.space)
        let resumedAt = model.playhead
        let rolledBack = Double(stoppedAt - resumedAt) / model.sampleRate
        log.note("preroll measured at the key", String(format: "%.3f s", rolledBack))
        log.check(
            "Space resumes one preroll before where it paused "
                + "(\(rolledBack) s vs the configured \(model.prerollSeconds) s)",
            abs(rolledBack - model.prerollSeconds) < 0.01)
        log.check("the prerolled resume is playing", model.isPlaying)

        // Deliberately compounding: each press is a fresh resume from wherever
        // the playhead is now, so pausing and resuming twice walks backwards.
        // It is the same gesture repeated, and it is how you inch back through a
        // phrase you keep missing the start of.
        press(.space)
        await settle(seconds: 0.1)
        model.seek(to: resumedAt)
        press(.space)
        let again = model.playhead
        log.check(
            "a second pause-and-resume prerolls again rather than staying put "
                + "(\(again) vs \(resumedAt))",
            again < resumedAt)
        press(.space)
        await settle(seconds: 0.1)

        // Nothing before frame 0 to roll back into.
        model.seek(to: 0)
        press(.space)
        log.check(
            "a preroll at the file start clamps to 0 (\(model.playhead))", model.playhead == 0)
        press(.space)
        await settle(seconds: 0.1)
        log.check("Space pauses again after the preroll checks", !model.isPlaying)
    }

    // MARK: - Play from start

    /// Task 18 moved play-from-start off `Return` and onto `⇧Space`; Task 28
    /// moved it onto the bare `Space` and Task 29 put it back. Both halves are
    /// checked: the binding works, and `Return` still does not — a binding that
    /// keeps working after every document says it moved is the drift this
    /// project has been bitten by twice.
    ///
    /// That `⇧Space` takes **no** preroll is checked in the `start` group rather
    /// than here: `checkStartPrecedence` asserts the aim point by exact equality
    /// against a selection start and a loop in point that are both far past the
    /// preroll, so a preroll leaking into this key would fail it outright.
    @MainActor
    private static func checkPlayFromStart(model: ViewerModel, log: inout Logger) async {
        model.seek(to: FrameIndex(model.sampleRate * 3))
        let displaced = model.playhead
        press(.shiftSpace)
        log.check("⇧Space plays from the start", model.isPlaying)
        await settle(seconds: 0.2)
        // Not position-dependent: `seek` moves the model's own playhead
        // synchronously, so this holds whether or not the render thread is
        // advancing — which is why it carries no `unless: stalled`.
        log.check(
            "⇧Space moved the position back to zero (\(model.playhead) vs \(displaced))",
            model.playhead < displaced)

        press(.space)
        await settle(seconds: 0.1)
        log.check("Space still pauses after a ⇧Space", !model.isPlaying)
        press(.enter)
        await settle(seconds: 0.2)
        log.check("Return is bound to nothing and starts no playback", !model.isPlaying)
    }
}
