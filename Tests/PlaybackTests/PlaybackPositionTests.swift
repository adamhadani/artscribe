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

/// A stretcher handed over already carrying an out-of-range ratio must be *corrected*, not
/// merely ignored. Sanitizing into `timeRatio` without writing back would leave the
/// stretcher stretching at the caller's value while the position accounting ran at 1.0.
@Test func aPreSetOutOfRangeStretcherRatioIsWrittenBack() {
    let stretcher = IdentityStretcher()
    stretcher.timeRatio = 100  // far outside SpeedState's range
    let ring = CommandRing(capacity: 8)
    let engine = PlaybackEngine(
        audio: makeRampAudio(frames: 10_000), stretcher: stretcher, ring: ring, maxBlock: 512)
    #expect(stretcher.timeRatio == 1.0)
    #expect(engine.rejectedCommandCount == 1)
}

@Test func aPreSetInRangeStretcherRatioIsLeftAlone() {
    let stretcher = IdentityStretcher()
    stretcher.timeRatio = 2.0  // half speed, in range
    let ring = CommandRing(capacity: 8)
    let engine = PlaybackEngine(
        audio: makeRampAudio(frames: 10_000), stretcher: stretcher, ring: ring, maxBlock: 512)
    #expect(stretcher.timeRatio == 2.0)
    #expect(engine.rejectedCommandCount == 0)
}

// MARK: - Real stretcher
//
// Guarded from here down: everything above drives `IdentityStretcher` and deliberate fakes,
// which is exactly the part worth running on a phone, and everything below needs Rubber Band.

#if canImport(CRubberBand)

private let sineHz = 220.0
private let sineAmplitude = 0.5

/// The analytic maximum sample-to-sample step of the test sine: `A·2πf/rate`. Every seam
/// bound below is expressed as a multiple of this rather than as a round number, so the
/// margin is explicit instead of implied.
private let analyticStep = Float(sineAmplitude * 2 * Double.pi * sineHz / 44100)  // 0.015672

private func makeSineAudio(frames: Int) -> DecodedAudio {
    let storage = AudioStorage(channels: 1, capacityFrames: frames)
    for i in 0..<frames {
        storage.pointer(0)[i] =
            Float(sin(2 * Double.pi * sineHz * Double(i) / 44100) * sineAmplitude)
    }
    return DecodedAudio(
        channels: 1, sampleRate: 44100, frameCount: FrameIndex(frames), storage: storage)
}

private func worstStep(_ out: [Float]) -> Float {
    var worst: Float = 0
    for i in 1..<out.count { worst = max(worst, abs(out[i] - out[i - 1])) }
    return worst
}

private func peak(_ out: [Float]) -> Float { out.reduce(0) { max($0, abs($1)) } }

private func rms(_ out: [Float]) -> Double {
    (out.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(out.count)).squareRoot()
}

/// Asserts the output really is the test sine and not silence or a fragment of it.
///
/// This is not padding. Measured: resetting the stretcher at the boundary of a *short*
/// loop makes the engine re-prime so often it never emits anything at all — the output is
/// digital silence, whose worst sample-to-sample step is exactly `0`. A step-only
/// assertion scores that as the best possible result and passes. The floor is what
/// actually catches that failure.
private func expectIsTheSine(_ out: [Float], _ label: String) {
    #expect(out.allSatisfy { $0.isFinite }, "\(label): non-finite output")
    #expect(peak(out) > 0.45, "\(label): peak \(peak(out)) — output is not the sine")
    #expect(rms(out) > 0.30, "\(label): rms \(rms(out)) — output is not the sine")
}

/// The single most important property in the product: looping the same passage fifty
/// times must not tick even once.
///
/// The loop is **exactly 110 cycles** of 220 Hz, so a perfect engine emits an unbroken
/// sine and any step above the sine's own is attributable to the engine alone. That is
/// what buys the tight bound: measured worst step is **0.015690**, against an analytic
/// step of 0.015672 — the engine contributes **0.1%**. The bound is set at 2× analytic
/// (0.031), leaving 2× headroom while still failing a 0.05 tick that a looser threshold
/// would wave through. `rubberBandLoopDoesNotAmplifyADiscontinuousSeam` covers the case
/// this fixture cannot: a seam the source itself breaks.
@Test func rubberBandLoopProducesNoDiscontinuityAtTheSeam() {
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: makeSineAudio(frames: 44100),
        stretcher: RubberBandStretcher(core: .finer),
        ring: ring, maxBlock: 512)
    ring.push(.setLoop(FrameRange(start: 0, count: 22050), true))  // 110 whole cycles
    ring.push(.setPlaying(true))

    let out = render(engine, frames: 88200)
    expectIsTheSine(out, "seam")
    #expect(engine.renderStallCount == 0)
    let worst = worstStep(out)
    #expect(worst < 2 * analyticStep, "loop seam discontinuity of \(worst)")
}

/// A loop whose length is *not* a whole number of cycles: the source seam is genuinely
/// broken, as it is for any real musical passage, so the stretcher has real work to do
/// and cannot be flattered by a phase-aligned fixture.
///
/// The engine cannot remove the source's own discontinuity, so the assertion is that it
/// does not *amplify* it. Measured: source seam step 0.14056, output worst step 0.14011 —
/// the engine reproduces it slightly smoothed (0.997×), adding nothing.
@Test func rubberBandLoopDoesNotAmplifyADiscontinuousSeam() {
    let audio = makeSineAudio(frames: 44100)
    let loopLength = 4001  // 19.96 cycles — deliberately not a whole number
    let sourceSeamStep = abs(audio.channel(0)[0] - audio.channel(0)[loopLength - 1])
    // Guards the fixture against silently degenerating into the phase-aligned case above
    // if anyone edits `loopLength` or the frequency.
    #expect(sourceSeamStep > 5 * analyticStep, "fixture seam is not discontinuous")

    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: audio, stretcher: RubberBandStretcher(core: .finer),
        ring: ring, maxBlock: 512)
    ring.push(.setLoop(FrameRange(start: 0, count: FrameIndex(loopLength)), true))
    ring.push(.setPlaying(true))

    let out = render(engine, frames: 88200)
    expectIsTheSine(out, "discontinuous seam")
    #expect(engine.renderStallCount == 0)
    let worst = worstStep(out)
    #expect(
        worst < sourceSeamStep * 1.1,
        "engine amplified the seam: \(worst) vs source \(sourceSeamStep)")
}

/// With a real stretcher's latency the reported position must stay behind the feed
/// cursor and inside the loop region — the failure mode is a playhead drawn to the
/// right of the note being heard.
@Test func rubberBandPositionStaysInsideTheLoop() {
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: makeSineAudio(frames: 44100),
        stretcher: RubberBandStretcher(core: .finer),
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
        stretcher: RubberBandStretcher(core: .finer),
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

#endif  // canImport(CRubberBand)
