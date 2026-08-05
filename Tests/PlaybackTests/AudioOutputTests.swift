import AVFAudio
import Accelerate
import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import TimeStretch

@testable import Playback

// MARK: - Fixtures

/// Builds a `DecodedAudio` from a per-channel sample function.
private func makeAudio(
    channels: Int, sampleRate: Double, frames: Int, sample: (Int, Int) -> Float
) -> DecodedAudio {
    let storage = AudioStorage(channels: channels, capacityFrames: frames)
    for c in 0..<channels {
        let p = storage.pointer(c)
        for i in 0..<frames { p[i] = sample(c, i) }
    }
    return DecodedAudio(
        channels: channels, sampleRate: sampleRate, frameCount: FrameIndex(frames),
        storage: storage)
}

/// A playing engine over `audio`, with the identity stretcher so that whatever
/// comes out of `AudioOutput` is exactly what CoreAudio did to it and nothing else.
@MainActor
private func playingEngine(_ audio: DecodedAudio) -> (PlaybackEngine, CommandRing) {
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: audio, stretcher: IdentityStretcher(), ring: ring, maxBlock: 1024)
    ring.push(.setPlaying(true))
    return (engine, ring)
}

/// See `OutputDeviceAvailability` — why the graph needs a device to exist, and
/// why the question is platform-dependent.
private let hasOutputDevice = OutputDeviceAvailability.hasOutputDevice

private enum TestSetupError: Error { case unsupportedFormat }

/// Pulls `frames` frames through the real graph in manual rendering mode: the
/// same `AVAudioSourceNode`, the same mixer, the same format conversion the
/// hardware path uses — only the DAC is missing. Returns deinterleaved channels.
@MainActor
private func renderOffline(
    _ output: AudioOutput, at rate: Double, channels: Int, frames: Int
) throws -> [[Float]] {
    guard
        let format = AVAudioFormat(
            standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
    else { throw TestSetupError.unsupportedFormat }

    try output.avEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try output.avEngine.start()
    defer {
        output.avEngine.stop()
        output.avEngine.disableManualRenderingMode()
    }

    var collected = [[Float]](repeating: [], count: channels)
    var remaining = frames
    while remaining > 0 {
        let want = AVAudioFrameCount(min(remaining, 4096))
        let status = try output.avEngine.renderOffline(want, to: buffer)
        guard status == .success, buffer.frameLength > 0 else { break }
        guard let data = buffer.floatChannelData else { break }
        for c in 0..<channels {
            collected[c].append(
                contentsOf: UnsafeBufferPointer(start: data[c], count: Int(buffer.frameLength)))
        }
        remaining -= Int(buffer.frameLength)
    }
    return collected
}

/// Hann-windowed magnitude spectrum over the largest power-of-two window that
/// fits, via vDSP. Spec §9 specifies FFT peak as *the* way to measure pitch here;
/// the same spectrum also answers "what else did the converter put in the signal",
/// which a time-domain SNR estimate cannot (it measures its own estimator).
private func magnitudeSpectrum(_ samples: [Float]) -> [Float] {
    var n = 1
    var log2n: vDSP_Length = 0
    while n * 2 <= samples.count {
        n *= 2
        log2n += 1
    }
    guard n >= 1024, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return []
    }
    defer { vDSP_destroy_fftsetup(setup) }

    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var windowed = [Float](repeating: 0, count: n)
    samples.withUnsafeBufferPointer { sp in
        guard let base = sp.baseAddress else { return }
        vDSP_vmul(base, 1, window, 1, &windowed, 1, vDSP_Length(n))
    }

    var realp = [Float](repeating: 0, count: n / 2)
    var imagp = [Float](repeating: 0, count: n / 2)
    var magnitudes = [Float](repeating: 0, count: n / 2)
    realp.withUnsafeMutableBufferPointer { realPtr in
        imagp.withUnsafeMutableBufferPointer { imagPtr in
            guard let rBase = realPtr.baseAddress, let iBase = imagPtr.baseAddress else { return }
            var split = DSPSplitComplex(realp: rBase, imagp: iBase)
            windowed.withUnsafeBufferPointer { wp in
                guard let wBase = wp.baseAddress else { return }
                wBase.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
        }
    }
    return magnitudes
}

/// FFT peak refined by quadratic interpolation of the log magnitudes, so the
/// estimate is not limited to the bin spacing.
private func peakFrequency(_ spectrum: [Float], sampleRate: Double) -> Double {
    guard spectrum.count > 2 else { return 0 }
    var bin = 1
    for i in 1..<(spectrum.count - 1) where spectrum[i] > spectrum[bin] { bin = i }
    let m1 = log(Double(spectrum[bin - 1]) + 1e-12)
    let m0 = log(Double(spectrum[bin]) + 1e-12)
    let m2 = log(Double(spectrum[bin + 1]) + 1e-12)
    let denom = m1 - 2 * m0 + m2
    let delta = denom != 0 ? 0.5 * (m1 - m2) / denom : 0
    return (Double(bin) + delta) * sampleRate / Double(spectrum.count * 2)
}

/// Spurious-free dynamic range: the peak, over the largest thing that is not the
/// peak. An imaging or aliasing artefact from a bad sample-rate converter shows
/// up here and nowhere else.
private func spuriousFreeDynamicRangeDB(_ spectrum: [Float]) -> Double {
    guard spectrum.count > 2 else { return 0 }
    var bin = 1
    for i in 1..<(spectrum.count - 1) where spectrum[i] > spectrum[bin] { bin = i }
    // Hann's sidelobes only fall to about -70 dB by ten bins out, so a narrow
    // exclusion would measure the window rather than the signal. Sample-rate
    // conversion artefacts — images and aliases of a 440 Hz tone across a
    // 44.1/48 kHz boundary — land kilohertz away, so excluding a wide skirt
    // costs no sensitivity to the thing being measured.
    let skirt = 64
    var worst: Float = 0
    for i in 1..<(spectrum.count - 1) where abs(i - bin) > skirt {
        worst = max(worst, spectrum[i])
    }
    return 20 * log10(Double(spectrum[bin]) / Double(max(worst, 1e-12)))
}

// MARK: - Construction

@MainActor
@Test(.enabled(if: hasOutputDevice)) func audioOutputBuildsWithoutStartingHardware() throws {
    let audio = makeAudio(channels: 2, sampleRate: 44100, frames: 4410) { _, _ in 0 }
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: audio, stretcher: IdentityStretcher(), ring: ring, maxBlock: 512)
    let output = try AudioOutput(engine: engine, sampleRate: 44100, transport: .unmanaged)
    #expect(output.isRunning == false)
}

