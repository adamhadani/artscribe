import ArtscribeKit
import AudioDecode
import Testing
import TimeStretch

@testable import Playback

// MARK: - Transport

@Test func stoppedEngineRendersSilence() {
    let ring = CommandRing(capacity: 8)
    let engine = PlaybackEngine(
        audio: makeRampAudio(frames: 1000),
        stretcher: IdentityStretcher(), ring: ring, maxBlock: 256)
    let out = render(engine, frames: 128)
    #expect(out.allSatisfy { $0 == 0 })
}

@Test func playsSourceFramesInOrderFromTheStart() {
    let (engine, _) = makeEngine()
    let out = render(engine, frames: 256)
    #expect(out[0] == 0)
    #expect(out[100] == 100)
    #expect(out[255] == 255)
}

@Test func everyChannelCarriesItsOwnSource() {
    let (engine, _) = makeEngine(channels: 2)
    let out = renderChannels(engine, frames: 256, channels: 2)
    #expect(out[0][100] == 100)
    #expect(out[1][100] == 100 + channelStride)
}

@Test func seekJumpsToExactFrame() {
    let (engine, ring) = makeEngine()
    ring.push(.seek(5000))
    let out = render(engine, frames: 64)
    #expect(out[0] == 5000)
    #expect(out[63] == 5063)
}

@Test func speedChangeMidStreamIsAppliedWithoutDroppingFrames() {
    let (engine, ring) = makeEngine()
    let first = render(engine, frames: 128)
    ring.push(.setTimeRatio(2.0))
    let second = render(engine, frames: 128)
    #expect(first[0] == 0)
    // IdentityStretcher ignores the ratio, so continuity is what is under test:
    // no gap and no repeat across the command boundary.
    #expect(second[0] == 128)
}

@Test func outputIsAlwaysFinite() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 0, count: 777), true))
    let out = render(engine, frames: 8192)
    #expect(out.allSatisfy { $0.isFinite })
}

/// CoreAudio can hand down a zero-frame quantum; it must not touch the buffer or trap.
@Test func aZeroFrameRenderIsANoOp() {
    let (engine, ring) = makeEngine()
    ring.push(.seek(700))
    let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)
    table.initialize(to: nil)
    #expect(engine.render(into: table, frames: 0) == 0)
    #expect(engine.currentFrame == 700)
    table.deinitialize(count: 1)
    table.deallocate()
}

// MARK: - Looping

@Test func loopWrapsAtExactSampleBoundary() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), true))
    ring.push(.seek(1000))
    let out = render(engine, frames: 250)

    #expect(out[0] == 1000)
    #expect(out[99] == 1099)
    // Must wrap to loop start on the very next frame — no gap, no repeat.
    #expect(out[100] == 1000)
    #expect(out[199] == 1099)
    #expect(out[200] == 1000)
}

@Test func loopedPlaybackNeverLeavesTheLoopRegion() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 2000, count: 500), true))
    ring.push(.seek(2000))
    let out = render(engine, frames: 4000)
    #expect(out.allSatisfy { $0 >= 2000 && $0 < 2500 })
}

@Test func disablingLoopPlaysStraightThrough() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), false))
    ring.push(.seek(1050))
    let out = render(engine, frames: 200)
    #expect(out[0] == 1050)
    #expect(out[199] == 1249)  // sails past the disabled loop end
}

/// A loop far shorter than one feed block must wrap many times inside a single
/// `feedSource` call without spinning, double-wrapping, or skipping a frame.
@Test func loopShorterThanOneFeedBlockWrapsRepeatedly() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 10, count: 7), true))
    ring.push(.seek(10))
    let out = render(engine, frames: 300)
    for i in 0..<300 {
        #expect(out[i] == Float(10 + i % 7), "frame \(i)")
    }
}

/// A loop set entirely *behind* the cursor must fall into it on the next feed
/// rather than reading past the end of the region.
@Test func loopSetBehindTheCursorWrapsIntoItImmediately() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), true))
    ring.push(.seek(5000))
    let out = render(engine, frames: 200)
    #expect(out[0] == 1000)
    #expect(out[99] == 1099)
    #expect(out[100] == 1000)
}

/// A loop set entirely *ahead* of the cursor plays through into it, then loops —
/// enabling a loop must not teleport the playhead (`loop.restart` is a separate action).
@Test func loopSetAheadOfTheCursorPlaysIntoIt() {
    let (engine, ring) = makeEngine()
    ring.push(.seek(0))
    ring.push(.setLoop(FrameRange(start: 500, count: 100), true))
    let out = render(engine, frames: 700)
    #expect(out[0] == 0)
    #expect(out[599] == 599)
    #expect(out[600] == 500)
    #expect(out[699] == 599)
}

// MARK: - End of file

@Test func stopsAtEndOfFileWithoutOverrunning() {
    let (engine, ring) = makeEngine(frames: 1000)
    ring.push(.seek(900))
    let out = render(engine, frames: 400)
    #expect(out[0] == 900)
    #expect(out[99] == 999)
    // Past the end: silence, not garbage and not a crash.
    #expect(out[150] == 0)
    #expect(!engine.isPlaying)
}

/// Concern 4: the stretcher must be told the stream ended, or its tail — the last
/// fraction of a second of the file — is never flushed.
@Test func endOfStreamTailIsFlushed() {
    let stretcher = FakeStretcher(tail: 64)
    let (engine, ring) = makeFakeEngine(stretcher, frames: 1000)
    ring.push(.seek(900))
    let out = render(engine, frames: 400)
    #expect(out[99] == 999)
    #expect(out[100] == FakeStretcher.tailMarker)
    #expect(out[163] == FakeStretcher.tailMarker)
    #expect(out[164] == 0)
    #expect(!engine.isPlaying)
}

/// After the stream has been finalised, a seek must re-prime it rather than leaving
/// the engine permanently unable to play.
@Test func seekAfterEndOfFileResumesPlayback() {
    let (engine, ring) = makeEngine(frames: 1000)
    ring.push(.seek(900))
    _ = render(engine, frames: 400)
    #expect(!engine.isPlaying)

    ring.push(.seek(100))
    ring.push(.setPlaying(true))
    let out = render(engine, frames: 128)
    #expect(out[0] == 100)
    #expect(out[127] == 227)
    #expect(engine.isPlaying)
}

/// Enabling a loop after the stream was finalised must revive it, not leave the
/// engine stuck at the end of the file.
@Test func enablingALoopAfterEndOfFileResumesPlayback() {
    let (engine, ring) = makeEngine(frames: 1000)
    ring.push(.seek(900))
    _ = render(engine, frames: 400)

    ring.push(.setLoop(FrameRange(start: 100, count: 50), true))
    ring.push(.setPlaying(true))
    let out = render(engine, frames: 200)
    #expect(out[0] == 100)
    #expect(out[50] == 100)
    #expect(out.allSatisfy { $0 >= 100 && $0 < 150 })
}
