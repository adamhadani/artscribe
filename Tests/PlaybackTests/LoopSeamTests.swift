import ArtscribeKit
import AudioDecode
import Foundation  // sin
import Testing
import TimeStretch

@testable import Playback

// MARK: - The loop seam (spec §5.1)
//
// "Never `reset()` the stretcher at a loop boundary" is the most important property in
// this project, so it gets the strongest test that can be written for it.
//
// The two seam tests in `PlaybackPositionTests` bound the *worst single-sample step* of
// the looped render. That statistic was measured to be unreliable: a sweep of thirteen
// realistic loop lengths with a `reset()` forced at the wrap escaped both of them in five
// rows, because a global maximum can only see a click louder than the material's loudest
// natural transient, and a phase-vocoder click is a short burst rather than one extreme
// step. At loopLength 50003 the forced reset actually *lowered* the worst step, to 0.0588
// against the clean render's 0.1744 — a step-only test scores that as better than perfect.
//
// What is measured here instead is the difference against a control, localised to the
// wrap. The control is the key idea: because `feedSource` wraps by feeding continuously,
// the sample stream a *correct* engine pushes into the stretcher when looping `0..<L` is
// byte-for-byte the stream it pushes when playing a source that already has that passage
// laid out end to end. So the two renders must agree — and they do, exactly, at every
// length swept. Anything that interrupts the stretcher at the wrap breaks that agreement
// immediately and by a wide margin.
//
// This has three properties the step metric lacks:
//   * it is phase-independent — a loop length that happens to be a whole number of cycles
//     is tested exactly as hard as one that is not, so no fixture can be flattered;
//   * it is localised — the reported number does not shrink as the loop gets longer, where
//     a whole-render statistic dilutes (the forced reset's whole-render difference RMS
//     falls from 0.289 at L=20000 to 0.078 at L=400003, while the windowed one holds at
//     0.334 throughout);
//   * it has no natural floor to hide under — the clean value is exactly zero.

/// Loop lengths swept, in source frames at 44.1 kHz: 0.20 s to 9.07 s, the range a user
/// actually loops. None is a whole number of cycles of the 220 Hz test tone (that would
/// need a multiple of 2205), so every seam is a genuine discontinuity in the source.
private let sweptLoopLengths = [8837, 20011, 44101, 75007, 133_337, 200_003, 300_007, 400_003]

/// Half-width of the window placed on each wrap, in output frames. Comfortably wider than
/// `.studio`'s 2048-frame start delay, so a stretcher restarted at the wrap cannot hide
/// its re-priming gap just outside the window.
private let seamHalfWindow = 2048

private let seamHz = 220.0
private let seamAmplitude = 0.5

/// `count` frames of the test tone starting at source frame `from`.
private func seamTone(from: Int, count: Int, into pointer: UnsafeMutablePointer<Float>) {
    for i in 0..<count {
        pointer[i] = Float(sin(2 * Double.pi * seamHz * Double(from + i) / 44100) * seamAmplitude)
    }
}

private func seamAudio(frames: Int) -> DecodedAudio {
    let storage = AudioStorage(channels: 1, capacityFrames: frames)
    seamTone(from: 0, count: frames, into: storage.pointer(0))
    return DecodedAudio(
        channels: 1, sampleRate: 44100, frameCount: FrameIndex(frames), storage: storage)
}

/// The loop passage laid out contiguously `times` times — exactly the source stream a
/// correctly wrapping engine feeds the stretcher, expressed as a file that needs no loop.
private func seamTiledAudio(loopLength: Int, times: Int) -> DecodedAudio {
    let storage = AudioStorage(channels: 1, capacityFrames: loopLength * times)
    let p = storage.pointer(0)
    for r in 0..<times { seamTone(from: 0, count: loopLength, into: p + r * loopLength) }
    return DecodedAudio(
        channels: 1, sampleRate: 44100,
        frameCount: FrameIndex(loopLength * times), storage: storage)
}