@MainActor
@Test(.enabled(if: hasOutputDevice)) func anImpossibleFormatIsRefusedRatherThanApproximated() {
    let audio = makeAudio(channels: 2, sampleRate: 44100, frames: 64) { _, _ in 0 }
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(
        audio: audio, stretcher: IdentityStretcher(), ring: ring, maxBlock: 64)
    #expect(throws: AudioOutputError.self) {
        _ = try AudioOutput(engine: engine, sampleRate: 0, transport: .unmanaged)
    }
}

// MARK: - Concern 2: the buffer list really is one buffer per channel

@MainActor
@Test(.enabled(if: hasOutputDevice)) func eachChannelLandsInItsOwnBuffer() throws {
    // Distinct DC per channel: a single interleaved buffer, or a swapped
    // mapping, shows up immediately as the wrong constant.
    let audio = makeAudio(channels: 2, sampleRate: 44100, frames: 44100) { c, _ in
        c == 0 ? 0.5 : -0.25
    }
    let (engine, ring) = playingEngine(audio)
    let output = try AudioOutput(engine: engine, sampleRate: 44100, transport: .unmanaged)
    let rendered = try renderOffline(output, at: 44100, channels: 2, frames: 8192)

    #expect(rendered[0].count == 8192)
    // Skip the first block: the mixer ramps its gain in on the first render.
    let left = Array(rendered[0][1024...])
    let right = Array(rendered[1][1024...])
    #expect(left.allSatisfy { abs($0 - 0.5) < 0.01 })
    #expect(right.allSatisfy { abs($0 + 0.25) < 0.01 })
    // The render block's layout guard must never have fired: if it did, the
    // assumption behind the per-channel mapping is wrong on this platform.
    #expect(output.renderLayoutMismatchCount == 0)
    #expect(engine.renderStallCount == 0)
    _ = ring
}

// MARK: - Concern 1: the device may not run at the file's sample rate

