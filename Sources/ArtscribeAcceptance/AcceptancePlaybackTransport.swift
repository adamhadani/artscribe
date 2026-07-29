import ArtscribeKit
import ArtscribeUI
import Foundation

/// The transport half of the `playback` group: what `Space` and `⇧Space` do,
/// driven through `NSApp.sendEvent` so the menu bar's key equivalents and the
/// window's `onKeyPress` are both exercised.
///
/// Split out of `AcceptancePlayback` when the P0 key swap pushed that file past
/// the project's length limit. It is the same run — `checkPlayback` calls this
/// first — and it is the check to read most carefully after any rebinding,
/// because both transport keys are asserted here by name.
extension AcceptanceRun {

    @MainActor
    static func checkTransport(
        model: ViewerModel, log: inout Logger, stalled: String?
    ) async {
        // Space is play-from-start since the P0 swap; with no selection and no
        // loop its aim point is frame 0, which is where the caller left the
        // playhead, so this starts playing without moving anything.
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

        // The deliberate consequence of the swap, checked rather than assumed:
        // Space no longer toggles. Pressed while playing it is still a
        // play-from-start, so the transport stays running and the position goes
        // back to the aim point — which is Pro Tools' behaviour and what the
        // user asked for. Pausing is ⇧Space and nothing else.
        press(.space)
        log.check("Space while playing does not pause — it restarts", model.isPlaying)
        await settle(seconds: 0.2)
        log.check(
            "Space while playing goes back to the aim point (\(model.playhead) vs \(later))",
            model.playhead < later, unless: stalled)

        press(.shiftSpace)
        log.check("⇧Space pauses", !model.isPlaying)
        await settle(seconds: 0.3)
        let paused = model.playhead
        await settle(seconds: 0.4)
        log.check("the playhead stops when paused", model.playhead == paused)

        // Task 18 moved play-from-start off `Return` and onto `⇧Space`; the P0
        // swap moved it again, onto the bare `Space`. Both halves are checked:
        // the new binding works, and `Return` still does not — a binding that
        // keeps working after every document says it moved is the drift this
        // project has been bitten by twice.
        model.seek(to: FrameIndex(model.sampleRate * 3))
        let displaced = model.playhead
        press(.space)
        log.check("Space plays from the start", model.isPlaying)
        await settle(seconds: 0.2)
        // Not position-dependent: `seek` moves the model's own playhead
        // synchronously, so this holds whether or not the render thread is
        // advancing — which is why it carries no `unless: stalled`.
        log.check(
            "Space moved the position back to zero (\(model.playhead) vs \(displaced))",
            model.playhead < displaced)
        press(.shiftSpace)
        await settle(seconds: 0.1)

        log.check("⇧Space still pauses after a Space", !model.isPlaying)
        press(.enter)
        await settle(seconds: 0.2)
        log.check("Return is bound to nothing and starts no playback", !model.isPlaying)
    }
}