/// Renders `frames` frames in 512-frame blocks, as the render thread would.
private func seamRender(
    _ audio: DecodedAudio, loop: FrameRange?, frames: Int,
    stretcher: () -> any TimeStretcher
) -> ([Float], UInt64) {
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: audio, stretcher: stretcher(), ring: ring, maxBlock: 512)
    if let loop { ring.push(.setLoop(loop, true)) }
    ring.push(.setPlaying(true))

    var out = [Float](repeating: .nan, count: frames)
    let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)
    table.initialize(to: nil)
    defer {
        table.deinitialize(count: 1)
        table.deallocate()
    }
    out.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var written = 0
        while written < frames {
            let n = min(512, frames - written)
            table[0] = base + written
            _ = engine.render(into: table, frames: n)
            written += n
        }
    }
    return (out, engine.renderStallCount)
}

private func seamRMS(_ values: ArraySlice<Float>) -> Double {
    guard !values.isEmpty else { return 0 }
    return (values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count)).squareRoot()
}

/// What one loop length measured.
private struct SeamMeasurement {
    /// Worst, over every wrap in the render, of the difference's RMS in the window around
    /// that wrap divided by the control's RMS in the same window. Zero means the looped
    /// render and the contiguous control are identical there.
    var worstWindow: Double
    /// Largest single-sample disagreement anywhere in the render.
    var worstSample: Float
    var loopedRMS: Double
    var loopedPeak: Float
    var wraps: Int
    var stalls: UInt64
}

/// Renders `loopLength` both ways and compares them around every wrap.
///
/// `halfWindow` has to exceed the backend's start delay, or a stretcher that re-primes at
/// the wrap can hide its silent gap just outside the window and score zero for it.
/// The stretcher is required rather than defaulted, and the default it lost was
/// `RubberBandStretcher` — which does not exist on iOS. Naming it at each call site is what
/// lets this file's machinery compile for a phone, and therefore what lets the Signalsmith
/// sweep below run on the one platform where Signalsmith is the *only* backend.
private func measureLoopSeam(
    loopLength: Int, halfWindow: Int = seamHalfWindow,
    stretcher: () -> any TimeStretcher
) -> SeamMeasurement {
    // At least one wrap always, several for the short loops, without paying nine seconds
    // of audio per length for the long ones.
    let frames = min(4 * loopLength, loopLength + 4 * halfWindow)
    let (looped, loopedStalls) = seamRender(
        seamAudio(frames: loopLength),
        loop: FrameRange(start: 0, count: FrameIndex(loopLength)), frames: frames,
        stretcher: stretcher)
    let (control, controlStalls) = seamRender(
        seamTiledAudio(loopLength: loopLength, times: frames / loopLength + 2),
        loop: nil, frames: frames, stretcher: stretcher)

    var difference = [Float](repeating: 0, count: frames)
    var worstSample: Float = 0
    var loopedPeak: Float = 0
    for i in 0..<frames {
        difference[i] = looped[i] - control[i]
        worstSample = max(worstSample, abs(difference[i]))
        loopedPeak = max(loopedPeak, abs(looped[i]))
    }

    // The stretcher runs at ratio 1.0 and the engine compensates its start delay, so
    // source frame `w * loopLength` is audible at output frame `w * loopLength`.
    var worstWindow = 0.0
    var wraps = 0
    var wrap = loopLength
    while wrap < frames {
        wraps += 1
        let lo = max(0, wrap - halfWindow)
        let hi = min(frames, wrap + halfWindow)
        let reference = seamRMS(control[lo..<hi])
        if reference > 0 {
            worstWindow = max(worstWindow, seamRMS(difference[lo..<hi]) / reference)
        }
        wrap += loopLength
    }

    return SeamMeasurement(
        worstWindow: worstWindow, worstSample: worstSample,
        loopedRMS: seamRMS(looped[0..<frames]), loopedPeak: loopedPeak,
        wraps: wraps, stalls: loopedStalls + controlStalls)
}

// Rubber Band exists on macOS only — Homebrew builds a macOS dylib and nothing else — so the
// sweep against it is conditional while the Signalsmith sweep below is not. Guarding the test
// rather than the whole file is deliberate: everything above is shared, and the point of this
// change is that the *portable* backend's seam gets proved on the portable platform.
#if canImport(CRubberBand)