@MainActor
@Test(.enabled(if: hasOutputDevice))
func aDeviceRunningAtADifferentRateDoesNotShiftThePitch() throws {
    // 44.1 kHz file, 48 kHz device — the common case, and the case on the
    // machine this was written on.
    let audio = makeAudio(channels: 2, sampleRate: 44100, frames: 44100 * 2) { _, i in
        Float(sin(2 * Double.pi * 440 * Double(i) / 44100))
    }
    let (engine, ring) = playingEngine(audio)
    let output = try AudioOutput(engine: engine, sampleRate: 44100, transport: .unmanaged)
    #expect(output.needsSampleRateConversion(deviceRate: 48000))

    let rendered = try renderOffline(output, at: 48000, channels: 2, frames: 48000)
    let converted = magnitudeSpectrum(Array(rendered[0][2048...]))
    let peak = peakFrequency(converted, sampleRate: 48000)
    // A naive "play the 44.1 kHz samples at 48 kHz" lands at 478.9 Hz — a
    // semitone and a half sharp, which is exactly the failure this guards.
    #expect(abs(peak - 440) < 1.0, "FFT peak was \(peak) Hz, expected 440 Hz")

    // Quality of the conversion, measured against the same graph with no
    // conversion in it at all, so the figure is the converter's and not the
    // measurement's.
    let convertedSFDR = spuriousFreeDynamicRangeDB(converted)
    let (controlEngine, controlRing) = playingEngine(audio)
    let control = try AudioOutput(engine: controlEngine, sampleRate: 44100, transport: .unmanaged)
    let straight = try renderOffline(control, at: 44100, channels: 2, frames: 44100)
    let controlSFDR = spuriousFreeDynamicRangeDB(magnitudeSpectrum(Array(straight[0][2048...])))

    #expect(
        convertedSFDR > 90,
        "sample-rate conversion SFDR \(convertedSFDR) dB vs \(controlSFDR) dB unconverted")
    _ = (ring, controlRing)
}

@MainActor
@Test(.enabled(if: hasOutputDevice))
func theLatencyTheGraphAddsIsMeasuredNotAssumed() throws {
    // `PlaybackEngine.currentFrame` is the position at the end of the block it
    // just rendered. Anything the graph adds after that — notably a sample-rate
    // converter — is playhead error the output layer owns. Measure it.
    let impulseFrame = 4410
    let audio = makeAudio(channels: 2, sampleRate: 44100, frames: 44100) { _, i in
        i == impulseFrame ? 1.0 : 0.0
    }
    let (engine, ring) = playingEngine(audio)
    let output = try AudioOutput(engine: engine, sampleRate: 44100, transport: .unmanaged)
    let rendered = try renderOffline(output, at: 48000, channels: 2, frames: 24000)

    let expected = Double(impulseFrame) * 48000 / 44100
    var arrival = -1
    for (i, value) in rendered[0].enumerated() where abs(value) > 0.05 {
        arrival = i
        break
    }
    #expect(arrival >= 0, "the impulse never came out of the graph")
    let addedFrames = Double(arrival) - expected
    let addedMilliseconds = addedFrames / 48000 * 1000
    // A converter with a long filter would show up as tens of milliseconds; a
    // short one is a fraction of one. Either is fine, but it must be known.
    #expect(
        abs(addedMilliseconds) < 10,
        "the graph added \(addedMilliseconds) ms (\(addedFrames) frames at 48 kHz)")
    _ = ring
}

// MARK: - Concern 4: a device switch must not disturb playback state

@MainActor
@Test(.enabled(if: hasOutputDevice)) func switchingDeviceLeavesThePlaybackEngineAlone() throws {
    let audio = makeAudio(channels: 2, sampleRate: 44100, frames: 44100) { _, i in
        Float(i % 100) / 100
    }
    let (engine, ring) = playingEngine(audio)
    ring.push(.setLoop(FrameRange(start: 1000, count: 500), true))
    ring.push(.seek(1000))
    ring.push(.setTimeRatio(2.0))
    let output = try AudioOutput(engine: engine, sampleRate: 44100, transport: .unmanaged)
    _ = try renderOffline(output, at: 44100, channels: 2, frames: 4096)

    let frameBefore = engine.currentFrame
    let playingBefore = engine.isPlaying
    // Via `PlatformAudio` so this runs on iOS too, where it asserts the other
    // half of the contract: `setOutputDevice` is a no-op that must *succeed*.
    guard let device = PlatformAudio.makeDeviceSource().defaultOutputDevice() else { return }
    try output.setOutputDevice(device)

    #expect(engine.currentFrame == frameBefore)
    #expect(engine.isPlaying == playingBefore)
    #expect(playingBefore)
    // Still inside the loop region, still at the ratio that was set.
    #expect(frameBefore >= 1000 && frameBefore < 1500)
}

// MARK: - Silence

