import AVFAudio
import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import TimeStretch

@testable import Playback

// Rubber Band is a macOS dylib from Homebrew and does not exist for iOS, so this suite is
// conditional. It is guarded rather than deleted or ported: these are measurements *of Rubber
// Band*, and a version of them running against a different backend would be a different test
// wearing the same name.
#if canImport(CRubberBand)

/// Integration checks against real material, through the whole shipped output
/// path: decode → `PlaybackEngine` → Rubber Band R3 → `AVAudioSourceNode` →
/// mixer → 48 kHz conversion. Only the DAC is missing.
///
/// The reference album is copyrighted and ~1.1 GB, so it is never committed;
/// these skip unless `$ARTSCRIBE_TEST_MEDIA_DIR` points at it.
private let referenceTrack: URL? = {
    guard let directory = ProcessInfo.processInfo.environment["ARTSCRIBE_TEST_MEDIA_DIR"] else {
        return nil
    }
    let url = URL(fileURLWithPath: directory)
        .appendingPathComponent("03. Wynton Marsalis - Delfeayo's Dilemma.flac")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}()

private let canPlayReferenceTrack =
    referenceTrack != nil
    && CoreAudioHAL.defaultOutputDevice() != nil

/// One chunk of rendered output, with the engine's reported position at the end
/// of it, so a loop wrap can be located in the rendered signal.
private struct Chunk {
    let samples: [Float]
    let positionFrame: FrameIndex
}

@MainActor
private func renderThroughGraph(
    _ output: AudioOutput, at rate: Double, engine: PlaybackEngine, chunkFrames: Int, chunks: Int
) throws -> [Chunk] {
    guard
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames))
    else { return [] }

    try output.avEngine.enableManualRenderingMode(
        .offline, format: format, maximumFrameCount: AVAudioFrameCount(chunkFrames))
    try output.avEngine.start()
    defer {
        output.avEngine.stop()
        output.avEngine.disableManualRenderingMode()
    }

    var result: [Chunk] = []
    for _ in 0..<chunks {
        let status = try output.avEngine.renderOffline(
            AVAudioFrameCount(chunkFrames), to: buffer)
        guard status == .success, let data = buffer.floatChannelData, buffer.frameLength > 0
        else { break }
        result.append(
            Chunk(
                samples: Array(
                    UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))),
                positionFrame: engine.currentFrame))
    }
    return result
}

/// The largest sample-to-sample step in `samples`. A click at a loop seam is
/// exactly a step much larger than the signal's own steps.
private func maximumStep(_ samples: ArraySlice<Float>) -> Float {
    var worst: Float = 0
    var previous: Float?
    for value in samples {
        if let previous { worst = max(worst, abs(value - previous)) }
        previous = value
    }
    return worst
}

@MainActor
@Test(.enabled(if: canPlayReferenceTrack))
func theLoopSeamOnRealMaterialIsNotADiscontinuity() async throws {
    // The single most important qualitative check in the project, made
    // quantitative: a four-second loop at half speed, repeated, through the
    // real output graph. Resetting the stretcher at the wrap produces a step
    // discontinuity an order of magnitude beyond anything the music contains
    // (Task 8 measured 28×); this asserts the shipped path does not.
    let url = try #require(referenceTrack)
    let audio = try await AudioFileDecoder.decode(url: url)
    let ring = CommandRing(capacity: 64)
    let engine = PlaybackEngine(
        audio: audio, stretcher: RubberBandStretcher(core: .finer), ring: ring, maxBlock: 1024)
    let output = try AudioOutput(
        engine: engine, sampleRate: audio.sampleRate)

    let start = FrameIndex(30 * audio.sampleRate)
    let end = FrameIndex(34 * audio.sampleRate)
    ring.push(.setTimeRatio(2.0))  // half speed
    ring.push(.setLoop(FrameRange(start: start, count: end - start), true))
    ring.push(.seek(start))
    ring.push(.setPlaying(true))

    // Four seconds of source at half speed is eight seconds of output per pass;
    // 24 s covers two full seams with room either side.
    let chunkFrames = 512
    let chunks = try renderThroughGraph(
        output, at: 48000, engine: engine, chunkFrames: chunkFrames,
        chunks: 24 * 48000 / chunkFrames)
    #expect(chunks.count > 2000)

    // Locate the wraps: the reported position moves backwards exactly there.
    var seamChunks: [Int] = []
    for i in 1..<chunks.count where chunks[i].positionFrame < chunks[i - 1].positionFrame {
        seamChunks.append(i)
    }
    #expect(seamChunks.count >= 2, "expected at least two loop wraps, saw \(seamChunks.count)")

    let flat = chunks.flatMap(\.samples)
    #expect(flat.allSatisfy { $0.isFinite }, "the graph produced a non-finite sample")

    // Compare against the *same music* rendered straight through with no loop
    // at all. Both signals contain the same transients, so any step the looped
    // render has and the control does not came from a seam. Locating the seam
    // in the signal is deliberately avoided: an earlier version of this test
    // did that from the reported position, and a mutation that clicked at the
    // wrap slipped outside the window and was counted as baseline.
    let (controlEngine, controlOutput) = try makeReferencePlayer(audio: audio)
    let control = try renderThroughGraph(
        controlOutput, at: 48000, engine: controlEngine, chunkFrames: chunkFrames,
        chunks: 8 * 48000 / chunkFrames)
    let controlFlat = control.flatMap(\.samples)

    // Skip the first blocks of each: the mixer ramps its gain in, and Rubber
    // Band's start-delay priming is discarded there.
    let settled = 8 * chunkFrames
    let loopedWorst = maximumStep(flat[settled...])
    let controlWorst = maximumStep(controlFlat[settled...])

    let verdict =
        "worst step with the loop \(loopedWorst) vs the same music unlooped \(controlWorst)"
    // Measured: the two are *equal* on this material — the loop adds nothing.
    // Resetting the stretcher at the wrap (spec §5.1's forbidden move) raises the
    // looped figure by ~9%, so 5% separates "no seam" from "a click at the seam".
    #expect(loopedWorst <= controlWorst * 1.05, "\(verdict) — that is a click at the seam")
    #expect(engine.renderStallCount == 0)
    #expect(output.renderLayoutMismatchCount == 0)
}

/// A fresh engine and output over the same decoded audio, seeked to the loop
/// region but *not* looping.
@MainActor
private func makeReferencePlayer(audio: DecodedAudio) throws -> (PlaybackEngine, AudioOutput) {
    let ring = CommandRing(capacity: 64)
    let engine = PlaybackEngine(
        audio: audio, stretcher: RubberBandStretcher(core: .finer), ring: ring, maxBlock: 1024)
    let output = try AudioOutput(
        engine: engine, sampleRate: audio.sampleRate)
    ring.push(.setTimeRatio(2.0))
    ring.push(.seek(FrameIndex(30 * audio.sampleRate)))
    ring.push(.setPlaying(true))
    return (engine, output)
}

#endif  // canImport(CRubberBand)
