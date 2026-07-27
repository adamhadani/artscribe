import ArtscribeKit
import AudioDecode
import Foundation  // sin
import Testing
import TimeStretch

@testable import Playback

// MARK: - Audible position (concern 1)

/// The playhead must report the *audible* source frame, not the feed cursor.
/// With `maxBlock` 512 the engine has fed 512 source frames after rendering 128,
/// but only 128 of them have been heard.
@Test func positionReportsAudibleFrameNotFeedCursor() {
    let (engine, ring) = makeEngine()
    ring.push(.seek(3000))
    _ = render(engine, frames: 128)
    #expect(engine.currentFrame == 3128)
}

@Test func positionAdvancesExactlyWithOutput() {
    let (engine, ring) = makeEngine()
    ring.push(.seek(3000))
    _ = render(engine, frames: 512)
    #expect(engine.currentFrame == 3512)
    _ = render(engine, frames: 200)
    #expect(engine.currentFrame == 3712)
}

/// Inside a loop the compensation has to walk *backwards through the wrap*, because
/// the source position of already-emitted output is not `cursor - backlog`.
@Test func positionInsideALoopRewindsThroughTheWrap() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), true))
    ring.push(.seek(1000))
    let out = render(engine, frames: 250)
    // 250 frames emitted from a 100-frame loop starting at 1000: the next frame
    // to be heard is 1050, and the reported position must say so.
    #expect(out[249] == 1049)
    #expect(engine.currentFrame == 1050)
}

@Test func positionFollowsASeekWhilePaused() {
    let ring = CommandRing(capacity: 8)
    let engine = PlaybackEngine(
        audio: makeRampAudio(frames: 10_000),
        stretcher: IdentityStretcher(), ring: ring, maxBlock: 512)
    ring.push(.seek(4242))
    _ = render(engine, frames: 128)
    #expect(engine.currentFrame == 4242)
}

/// Concern 3: priming must be discarded exactly, and must not leak into the output
/// or shift the reported position.
@Test func startDelayPrimingIsDiscardedExactly() {
    let stretcher = FakeStretcher(delay: 300)
    let (engine, _) = makeFakeEngine(stretcher)
    let out = render(engine, frames: 256)
    #expect(out[0] == 0)
    #expect(out[255] == 255)
    #expect(!out.contains(FakeStretcher.primingMarker))
    #expect(engine.currentFrame == 256)
}

// MARK: - Stall backstop (concern 2)

/// A stretcher that reports output it will not hand over must be *observable*, not
/// silently papered over.
@Test func aRefusedRetrieveIsCountedAsAStall() {
    let stretcher = FakeStretcher(refusesRetrieve: true)
    let (engine, _) = makeFakeEngine(stretcher)
    let out = render(engine, frames: 128)
    #expect(out.allSatisfy { $0 == 0 })
    #expect(engine.renderStallCount == 1)
    let second = render(engine, frames: 128)
    #expect(second.allSatisfy { $0 == 0 })
    #expect(engine.renderStallCount == 2)
}

/// A stretcher that consumes input forever and never produces output must trip the
/// iteration backstop, fill the block with silence, and say so.
@Test func aStretcherThatNeverProducesOutputTripsTheBackstop() {
    let stretcher = FakeStretcher(swallowsInput: true)
    let (engine, ring) = makeFakeEngine(stretcher)
    ring.push(.setLoop(FrameRange(start: 0, count: 1000), true))
    let out = render(engine, frames: 128)
    #expect(out.allSatisfy { $0 == 0 })
    #expect(engine.renderStallCount == 1)
}

/// A non-finite time ratio would poison the position arithmetic (and trap on the
/// `Double` → `Int64` conversion). It must be rejected and counted, not applied.
@Test func aNonFiniteTimeRatioIsRejectedAndCounted() {
    let (engine, ring) = makeEngine()
    ring.push(.setTimeRatio(.nan))
    let out = render(engine, frames: 128)
    #expect(out[0] == 0)
    #expect(out[127] == 127)
    #expect(engine.currentFrame == 128)
    #expect(engine.rejectedCommandCount == 1)
}

/// A time ratio outside `SpeedState`'s range is likewise refused rather than applied.
@Test func anOutOfRangeTimeRatioIsRejectedAndCounted() {
    let (engine, ring) = makeEngine()
    ring.push(.setTimeRatio(1000))
    _ = render(engine, frames: 128)
    #expect(engine.rejectedCommandCount == 1)
    #expect(engine.currentFrame == 128)
}

// MARK: - Real stretcher

private func makeSineAudio(frames: Int) -> DecodedAudio {
    let storage = AudioStorage(channels: 1, capacityFrames: frames)
    for i in 0..<frames {
        storage.pointer(0)[i] = Float(sin(2 * Double.pi * 220 * Double(i) / 44100)) * 0.5
    }
    return DecodedAudio(
        channels: 1, sampleRate: 44100, frameCount: FrameIndex(frames), storage: storage)
}

@Test func rubberBandLoopProducesNoDiscontinuityAtTheSeam() {
    // A real stretcher over a smooth sine: the loop seam must not click.
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: makeSineAudio(frames: 44100),
        stretcher: RubberBandStretcher(engine: .studio),
        ring: ring, maxBlock: 512)
    ring.push(.setLoop(FrameRange(start: 0, count: 22050), true))
    ring.push(.setPlaying(true))

    let out = render(engine, frames: 88200)
    #expect(out.allSatisfy { $0.isFinite })
    #expect(engine.renderStallCount == 0)
    // No sample-to-sample jump larger than a fifth of full scale.
    var worst: Float = 0
    for i in 1..<out.count { worst = max(worst, abs(out[i] - out[i - 1])) }
    #expect(worst < 0.2, "loop seam discontinuity of \(worst)")
}

/// With a real stretcher's latency the reported position must stay behind the feed
/// cursor and inside the loop region — the failure mode is a playhead drawn to the
/// right of the note being heard.
@Test func rubberBandPositionStaysInsideTheLoop() {
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: makeSineAudio(frames: 44100),
        stretcher: RubberBandStretcher(engine: .studio),
        ring: ring, maxBlock: 512)
    ring.push(.setLoop(FrameRange(start: 10_000, count: 4000), true))
    ring.push(.seek(10_000))
    ring.push(.setPlaying(true))

    for _ in 0..<40 {
        _ = render(engine, frames: 512)
        #expect(engine.currentFrame >= 10_000)
        #expect(engine.currentFrame <= 14_000)
    }
}

/// At half speed the source advances at half the rate of the output. The audible
/// position must reflect that, and must never run ahead of the feed cursor.
@Test func rubberBandPositionTracksHalfSpeedPlayback() {
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: makeSineAudio(frames: 44100),
        stretcher: RubberBandStretcher(engine: .studio),
        ring: ring, maxBlock: 512)
    ring.push(.setTimeRatio(2.0))  // half speed
    ring.push(.setPlaying(true))

    var outputFrames = 0
    for _ in 0..<20 {
        _ = render(engine, frames: 512)
        outputFrames += 512
    }
    // 10240 output frames at half speed ≈ 5120 source frames consumed. Rubber Band's
    // real-time ratio tracking is approximate over short spans, so allow ±10%.
    let expected = Double(outputFrames) / 2
    #expect(Double(engine.currentFrame) > expected * 0.9)
    #expect(Double(engine.currentFrame) < expected * 1.1)
}
