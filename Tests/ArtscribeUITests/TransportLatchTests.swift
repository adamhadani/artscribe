import ArtscribeKit
import Testing

@testable import ArtscribeUI

/// The play/pause state machine, and the two traps it exists to avoid.
///
/// **Trap 1.** `PlaybackEngine.isPlaying` is not observable until the render
/// thread has drained the command ring. Task 9's CLI hit this: it pushed
/// `.setPlaying(true)`, immediately polled `isPlaying`, saw `false`, and
/// concluded playback had ended before a single frame was rendered. The UI must
/// show what the *user asked for* until the engine has had a chance to answer.
///
/// **Trap 2.** Pressing play at end of file with no loop makes the engine restart
/// the stream, immediately re-finalise it, and clear the playing flag inside one
/// render call. Without the rewind below, the play button flickers on and off.
@Suite("Transport latch")
struct TransportLatchTests {

    // MARK: - Trap 1

    @Test("the button shows playing the instant play is requested, before the engine answers")
    func intentIsImmediate() {
        var latch = TransportLatch()
        latch.request(true, now: 0)
        #expect(latch.isPlaying)
    }

    /// The exact CLI bug, as a test: the first few polls after the request see
    /// `isPlaying == false` simply because the render thread has not run yet.
    /// Concluding "playback ended" there is wrong.
    @Test("polls before the render thread drains the ring do not end playback")
    func waitsForTheRenderThread() {
        var latch = TransportLatch()
        latch.request(true, now: 0)
        for tick in 1...10 {
            #expect(latch.poll(enginePlaying: false, now: Double(tick) / 60) == .unchanged)
            #expect(latch.isPlaying)
        }
        #expect(latch.poll(enginePlaying: true, now: 0.2) == .started)
        #expect(latch.isPlaying)
    }

    @Test("once confirmed, the engine dropping out of playing ends playback")
    func confirmedStopEndsPlayback() {
        var latch = TransportLatch()
        latch.request(true, now: 0)
        #expect(latch.poll(enginePlaying: true, now: 0.05) == .started)
        #expect(latch.poll(enginePlaying: false, now: 0.10) == .finished)
        #expect(!latch.isPlaying)
    }

    /// A start that never happens must be reported, not waited on forever: a
    /// permanently "playing" button over silence is exactly the silent
    /// degradation spec §8 forbids.
    @Test("a start that never arrives is reported once the deadline passes")
    func neverStartedIsReported() {
        var latch = TransportLatch()
        latch.request(true, now: 0)
        #expect(
            latch.poll(enginePlaying: false, now: TransportLatch.startTimeout - 0.01)
                == .unchanged)
        #expect(
            latch.poll(enginePlaying: false, now: TransportLatch.startTimeout + 0.01)
                == .neverStarted)
        #expect(!latch.isPlaying)
        // Reported once, not on every subsequent tick.
        #expect(latch.poll(enginePlaying: false, now: 10) == .unchanged)
    }

    @Test("pausing is immediate and is never mistaken for the engine finishing")
    func pauseIsNotFinish() {
        var latch = TransportLatch()
        latch.request(true, now: 0)
        #expect(latch.poll(enginePlaying: true, now: 0.05) == .started)
        latch.request(false, now: 1.0)
        #expect(!latch.isPlaying)
        // The engine is still draining its last block; that is not an EOF.
        #expect(latch.poll(enginePlaying: true, now: 1.01) == .unchanged)
        #expect(latch.poll(enginePlaying: false, now: 1.02) == .unchanged)
        #expect(!latch.isPlaying)
    }

    @Test("re-requesting play restarts the confirmation window")
    func rerequestResetsTheDeadline() {
        var latch = TransportLatch()
        latch.request(true, now: 0)
        #expect(
            latch.poll(enginePlaying: false, now: TransportLatch.startTimeout + 0.01)
                == .neverStarted)
        latch.request(true, now: 100)
        #expect(latch.poll(enginePlaying: false, now: 100.1) == .unchanged)
        #expect(latch.isPlaying)
    }

    // MARK: - Trap 2

    @Test("playing from a natural end of file rewinds first, so the engine cannot bounce")
    func rewindsAfterEndOfFile() {
        #expect(
            TransportLatch.rewindTarget(
                playhead: 44_100, totalFrames: 44_100, reachedEnd: true, loopActive: false,
                selectionStart: nil) == 0)
    }

    @Test("a rewind lands on the selection start when there is a selection")
    func rewindsToSelection() {
        #expect(
            TransportLatch.rewindTarget(
                playhead: 44_100, totalFrames: 44_100, reachedEnd: true, loopActive: false,
                selectionStart: 12_000) == 12_000)
    }

    @Test("a playhead parked exactly at the end rewinds even without a prior end-of-file")
    func rewindsFromTheEndPosition() {
        #expect(
            TransportLatch.rewindTarget(
                playhead: 44_100, totalFrames: 44_100, reachedEnd: false, loopActive: false,
                selectionStart: nil) == 0)
    }

    @Test("an active loop never rewinds: the engine wraps into the loop by itself")
    func loopDoesNotRewind() {
        #expect(
            TransportLatch.rewindTarget(
                playhead: 44_100, totalFrames: 44_100, reachedEnd: true, loopActive: true,
                selectionStart: nil) == nil)
    }

    @Test("resuming mid-file does not rewind")
    func midFileResumeHoldsPosition() {
        #expect(
            TransportLatch.rewindTarget(
                playhead: 20_000, totalFrames: 44_100, reachedEnd: false, loopActive: false,
                selectionStart: 12_000) == nil)
    }
}
