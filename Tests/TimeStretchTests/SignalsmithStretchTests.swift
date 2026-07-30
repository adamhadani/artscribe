import ArtscribeKit
import Foundation  // log2, sin
import Testing

@testable import TimeStretch

// The portable backend (MIT). The loop-seam property — the one that matters most — is
// proved in `PlaybackTests/LoopSeamTests`, where the engine that does the wrapping lives.
// What is measured here is everything a stretcher owes on its own: pitch, length, and the
// latency it reports about itself.

/// Signalsmith's pitch accuracy, measured with the same Hann-windowed FFT estimator that
/// bounds Rubber Band (spec §9's method), start delay + 8192 frames of margin discarded,
/// 6 s of input per point:
///
/// | freq (Hz) | ratio 2.0 (cents) | ratio 0.5 (cents) |
/// |-----------|-------------------|-------------------|
/// | 220       | -0.027            | -0.027            |
/// | 300       | -0.050            | -0.050            |
/// | 330       | +0.041            | +0.041            |
/// | 440       | -0.026            | -0.026            |
/// | 660       | -0.024            | -0.024            |
/// | 880       | -0.021            | -0.021            |
///
/// Two things are worth reading off that table beyond the headline.
///
/// The error is the **same at both ratios**, to five decimal places, and the same for both
/// quality presets (-0.0257 standard, -0.0262 cheaper at 440 Hz / ratio 2.0). A stretcher
/// artefact would move with the ratio; this does not. It is the estimator's own bias on
/// each frequency — the floor of the ruler, not the thing being measured. So the true error
/// is *below* these numbers, not equal to them.
///
/// And it puts Signalsmith alongside Rubber Band R3 "Finer" (~0.00 cents) rather than R2
/// "Faster" (up to -26 cents at these ratios, -108 cents at the extremes). That is a
/// commercial fact as much as a technical one: the free, MIT-licensed, App-Store-shippable
/// backend is not the compromise it was assumed to be. See `docs/LICENSING.md`.
///
/// The ±2 cent bound is Rubber Band `.studio`'s, deliberately — the same question deserves
/// the same bar — and sits 40× above the worst measurement, so it fails on a real
/// regression rather than on FFT noise.
@Test(arguments: [2.0, 0.5], [220.0, 300.0, 330.0, 440.0, 660.0, 880.0])
func signalsmithPreservesPitch(ratio: Double, freq: Double) {
    let stretcher = SignalsmithStretcher()
    stretcher.configure(sampleRate: 44100, channels: 1, maxBlock: 512)
    stretcher.timeRatio = ratio

    let input = sine(freq: freq, seconds: 6, sampleRate: 44100)
    let out = runStretcher(stretcher, input: input, sampleRate: 44100, block: 512)

    let skip = stretcher.startDelay + 8192
    #expect(out.count > skip + 65536, "not enough output to measure")
    let measured = estimateFrequencyFFT(
        Array(out[skip..<Swift.min(out.count, skip + 65536)]), sampleRate: 44100)
    let cents = 1200 * log2(measured / freq)
    #expect(abs(cents) < 2.0, "ratio \(ratio), \(freq) Hz: off by \(cents) cents")
}

/// A stretcher owes exactly `input * timeRatio` frames of audible output. Not "about".
///
/// This is the test that caught the one real defect in this backend's first draft, and it
/// caught it at 0.1× speed while every check at 1× stayed green — which is why the ratios
/// swept here reach the ends of `SpeedState`'s range instead of stopping at the comfortable
/// middle.
///
/// The defect: Signalsmith reports its latency in two halves in **two different units** —
/// `inputLatency` in input frames, `outputLatency` in output frames — and the flush that
/// drains the tail at end-of-file was asking for `outputLatency` frames alone. That is the
/// whole tail only when the two halves happen to be interchangeable, i.e. at ratio 1.0. At
/// 0.1× speed it dropped 24844 frames, 0.94% of the track: the last half-second of every
/// file, gone, with no error anywhere. Sizing the ring for `outputLatency` rather than for
/// the real tail then clamped what was left, silently.
///
/// Measured after the fix: the error is **exactly 0** frames at all four ratios. The bound
/// is ±1 to allow for the fractional-frame accumulator rounding a block differently if the
/// block size ever changes; it is not slack for a truncation to hide in.
@Test(arguments: [1.0, 2.0, 0.5, 10.0])
func signalsmithProducesExactlyTheRequestedLength(ratio: Double) {
    let stretcher = SignalsmithStretcher()
    stretcher.configure(sampleRate: 44100, channels: 1, maxBlock: 512)
    stretcher.timeRatio = ratio

    let input = sine(freq: 440, seconds: 6, sampleRate: 44100)
    let out = runStretcher(stretcher, input: input, sampleRate: 44100, block: 512)

    // What the engine will actually hear: `PlaybackEngine` discards `startDelay` frames of
    // priming before it emits anything.
    let audible = out.count - stretcher.startDelay
    let expected = Int((Double(input.count) * ratio).rounded())
    let shortfall = audible - expected
    #expect(
        abs(shortfall) <= 1,
        "ratio \(ratio): \(audible) audible frames against \(expected) owed (\(shortfall) short)")
}