/// The single most important property in the product, swept across the loop lengths a
/// user actually works in: looping a passage must sound exactly like playing that passage
/// written out end to end. Nothing may be flushed, re-primed or re-aligned at the wrap.
///
/// Measured on the clean engine: `worstWindow` and `worstSample` are **exactly 0** at
/// every one of these lengths — the two renders agree bit for bit. Against a forced
/// `stretcher.reset()` at the wrap the worst window is 0.334 (95× the bound below) at
/// every length, and against a forced full `restartStream()` it is 0.651 (186×). A
/// one-frame slip at the wrap, which is not a click at all, still scores 0.031 (3×).
@Test func rubberBandLoopingIsIndistinguishableFromAContiguousRender() {
    for loopLength in sweptLoopLengths {
        let m = measureLoopSeam(
            loopLength: loopLength, stretcher: { RubberBandStretcher(core: .finer) })
        let label = "loopLength \(loopLength)"

        // The comparison is only meaningful if there was something to compare, and if the
        // engine really rendered the tone rather than degenerating to silence — which a
        // reset at the wrap of a short loop does, by re-priming faster than it can emit.
        #expect(m.wraps >= 1, "\(label): the render covered no loop wrap")
        #expect(m.stalls == 0, "\(label): \(m.stalls) render stalls")
        #expect(m.loopedPeak > 0.45, "\(label): peak \(m.loopedPeak) — output is not the tone")
        #expect(m.loopedRMS > 0.30, "\(label): rms \(m.loopedRMS) — output is not the tone")

        let seam = "differs from a contiguous render by \(m.worstWindow) of signal RMS"
        #expect(m.worstWindow < 0.01, "\(label): the loop seam \(seam), over \(m.wraps) wrap(s)")
        #expect(
            m.worstSample < 0.01,
            "\(label): worst sample disagreement \(m.worstSample) against a contiguous render")
    }
}

#endif  // canImport(CRubberBand)

/// Signalsmith's start delay, measured: 6615 output frames at 44.1 kHz and ratio 1.0
/// (`inputLatency` 2646 + `outputLatency` 3969). The window has to be wider than that, or a
/// backend that re-primes at the wrap gets to hide the gap outside the window and scores a
/// clean zero for it — which is the one failure this whole file exists to catch.
private let signalsmithHalfWindow = 8192

/// The same property, proved the same way, for the portable backend.
///
/// This is the test that had to exist before the Signalsmith backend could be trusted at
/// all, and it is written as a *substitution* into the existing measurement rather than as
/// a new one: the control, the windowing and the bounds are the ones Rubber Band is held
/// to, so the two backends are being asked the same question. That is only possible
/// because `SignalsmithStretcher` fakes the push/pull shape behind `TimeStretcher` instead
/// of teaching `PlaybackEngine` a second render path — see the class's doc comment.
///
/// Measured: `worstWindow` and `worstSample` are **exactly 0** at every length swept, the
/// same as Rubber Band. Signalsmith is fed continuously across the wrap by the same
/// `feedSource`, so the two renders agree bit for bit.
///
/// Mutation-tested rather than assumed. With `stretcher.reset()` forced at the wrap in
/// `feedSource`, this test reports 17 issues and `worstWindow` scores 0.635 at seven of the
/// eight lengths and 0.891 at the shortest — 64× to 89× the bound — with the shortest loop
/// additionally collapsing below the "output is not the tone" floor, because re-priming
/// 6615 frames every 8837 frames leaves almost nothing to emit.
///
/// Do not replace this with a worst-single-sample-step bound. The header of this file
/// records why that shape was abandoned; it is no more reliable against a phase vocoder
/// from Signalsmith than against one from Rubber Band.
@Test func signalsmithLoopingIsIndistinguishableFromAContiguousRender() {
    for loopLength in sweptLoopLengths {
        let m = measureLoopSeam(
            loopLength: loopLength, halfWindow: signalsmithHalfWindow,
            stretcher: { SignalsmithStretcher() })
        let label = "loopLength \(loopLength)"

        #expect(m.wraps >= 1, "\(label): the render covered no loop wrap")
        #expect(m.stalls == 0, "\(label): \(m.stalls) render stalls")
        #expect(m.loopedPeak > 0.45, "\(label): peak \(m.loopedPeak) — output is not the tone")
        #expect(m.loopedRMS > 0.30, "\(label): rms \(m.loopedRMS) — output is not the tone")

        let seam = "differs from a contiguous render by \(m.worstWindow) of signal RMS"
        #expect(m.worstWindow < 0.01, "\(label): the loop seam \(seam), over \(m.wraps) wrap(s)")
        #expect(
            m.worstSample < 0.01,
            "\(label): worst sample disagreement \(m.worstSample) against a contiguous render")
    }
}
