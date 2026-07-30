import Accelerate
import ArtscribeKit
import Foundation  // log, log2, sin
import Testing

@testable import TimeStretch

@Test func identityStretcherPassesSamplesThroughUnchanged() {
    let input = sine(freq: 440, seconds: 0.5, sampleRate: 44100)
    let out = runStretcher(IdentityStretcher(), input: input, sampleRate: 44100)
    #expect(out.count == input.count)
    for i in stride(from: 0, to: input.count, by: 97) {
        #expect(abs(out[i] - input[i]) < 1e-6)
    }
}

@Test func identityStretcherHasNoStartDelay() {
    let s = IdentityStretcher()
    s.configure(sampleRate: 44100, channels: 1, maxBlock: 512)
    #expect(s.startDelay == 0)
}

/// Retrieving fewer frames than are buffered shifts the unread tail down to
/// index 0. When more than half the buffer is still unread, source and
/// destination of that shift overlap — this must use memmove semantics, not
/// memcpy, or the tail gets corrupted.
@Test func identityStretcherPartialRetrieveWithOverlappingTailSurvivesIntact() {
    let s = IdentityStretcher()
    s.configure(sampleRate: 44100, channels: 1, maxBlock: 128)
    let ramp: [Float] = (0..<100).map { Float($0) }

    ramp.withUnsafeBufferPointer { buf in
        let channelPtrs = [buf.baseAddress]
        channelPtrs.withUnsafeBufferPointer { ptrs in
            guard let base = ptrs.baseAddress else { return }
            s.process(base, frames: 100, final: false)
        }
    }
    #expect(s.available() == 100)

    var expected = 0
    var scratch = [Float](repeating: -1, count: 10)
    while s.available() > 0 {
        let got = scratch.withUnsafeMutableBufferPointer { buf -> Int in
            var channelPtrs: [UnsafeMutablePointer<Float>?] = [buf.baseAddress]
            return channelPtrs.withUnsafeMutableBufferPointer { ptrs in
                guard let base = ptrs.baseAddress else { return 0 }
                return s.retrieve(base, frames: 10)
            }
        }
        #expect(got == 10, "expected a full 10-frame retrieve")
        for i in 0..<got {
            #expect(scratch[i] == Float(expected + i))
        }
        expected += got
    }
    #expect(expected == 100)
}

/// Measured with `estimateFrequencyFFT` (Hann-windowed FFT peak, quadratically
/// interpolated — spec §9's method) at ratio 2.0 (half speed), start delay +
/// 8192-frame margin discarded, 6 s input per point:
///
/// | freq (Hz) | .studio (cents) | .fast (cents) |
/// |-----------|------------------|----------------|
/// | 220       | -0.009           | -15.581        |
/// | 300       | (not swept here) | -25.948        |
/// | 330       | -0.012           | -0.007         |
/// | 440       |  0.0005          | +16.271        |
/// | 660       |  0.007           | +0.011         |
/// | 880       | -0.0002          | -0.0002        |
///
/// `.studio` (R3 "Finer") holds pitch to a small fraction of a cent everywhere
/// tested — it is the product's quality core and earns the tight ±2 cent bound.
/// `.fast` (R2 "Faster") shows a genuine, frequency- and ratio-dependent pitch
/// wobble — reproduced independently against the raw C API (bypassing this
/// wrapper entirely) and by an independent standalone-C-program review, so this
/// is an inherent property of the R2 phase vocoder, not a wiring defect or a
/// measurement artifact. A wider informal scan (200-900 Hz in 20 Hz steps, same
/// ratio) found the true worst case at 300 Hz: -25.95 cents. `.fast`'s bound
/// below (±30 cents) is set from that broader scan plus margin, not merely from
/// the handful of points asserted here, so it isn't tuned to one lucky sample.
@Test(
    arguments: [StretchEngine.studio, StretchEngine.fast],
    [220.0, 300.0, 330.0, 440.0, 660.0, 880.0]
)
func halfSpeedPreservesPitch(engine: StretchEngine, freq: Double) {
    let rate = 44100.0
    let input = sine(freq: freq, seconds: 6, sampleRate: rate)
    let s = RubberBandStretcher(engine: engine)
    s.timeRatio = 2.0  // half speed => twice as long
    var out = runStretcher(s, input: input, sampleRate: rate)

    // Discard the engine's start delay plus a safety margin before measuring.
    let skip = Swift.min(out.count, s.startDelay + 8192)
    out.removeFirst(skip)
    #expect(out.count > Int(rate * 4))

    let measured = estimateFrequencyFFT(out, sampleRate: rate)
    let cents = 1200 * log2(measured / freq)
    // See the measured table above the @Test attribute for where these two
    // numbers come from. `.studio` is not weakened; `.fast` is deliberately
    // wider because pitch accuracy is a real trade-off it makes for CPU, not a
    // test convenience — see RubberBandStretcher's engine-selection comment.
    let tolerance = engine == .studio ? 2.0 : 30.0
    #expect(abs(cents) < tolerance, "pitch drifted \(cents) cents (measured \(measured) Hz)")
}

