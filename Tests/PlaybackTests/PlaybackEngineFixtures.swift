import ArtscribeKit
import AudioDecode
import Testing
import TimeStretch

@testable import Playback

/// Channel `c` holds `Float(frame) + c * channelStride`, so any output sample reveals
/// both which source frame produced it *and* which channel it came from — a channel
/// swap cannot hide behind an identical ramp in every channel.
let channelStride: Float = 1_000_000

func makeRampAudio(frames: Int, channels: Int = 1) -> DecodedAudio {
    let storage = AudioStorage(channels: channels, capacityFrames: frames)
    for c in 0..<channels {
        for i in 0..<frames { storage.pointer(c)[i] = Float(i) + Float(c) * channelStride }
    }
    return DecodedAudio(
        channels: channels, sampleRate: 44100,
        frameCount: FrameIndex(frames), storage: storage)
}

/// Renders `frames` frames into freshly allocated per-channel buffers and returns them.
/// Buffers start filled with NaN, so "the engine never wrote here" is distinguishable
/// from "the engine wrote silence here".
func renderChannels(_ engine: PlaybackEngine, frames: Int, channels: Int = 1) -> [[Float]] {
    let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
    for c in 0..<channels {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        buffer.initialize(repeating: .nan, count: frames)
        (table + c).initialize(to: buffer)
    }
    let returned = engine.render(into: table, frames: frames)
    #expect(returned == frames)

    var result: [[Float]] = []
    for c in 0..<channels {
        guard let buffer = table[c] else { continue }
        result.append(Array(UnsafeBufferPointer(start: buffer, count: frames)))
        buffer.deinitialize(count: frames)
        buffer.deallocate()
    }
    table.deinitialize(count: channels)
    table.deallocate()
    return result
}

func render(_ engine: PlaybackEngine, frames: Int) -> [Float] {
    renderChannels(engine, frames: frames, channels: 1)[0]
}

func makeEngine(
    frames: Int = 10_000, channels: Int = 1, maxBlock: Int = 512
) -> (PlaybackEngine, CommandRing) {
    let ring = CommandRing(capacity: 64)
    let engine = PlaybackEngine(
        audio: makeRampAudio(frames: frames, channels: channels),
        stretcher: IdentityStretcher(),
        ring: ring,
        maxBlock: maxBlock)
    ring.push(.setPlaying(true))
    return (engine, ring)
}

/// A scriptable `TimeStretcher` for the behaviours `IdentityStretcher` cannot express:
/// start-delay priming, an end-of-stream tail, and outright misbehaviour.
///
/// Deliberately *not* allocation-free — it models stretcher semantics, not render-thread
/// discipline. `IdentityStretcher` remains the double for the sample-exact position tests.
final class FakeStretcher: TimeStretcher {
    /// Value written for priming frames; must never reach the output.
    static let primingMarker: Float = -999
    /// Value written for end-of-stream tail frames; must reach the output.
    static let tailMarker: Float = -1

    private let delay: Int
    private let tail: Int
    /// Reports one frame available that `retrieve` then refuses to hand over.
    private let refusesRetrieve: Bool
    /// Swallows everything fed to it and never produces output.
    private let swallowsInput: Bool

    private var fifo: [[Float]] = []
    private var channelCount = 0
    private var block = 0

    init(
        delay: Int = 0, tail: Int = 0,
        refusesRetrieve: Bool = false, swallowsInput: Bool = false
    ) {
        self.delay = delay
        self.tail = tail
        self.refusesRetrieve = refusesRetrieve
        self.swallowsInput = swallowsInput
    }

    var timeRatio: Double = 1.0
    var startDelay: Int { delay }

    func configure(sampleRate: Double, channels: Int, maxBlock: Int) {
        channelCount = channels
        block = maxBlock
        reset()
    }

    func samplesRequired() -> Int { block }

    func available() -> Int {
        if refusesRetrieve { return 1 }
        return fifo.first?.count ?? 0
    }

    func process(_ input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool) {
        if !swallowsInput {
            for c in 0..<channelCount {
                guard let src = input[c] else { continue }
                fifo[c].append(contentsOf: UnsafeBufferPointer(start: src, count: frames))
            }
        }
        if final && tail > 0 {
            for c in 0..<channelCount {
                fifo[c].append(contentsOf: [Float](repeating: Self.tailMarker, count: tail))
            }
        }
    }

    func retrieve(_ output: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int) -> Int {
        if refusesRetrieve { return 0 }
        let n = Swift.min(frames, fifo.first?.count ?? 0)
        guard n > 0 else { return 0 }
        for c in 0..<channelCount {
            if let dst = output[c] {
                for i in 0..<n { dst[i] = fifo[c][i] }
            }
            fifo[c].removeFirst(n)
        }
        return n
    }

    func reset() {
        fifo = Array(
            repeating: [Float](repeating: Self.primingMarker, count: delay), count: channelCount)
    }
}

func makeFakeEngine(
    _ stretcher: FakeStretcher, frames: Int = 10_000, maxBlock: Int = 512
) -> (PlaybackEngine, CommandRing) {
    let ring = CommandRing(capacity: 64)
    let engine = PlaybackEngine(
        audio: makeRampAudio(frames: frames), stretcher: stretcher,
        ring: ring, maxBlock: maxBlock)
    ring.push(.setPlaying(true))
    return (engine, ring)
}