/// The guarantee an automated run depends on: with `OutputAudibility` closed,
/// what leaves the graph is exactly zero — not "quiet", not "attenuated".
///
/// Measured through the same real graph the hardware uses, and against a control
/// with the gate open, so a test that could not fail (because the fixture was
/// silent anyway, or because the engine never played) is ruled out by the
/// control's own assertion.
///
/// The gate is process-wide and this test flips it. That is safe here and only
/// here: every test in this file is `@MainActor` and every one of them renders
/// synchronously, so no other test can observe the gate between the two lines
/// that close and reopen it. The `defer` reopens it even if an expectation
/// throws.
@MainActor
@Test(.enabled(if: hasOutputDevice)) func aSilencedGraphEmitsExactlyZero() throws {
    let audio = makeAudio(channels: 2, sampleRate: 44100, frames: 44100) { _, i in
        Float(sin(2 * Double.pi * 440 * Double(i) / 44100))
    }

    let (controlEngine, controlRing) = playingEngine(audio)
    let control = try AudioOutput(engine: controlEngine, sampleRate: 44100, transport: .unmanaged)
    let audible = try renderOffline(control, at: 44100, channels: 2, frames: 8192)
    #expect(audible[0].contains { abs($0) > 0.1 }, "the control never made a sound to silence")

    defer { OutputAudibility.shared.allowAudibleOutput() }
    OutputAudibility.shared.silence()
    #expect(OutputAudibility.shared.isSilenced)

    let (engine, ring) = playingEngine(audio)
    let output = try AudioOutput(engine: engine, sampleRate: 44100, transport: .unmanaged)
    let rendered = try renderOffline(output, at: 44100, channels: 2, frames: 8192)
    #expect(rendered[0].count == 8192)
    for channel in rendered {
        #expect(channel.allSatisfy { $0 == 0 }, "a silenced graph emitted a non-zero sample")
    }

    // And the engine still ran: the position advanced, which is what keeps the
    // acceptance harness's playhead checks meaningful while it is muted.
    #expect(engine.currentFrame > 0)
    // The mixer is untouched, so the volume control still reads back the value
    // the user asked for rather than the silencing.
    output.setVolume(0.4)
    #expect(abs(output.volume - 0.4) < 0.001)
    _ = (ring, controlRing)
}

@MainActor
@Test func theSilenceGateIsOffByDefaultAndCanBeClosedAndReopened() {
    // The product app must be audible unless something explicitly says otherwise.
    #expect(OutputAudibility.shared.isSilenced == false)
    defer { OutputAudibility.shared.allowAudibleOutput() }
    OutputAudibility.shared.silence()
    #expect(OutputAudibility.shared.isSilenced)
    OutputAudibility.shared.silence()
    #expect(OutputAudibility.shared.isSilenced, "closing the gate twice must not reopen it")
    OutputAudibility.shared.allowAudibleOutput()
    #expect(OutputAudibility.shared.isSilenced == false)
}

// MARK: - The channel count is the engine's, not the caller's

/// `render` reads every entry in `0..<engine.channelCount` of the pointer table and cannot
/// check that the table is that long. While the count was a parameter here, a mono
/// `AudioOutput` over a stereo engine was constructible and passed every guard — a mono
/// format yields one buffer, so `buffers.count == channels` held — after which `render`
/// read `pointers[1]` past its allocation and wrote through it. No longer a parameter.
@MainActor
@Test(.enabled(if: hasOutputDevice)) func theOutputRendersExactlyTheEnginesChannels() throws {
    for channels in [1, 2] {
        let audio = makeAudio(channels: channels, sampleRate: 44100, frames: 44100) { c, _ in
            c == 0 ? 0.5 : -0.25
        }
        let (engine, _) = playingEngine(audio)
        let output = try AudioOutput(engine: engine, sampleRate: 44100, transport: .unmanaged)
        #expect(output.channelCount == channels)
        #expect(output.channelCount == engine.channelCount)

        // Skip the first block: the mixer ramps its gain in on the first render.
        let rendered = try renderOffline(output, at: 44100, channels: channels, frames: 4096)
        #expect(rendered.count == channels)
        // Channel 0 carries +0.5 in both cases. A mono graph picks up the mixer's −3 dB
        // mono pan law on the way through, so it arrives as 0.5/√2; stereo passes intact.
        let expected: Float = channels == 1 ? 0.5 / (2 as Float).squareRoot() : 0.5
        #expect(rendered[0][1024...].allSatisfy { abs($0 - expected) < 0.01 })
    }
}

@MainActor
@Test(.enabled(if: hasOutputDevice)) func stoppingAnOutputThatNeverStartedIsANoOp() throws {
    let audio = makeAudio(channels: 2, sampleRate: 44100, frames: 4410) { _, _ in 0 }
    let (engine, _) = playingEngine(audio)
    let output = try AudioOutput(engine: engine, sampleRate: 44100, transport: .unmanaged)
    _ = renderChannels(engine, frames: 64, channels: 2)  // drains `.setPlaying(true)`
    output.stop()
    #expect(output.isRunning == false)
    #expect(engine.isPlaying)
}
