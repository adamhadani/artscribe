import ArtscribeKit

/// Where `⇧Space` aims — one rule, decided here rather than left to the engine.
///
/// **The bug this exists to kill.** `returnToStart` used to be
/// `seek(to: selection.isEmpty ? 0 : selection.range.start)`, which never
/// mentions the loop. That was not the whole story the user saw, because
/// `PlaybackEngine` pulls playback into an active loop: a cursor placed before
/// the in point plays forward until the out point and is captured there (spec
/// §5.1, deliberate since Task 8). So with a loop running, `⇧Space` aimed at
/// frame 0, the engine dragged the cursor into the region a moment later, and the
/// app read as if it were following two competing rules — worse than a plain bug,
/// because it looked arbitrary.
///
/// Task 24 removed the other half of that behaviour: a cursor at or past the out
/// point used to be snapped *backwards* on the very next feed, and no longer is.
/// The loop now captures on arrival only, so aiming correctly matters more, not
/// less — nothing downstream will quietly correct a bad target any more.
///
/// The fix is to aim correctly in the first place instead of relying on the
/// engine to correct a bad target:
///
/// 1. a selection exists → its start;
/// 2. no selection, an **active** loop → the loop's in point;
/// 3. otherwise → the start of the track.
///
/// **Why `isActive` and not `isEnabled`.** `isActive` is `isEnabled && count > 0`,
/// and both halves earn their place. A loop the user switched off with `D` must
/// not steer the playhead — turning it off is an explicit instruction to ignore
/// it, and the engine ignores it too, so aiming at it would put the playhead
/// somewhere no other part of the app agrees with. And a zero-length region — one
/// press of `A` with no `S` yet — has no meaningful "start" to play from, so
/// `isEnabled` alone would let a stale in-point hijack rule 3. `PlaybackEngine`
/// and `TransportLatch.rewindTarget` both already branch on exactly `isActive`;
/// using a different predicate here is how the disagreement started.
///
/// **What this rule does not do.** It picks the aim point, and nothing more. A
/// selection lying wholly outside an active loop is two explicit instructions
/// that contradict each other; since Task 24 the engine no longer arbitrates
/// between them by dragging the cursor about, so what happens is simply what the
/// aim point says: a selection *before* the loop plays until the out point and is
/// captured there, and one *after* it plays to the end of the file. Both are the
/// same one rule — the loop captures on arrival — applied to an honestly honoured
/// seek.
public enum PlaybackStart {

    /// - Returns: the frame `⇧Space` should seek to. Unclamped; `ViewerModel.seek`
    ///   clamps to the file, and every input here is already a frame within it.
    public static func target(selection: Selection, loop: LoopRegion) -> FrameIndex {
        guard selection.isEmpty else { return selection.range.start }
        return loop.isActive ? loop.range.start : 0
    }
}