/// The other end of `SpeedState`'s range. `halfSpeedPreservesPitch` covers 50%,
/// which the acceptance checklist names explicitly; **200% had no coverage at
/// all**, so a pitch regression at the top of the range could only have been
/// caught by ear.
///
/// Measured the same way (Hann-windowed FFT peak, quadratically interpolated;
/// start delay + 8192 frames discarded; 8 s input per point) at ratio 0.5:
///
/// - `.studio` holds pitch to a small fraction of a cent at every point tested,
///   exactly as it does at ratio 2.0. The product's quality claim is intact.
/// - `.fast` is **much worse here than at half speed**. A 200–900 Hz sweep in
///   20 Hz steps found: 220 Hz −108.5 c, 200 Hz −93.8 c, 340 Hz +72.8 c,
///   300 Hz +58.3 c, 360 Hz −51.5 c, and under 15 c above about 500 Hz. The
///   worst case is more than a semitone, against ~26 cents at ratio 2.0. Trimming
///   the final flush from the measurement changes nothing, so it is not a tail
///   artefact — it is R2's phase vocoder, whose drift is both frequency- and
///   ratio-dependent, being pushed harder by compression than by expansion.
///
/// The `.fast` bound below is therefore a **regression fence around a measured
/// defect, not a quality claim**: it is set from that sweep's worst case plus
/// margin, and a bound of ±120 cents should not be read as "a semitone of drift
/// is acceptable". `.studio` is the default and is the engine any pitch-critical
/// listening should use above 100% speed.
@Test(
    arguments: [StretchEngine.studio, StretchEngine.fast],
    [220.0, 330.0, 440.0, 660.0, 880.0]
)
func doubleSpeedPreservesPitch(engine: StretchEngine, freq: Double) {
    let rate = 44100.0
    let input = sine(freq: freq, seconds: 8, sampleRate: rate)
    let s = RubberBandStretcher(engine: engine)
    s.timeRatio = 0.5  // double speed => half as long
    var out = runStretcher(s, input: input, sampleRate: rate)

    let skip = Swift.min(out.count, s.startDelay + 8192)
    out.removeFirst(skip)
    #expect(out.count > Int(rate * 2))

    let measured = estimateFrequencyFFT(out, sampleRate: rate)
    let cents = 1200 * log2(measured / freq)
    let tolerance = engine == .studio ? 2.0 : 120.0
    #expect(abs(cents) < tolerance, "pitch drifted \(cents) cents (measured \(measured) Hz)")
}

@Test func halfSpeedRoughlyDoublesLength() {
    let rate = 44100.0
    let input = sine(freq: 440, seconds: 4, sampleRate: rate)
    let s = RubberBandStretcher(engine: .studio)
    s.timeRatio = 2.0
    let out = runStretcher(s, input: input, sampleRate: rate)
    let ratio = Double(out.count) / Double(input.count)
    #expect(abs(ratio - 2.0) < 0.05, "expected ~2x length, got \(ratio)x")
}

@Test func doubleSpeedRoughlyHalvesLength() {
    let rate = 44100.0
    let input = sine(freq: 440, seconds: 4, sampleRate: rate)
    let s = RubberBandStretcher(engine: .studio)
    s.timeRatio = 0.5
    let out = runStretcher(s, input: input, sampleRate: rate)
    let ratio = Double(out.count) / Double(input.count)
    #expect(abs(ratio - 0.5) < 0.05, "expected ~0.5x length, got \(ratio)x")
}

@Test func outputContainsNoNaNOrInfinity() {
    let input = sine(freq: 440, seconds: 2, sampleRate: 44100)
    let s = RubberBandStretcher(engine: .studio)
    s.timeRatio = 3.0
    let out = runStretcher(s, input: input, sampleRate: 44100)
    #expect(out.allSatisfy { $0.isFinite })
}

@Test func studioEngineReportsNonZeroStartDelay() {
    let s = RubberBandStretcher(engine: .studio)
    s.configure(sampleRate: 44100, channels: 2, maxBlock: 1024)
    #expect(s.startDelay > 0)
}
