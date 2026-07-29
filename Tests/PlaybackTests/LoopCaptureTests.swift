import ArtscribeKit
import Testing
import TimeStretch

@testable import Playback

// MARK: - The loop captures on arrival, not on entry (Task 24 A)
//
// An explicit seek is honoured: playback starts exactly where it was asked to, and the
// loop takes hold only when playback *reaches* the out point from below. The three cases
// below are the whole rule, and they are what Ableton and Logic do.
//
// The behaviour this replaced was one line — `if looping && readCursor >= loop.range.end
// { readCursor = loop.range.start }` evaluated before the segment end was chosen. A cursor
// past the out point was snapped backwards on the very next feed (which reads as being
// yanked), while a cursor before the in point was not (which reads as playing normally and
// then falling in). One line, two experiences, and the user overruled both.

/// Case 1 — **before** the loop. Plays from the seek, runs on through the in point, is
/// captured at the out point, and loops from then on.
@Test func aSeekBeforeTheLoopPlaysOnAndIsCapturedAtTheOutPoint() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 500, count: 100), true))
    ring.push(.seek(0))
    let out = render(engine, frames: 800)

    // Honoured: playback starts where it was asked, not at the loop's in point.
    #expect(out[0] == 0)
    // Runs straight through the in point without being pulled in early.
    #expect(out[500] == 500)
    #expect(out[599] == 599)
    // Captured on arrival at the out point, and looping from there on.
    #expect(out[600] == 500)
    #expect(out[699] == 599)
    #expect(out[700] == 500)
}

/// Case 2 — **inside** the loop. Plays from the seek and wraps normally.
@Test func aSeekInsideTheLoopPlaysFromThereAndWrapsNormally() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), true))
    ring.push(.seek(1050))
    let out = render(engine, frames: 250)

    #expect(out[0] == 1050)
    #expect(out[49] == 1099)
    #expect(out[50] == 1000)
    #expect(out[149] == 1099)
    #expect(out[150] == 1000)
    #expect(out.allSatisfy { $0 >= 1000 && $0 < 1100 })
}

/// Case 3 — **after** the loop. Plays from the seek to the end of the file and never
/// wraps. This is the case the user reported as being yanked backwards.
@Test func aSeekAfterTheLoopPlaysOnAndNeverWraps() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), true))
    ring.push(.seek(5000))
    let out = render(engine, frames: 400)

    for i in 0..<400 {
        #expect(out[i] == Float(5000 + i), "frame \(i)")
    }
}

/// The boundary between cases 2 and 3. `FrameRange` is half-open, so the out point is the
/// first frame that is *not* in the loop: a seek landing exactly on it is a seek after the
/// loop, and plays on.
@Test func aSeekExactlyOnTheOutPointIsASeekAfterTheLoop() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), true))
    ring.push(.seek(1100))
    let out = render(engine, frames: 200)

    #expect(out[0] == 1100)
    #expect(out[199] == 1299)
}

/// The boundary between cases 1 and 2: the in point itself is inside the loop.
@Test func aSeekExactlyOnTheInPointLoopsImmediately() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), true))
    ring.push(.seek(1000))
    let out = render(engine, frames: 250)

    #expect(out[0] == 1000)
    #expect(out[99] == 1099)
    #expect(out[100] == 1000)
}

/// Case 3 all the way out: a seek past an active loop runs to the end of the file and
/// stops there, exactly as it would with no loop set at all. The stream is finalised, so
/// the transport clears itself rather than sitting "playing" over silence forever.
@Test func aSeekAfterTheLoopStillStopsAtTheEndOfTheFile() {
    let (engine, ring) = makeEngine(frames: 1000)
    ring.push(.setLoop(FrameRange(start: 100, count: 50), true))
    ring.push(.seek(900))
    let out = render(engine, frames: 400)

    #expect(out[0] == 900)
    #expect(out[99] == 999)
    #expect(out[150] == 0)
    #expect(!engine.isPlaying)
}

/// The end-of-file tail is flushed on that path too. Without the `final: true` the last
/// fraction of a second of the file is never heard — and the old code could not reach this
/// path at all with a loop enabled, because it wrapped instead.
@Test func aSeekAfterTheLoopFlushesTheEndOfStreamTail() {
    let stretcher = FakeStretcher(tail: 64)
    let (engine, ring) = makeFakeEngine(stretcher, frames: 1000)
    ring.push(.setLoop(FrameRange(start: 100, count: 50), true))
    ring.push(.seek(900))
    let out = render(engine, frames: 400)

    #expect(out[99] == 999)
    #expect(out[100] == FakeStretcher.tailMarker)
    #expect(out[163] == FakeStretcher.tailMarker)
    #expect(out[164] == 0)
    #expect(!engine.isPlaying)
}

/// A loop that is switched off is not a loop: the cursor position rule must not apply to
/// it in either direction.
@Test func aDisabledLoopCapturesNothingFromEitherSide() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), false))
    ring.push(.seek(900))
    let out = render(engine, frames: 400)
    #expect(out[0] == 900)
    #expect(out[399] == 1299)
}

/// The capture is a *state* of the cursor, not a one-shot: having been captured once,
/// playback keeps wrapping for as long as the loop is on, however many blocks later.
@Test func captureFromBelowSurvivesManyRenderBlocks() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 500, count: 100), true))
    ring.push(.seek(400))
    var seen: [Float] = []
    for _ in 0..<12 { seen.append(contentsOf: render(engine, frames: 256)) }

    #expect(seen[0] == 400)
    // Everything from the out point onward stays inside the region, block after block.
    #expect(seen[200...].allSatisfy { $0 >= 500 && $0 < 600 })
}
