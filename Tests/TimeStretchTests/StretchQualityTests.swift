import Accelerate
import ArtscribeKit
import Foundation  // log, log2, sin
import Testing

@testable import TimeStretch

/// Estimates a pure tone's frequency via FFT peak (spec §9's specified method),
/// refined with quadratic interpolation of the log-magnitude around the peak bin
/// for sub-bin precision. Uses the largest power-of-two window that fits the
/// input, windowed with a Hann function to suppress spectral leakage.
private func estimateFrequencyFFT(_ samples: [Float], sampleRate: Double) -> Double {
    var n = 1
    var log2n: vDSP_Length = 0
    while n * 2 <= samples.count {
        n *= 2
        log2n += 1
    }
    guard n >= 1024, let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return 0
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var windowed = [Float](repeating: 0, count: n)
    samples.withUnsafeBufferPointer { sp in
        guard let sBase = sp.baseAddress else { return }
        vDSP_vmul(sBase, 1, window, 1, &windowed, 1, vDSP_Length(n))
    }

    var realp = [Float](repeating: 0, count: n / 2)
    var imagp = [Float](repeating: 0, count: n / 2)
    var magnitudes = [Float](repeating: 0, count: n / 2)

    let peakBin: Int = realp.withUnsafeMutableBufferPointer { realPtr in
        imagp.withUnsafeMutableBufferPointer { imagPtr in
            guard let rBase = realPtr.baseAddress, let iBase = imagPtr.baseAddress else {
                return 0
            }
            var splitComplex = DSPSplitComplex(realp: rBase, imagp: iBase)
            windowed.withUnsafeBufferPointer { wp in
                guard let wBase = wp.baseAddress else { return }
                wBase.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n / 2))
                }
            }
            vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(n / 2))
            var bin = 1
            var peakVal: Float = -1
            for i in 1..<(n / 2 - 1) where magnitudes[i] > peakVal {
                peakVal = magnitudes[i]
                bin = i
            }
            return bin
        }
    }
    guard peakBin > 0, peakBin < magnitudes.count - 1 else { return 0 }

    // Quadratic (parabolic) interpolation of the log-magnitude spectrum around
    // the peak bin resolves the true peak location to a fraction of a bin.
    let m1 = log(Double(magnitudes[peakBin - 1]) + 1e-12)
    let m0 = log(Double(magnitudes[peakBin]) + 1e-12)
    let m2 = log(Double(magnitudes[peakBin + 1]) + 1e-12)
    let denom = m1 - 2 * m0 + m2
    let delta = denom != 0 ? 0.5 * (m1 - m2) / denom : 0
    let refinedBin = Double(peakBin) + delta
    return refinedBin * sampleRate / Double(n)
}

private func sine(freq: Double, seconds: Double, sampleRate: Double) -> [Float] {
    let n = Int(seconds * sampleRate)
    return (0..<n).map { Float(sin(2 * Double.pi * freq * Double($0) / sampleRate)) }
}

/// Pushes mono input through a stretcher and collects all output.
private func runStretcher(
    _ s: TimeStretcher, input: [Float],
    sampleRate: Double, block: Int = 1024
) -> [Float] {
    // Mono only. A single-element array of channel pointers is built explicitly
    // below (rather than reinterpreting the address of one scalar pointer
    // variable as if it were an array) so this generalises safely if a future
    // caller extends it to more channels; the scalar-address trick only "works"
    // by coincidence for channel count 1 and is a stack-buffer-overflow for any
    // channel index beyond that (confirmed under AddressSanitizer).
    let channels = 1
    s.configure(sampleRate: sampleRate, channels: channels, maxBlock: block)
    var out: [Float] = []
    var scratch = [Float](repeating: 0, count: block * 8)
    var offset = 0

    func drain() {
        while s.available() > 0 {
            let want = Swift.min(s.available(), scratch.count)
            let got = scratch.withUnsafeMutableBufferPointer { buf -> Int in
                var channelPtrs = [UnsafeMutablePointer<Float>?](
                    repeating: buf.baseAddress, count: channels)
                return channelPtrs.withUnsafeMutableBufferPointer { ptrs in
                    guard let base = ptrs.baseAddress else { return 0 }
                    return s.retrieve(base, frames: want)
                }
            }
            guard got > 0 else { break }
            out.append(contentsOf: scratch[0..<got])
        }
    }

    while offset < input.count {
        let n = Swift.min(block, input.count - offset)
        input.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let channelPtrs = [UnsafePointer<Float>?](repeating: base + offset, count: channels)
            channelPtrs.withUnsafeBufferPointer { ptrs in
                guard let base = ptrs.baseAddress else { return }
                s.process(base, frames: n, final: offset + n >= input.count)
            }
        }
        offset += n
        drain()
    }
    drain()
    return out
}

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