/// `startDelay` has to be right in *output* frames, and the arithmetic that gets it there
/// is the subtle one: `inputLatency` counts input frames, `outputLatency` counts output
/// frames, and one input frame is `timeRatio` output frames.
///
/// Summing the two without converting gives 6615 at every ratio. That is the correct answer
/// at ratio 1.0 and wrong everywhere else — so a check at ratio 1.0 alone would pass over
/// the bug completely, which is exactly why this sweeps three ratios.
///
/// The method is a burst planted at input frame 22050. After discarding `startDelay`, it
/// must land at `22050 * timeRatio`. Measured error: 0 frames at ratio 1.0, -40 at 0.5, -173
/// at 2.0 — the phase vocoder smears a hard transient across its analysis window, and that
/// smearing is what the 600-frame bound accommodates. The unconverted-sum bug would land it
/// 1323 frames out at ratio 0.5 and 2473 out at ratio 2.0, both far outside. The search
/// window is ±5000 frames, wide enough to contain the wrong answer as well as the right
/// one, so the measurement cannot flatter itself by only looking where it hopes to find.
@Test(arguments: [1.0, 2.0, 0.5])
func signalsmithStartDelayPlacesTheAudioWhereTheRatioSaysItShouldBe(ratio: Double) {
    let stretcher = SignalsmithStretcher()
    stretcher.configure(sampleRate: 44100, channels: 1, maxBlock: 512)
    stretcher.timeRatio = ratio

    var signal = [Float](repeating: 0, count: 44100)
    for i in 22050..<22250 { signal[i] = 1.0 }
    let out = runStretcher(stretcher, input: signal, sampleRate: 44100, block: 512)
    let audible = Array(out.dropFirst(stretcher.startDelay))

    let expected = Int(22050 * ratio)
    let low = Swift.max(0, expected - 5000)
    let high = Swift.min(audible.count, expected + 5000)
    #expect(high > low, "ratio \(ratio): no output around the expected burst position")

    var peak: Float = 0
    var peakIndex = low
    for i in low..<high where abs(audible[i]) > peak {
        peak = abs(audible[i])
        peakIndex = i
    }
    #expect(peak > 0.3, "ratio \(ratio): no burst found near \(expected) (peak \(peak))")
    #expect(
        abs(peakIndex - expected) < 600,
        "ratio \(ratio): burst landed at \(peakIndex), expected \(expected)")
}

@Test func signalsmithOutputContainsNoNaNOrInfinity() {
    let stretcher = SignalsmithStretcher()
    stretcher.configure(sampleRate: 44100, channels: 1, maxBlock: 512)
    stretcher.timeRatio = 2.0
    stretcher.pitchScale = 1.5
    let out = runStretcher(
        stretcher, input: sine(freq: 440, seconds: 2, sampleRate: 44100),
        sampleRate: 44100, block: 512)
    #expect(!out.isEmpty)
    #expect(!out.contains { !$0.isFinite })
}

@Test func signalsmithReportsANonZeroStartDelay() {
    let stretcher = SignalsmithStretcher()
    stretcher.configure(sampleRate: 44100, channels: 1, maxBlock: 512)
    // 6615 frames at 44.1 kHz and ratio 1.0 — 150 ms, and far too much to leave
    // uncompensated. If this ever reads 0 the engine will happily play the priming.
    #expect(stretcher.startDelay > 0)
}

/// Ties the ring's sizing constant to the speed range it is supposed to cover.
///
/// `SignalsmithStretcher.ratioCeiling` cannot import `SpeedState` — `TimeStretch` must not
/// need to know what a transport thinks, and a stretcher that reached upward for a UI
/// constant would be the wrong dependency direction. So the two are related by this test
/// instead of by an import: widen `SpeedState`'s range without widening the ring and this
/// fails here rather than as a `precondition` on the render thread at 0.05× speed.
@Test func signalsmithRingIsSizedForTheWholeSpeedRange() {
    let slowestTimeRatio = 1.0 / SpeedState.minRatio
    let sizedFor = SignalsmithStretcher.ratioCeiling
    #expect(
        sizedFor >= slowestTimeRatio,
        "SpeedState allows a time ratio of \(slowestTimeRatio); the ring is sized for \(sizedFor)")
}
