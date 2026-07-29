import AVFAudio
import ArtscribeKit
import CoreAudio
import Foundation
import Synchronization

/// The only place CoreAudio touches the engine.
///
/// The render block does nothing but validate the buffer layout and forward to
/// `PlaybackEngine.render`. Everything else here — starting, stopping, switching
/// device, reacting to a route change — happens on the main actor, never on the
/// render thread.
@MainActor
public final class AudioOutput: AudioOutputDeviceSink {

    /// Everything the render block needs that is not the engine: the counters it
    /// publishes for the main actor to poll, and the silence gate it reads.
    ///
    /// A separate object because the render block must capture it without
    /// touching `self` (which is main-actor isolated) and without ARC traffic —
    /// and one object rather than two so the capture list stays short.
    ///
    /// `audibility` is `unowned(unsafe)` for the same reason the block's own
    /// captures are: reading a strong reference from the render thread is
    /// retain/release traffic, which spec §5 forbids. It points at a process-wide
    /// singleton, so there is nothing for it to dangle against.
    fileprivate final class RenderContext: Sendable {
        let layoutMismatches = Atomic<UInt64>(0)
        unowned(unsafe) let audibility: OutputAudibility

        init(audibility: OutputAudibility) {
            self.audibility = audibility
        }
    }

    /// Internal rather than private so the tests can drive this exact graph in
    /// manual rendering mode — same source node, same mixer, same conversion,
    /// only the DAC missing.
    let avEngine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    private let engine: PlaybackEngine
    private let format: AVAudioFormat
    private let context = RenderContext(audibility: OutputAudibility.shared)
    /// Preallocated so the render block never allocates.
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private var configurationObserver: (any NSObjectProtocol)?

    public private(set) var isRunning = false
    /// Set when a route change forced a reconfiguration. Never overwritten with
    /// `nil` by the engine itself — the UI clears it once it has been shown.
    public private(set) var notice: String?

    /// The file's sample rate, which is the rate the render block produces.
    public let sourceSampleRate: Double

    /// The number of channels this output renders — `engine.channelCount`, never anything
    /// else. See `init` for why it is not a parameter.
    public var channelCount: Int { engine.channelCount }

    /// The channel count is **taken from the engine, not supplied**. It used to be a
    /// parameter, and a caller that passed a smaller one than the engine's got a graph
    /// that passed every guard here — a mono format yields one buffer, so the layout
    /// check `buffers.count == channels` held — and then had `PlaybackEngine.render` read
    /// past the end of `channelPointers` and write through whatever it found. `render`'s
    /// contract is explicitly unchecked (it runs on the render thread), so the only place
    /// that mismatch could be prevented is here, and the only way to prevent it rather
    /// than detect it is to leave the caller nothing to get wrong.
    ///
    /// `sampleRate` stays a parameter: a wrong one is audible — the track plays at the
    /// wrong speed — but it cannot make anything read or write out of bounds.
    public init(engine: PlaybackEngine, sampleRate: Double) throws {
        self.engine = engine
        self.sourceSampleRate = sampleRate
        let channels = engine.channelCount

        guard
            channels > 0, sampleRate > 0,
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        else {
            throw AudioOutputError.unsupportedFormat(sampleRate: sampleRate, channels: channels)
        }
        self.format = format

        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
            .allocate(capacity: channels)
        pointers.initialize(repeating: nil, count: channels)
        self.channelPointers = pointers

        sourceNode = AVAudioSourceNode(
            format: format,
            renderBlock: Self.makeRenderBlock(
                engine: engine, context: context, channels: channels, into: pointers))

        avEngine.attach(sourceNode)
        avEngine.connect(sourceNode, to: avEngine.mainMixerNode, format: format)
        observeConfigurationChanges()
    }

    isolated deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        avEngine.stop()
        channelPointers.deinitialize(count: Int(format.channelCount))
        channelPointers.deallocate()
    }

    /// Built as a static function so the block captures exactly four values and
    /// never `self` — `self` is main-actor isolated, and touching it from the
    /// render thread would be both a concurrency violation and ARC traffic.
    ///
    /// `unowned(unsafe)` on both objects: they are owned by the `AudioOutput`
    /// that owns this block and cannot outlive it, because `deinit` stops the
    /// engine (tearing the block down) before releasing either.
    private static func makeRenderBlock(
        engine: PlaybackEngine, context: RenderContext, channels: Int,
        into pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    ) -> AVAudioSourceNodeRenderBlock {
        { [unowned(unsafe) engine, unowned(unsafe) context] _, _, frameCount, rawList in
            let buffers = UnsafeMutableAudioBufferListPointer(rawList)
            let frames = Int(frameCount)

            // `standardFormatWithSampleRate` is *deinterleaved* float, so this
            // should always be one single-channel buffer per channel. Verified
            // by `eachChannelLandsInItsOwnBuffer`, but not assumed here: if the
            // layout were ever anything else, the per-channel mapping below
            // would write channel 1 into channel 0's buffer and past its end.
            // Exactly one buffer per channel, no more: a longer list would leave
            // buffers we never wrote, and undefined memory is worse than silence.
            var planar = buffers.count == channels
            if planar {
                for i in 0..<channels where !Self.isPlanarFloat(buffers[i], frames: frames) {
                    planar = false
                }
            }
            guard planar else {
                for i in 0..<buffers.count {
                    if let data = buffers[i].mData {
                        memset(data, 0, Int(buffers[i].mDataByteSize))
                    }
                }
                context.layoutMismatches.wrappingAdd(1, ordering: .relaxed)
                return noErr
            }

            for i in 0..<channels {
                pointers[i] = buffers[i].mData?.assumingMemoryBound(to: Float.self)
            }
            _ = engine.render(into: pointers, frames: frames)

            // The silence gate (see `OutputAudibility`). Deliberately *after* the
            // render: the engine still advances, so the position it publishes is
            // still real time and every position-based check still measures the
            // real render thread — only the samples are discarded. This node is
            // the graph's one signal source, so zeros here are silence at the DAC.
            if context.audibility.isSilenced {
                for i in 0..<channels {
                    if let channel = pointers[i] {
                        memset(channel, 0, frames * MemoryLayout<Float>.size)
                    }
                }
            }
            return noErr
        }
    }

    @inline(__always)
    private static func isPlanarFloat(_ buffer: AudioBuffer, frames: Int) -> Bool {
        buffer.mNumberChannels == 1
            && Int(buffer.mDataByteSize) >= frames * MemoryLayout<Float>.size
    }

    // MARK: - Transport

    public func start() throws {
        guard !isRunning else { return }
        // `prepare()` belongs here rather than in `init`: it *initialises* the
        // engine, and an initialised engine refuses `enableManualRenderingMode`
        // (-80801), which is how the tests drive this exact graph offline.
        avEngine.prepare()
        try avEngine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        avEngine.stop()
        isRunning = false
    }

    // MARK: - Level

    /// Sets the output gain, from the **main actor**.
    ///
    /// Deliberately the mixer's own control rather than a multiply inside
    /// `PlaybackEngine.render`: applying gain on the render path would need its
    /// own per-sample smoothing to avoid zipper noise on every keystroke, and
    /// `AVAudioMixerNode` already ramps `outputVolume` internally. It also keeps
    /// the render block exactly as small as spec §5 requires.
    ///
    /// Non-finite and out-of-range values are clamped rather than passed on: a
    /// NaN here would silence the graph with no way to tell why.
    public func setVolume(_ amplitude: Double) {
        guard amplitude.isFinite else { return }
        avEngine.mainMixerNode.outputVolume = Float(Swift.max(0, Swift.min(1, amplitude)))
    }

    /// Read back for verification; the UI owns the value, this is what the graph
    /// actually has.
    public var volume: Double { Double(avEngine.mainMixerNode.outputVolume) }

    // MARK: - Device

    /// The sample rate the output hardware is actually running at, or 0 when it
    /// cannot be read (manual rendering, no device).
    public var deviceSampleRate: Double {
        avEngine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    /// True when the graph is resampling between the file and the device. Not a
    /// failure — but the user is entitled to know it is happening, so the CLI
    /// prints it and the menu shows it (spec §8).
    public func needsSampleRateConversion(deviceRate: Double? = nil) -> Bool {
        let rate = deviceRate ?? deviceSampleRate
        guard rate > 0 else { return false }
        return abs(rate - sourceSampleRate) > 0.5
    }

    /// Roughly how far ahead of the speaker the render block is, in seconds.
    /// `PlaybackEngine.currentFrame` is the position at the end of the block it
    /// just rendered; this is the remaining offset the engine cannot know about.
    public var outputLatency: TimeInterval {
        avEngine.outputNode.presentationLatency
    }

    /// Routes output to `id`, preserving playback state.
    ///
    /// The `AVAudioEngine` has to be stopped across the change, but nothing here
    /// touches `PlaybackEngine` or the command ring: position, speed and loop
    /// live entirely in the engine and are untouched by a stop/start of the
    /// graph. Verified by `switchingDeviceLeavesThePlaybackEngineAlone`.
    public func setOutputDevice(_ id: AudioDeviceIdentifier) throws {
        guard let unit = avEngine.outputNode.audioUnit else {
            throw AudioOutputError.noOutputUnit
        }
        let wasRunning = isRunning
        if avEngine.isRunning { avEngine.stop() }
        // From here until the restart succeeds the graph is genuinely stopped;
        // `isRunning` must say so, or a failed restart would leave this object
        // claiming to be playing when it is silent.
        isRunning = false

        var device = AudioDeviceID(id)
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            // Put the graph back the way it was before reporting the failure,
            // so a refused switch costs the user nothing but a message.
            reconnect()
            if wasRunning, (try? avEngine.start()) != nil { isRunning = true }
            throw AudioOutputError.deviceSwitchFailed(status: status)
        }

        // The new device may run at a different rate, so the mixer → output
        // connection has to be renegotiated.
        reconnect()
        if wasRunning {
            try avEngine.start()
            isRunning = true
        }
    }

    /// Render blocks whose `AudioBufferList` did not have the expected
    /// deinterleaved layout. Always 0 in practice; non-zero means the assumption
    /// behind the per-channel mapping is wrong on this system, and the block in
    /// question was filled with silence rather than corrupted.
    public var renderLayoutMismatchCount: UInt64 {
        context.layoutMismatches.load(ordering: .relaxed)
    }

    public func clearNotice() { notice = nil }

    // MARK: - Route changes

    private func reconnect() {
        avEngine.disconnectNodeOutput(sourceNode)
        avEngine.connect(sourceNode, to: avEngine.mainMixerNode, format: format)
    }

    /// A route change (headphones plugged in, device rate changed) stops the
    /// engine and invalidates its connections. Spec §8 requires reconfiguring
    /// and preserving position and speed — which happens for free, because the
    /// position and speed live in `PlaybackEngine`, not here.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: avEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    private func handleConfigurationChange() {
        let wasRunning = isRunning
        reconnect()
        guard wasRunning else { return }
        do {
            isRunning = false
            try start()
        } catch {
            // Never silent: playback has genuinely stopped, so say so.
            notice =
                "Audio output was reconfigured and could not be restarted: "
                + error.localizedDescription
        }
    }
}

public enum AudioOutputError: Error, LocalizedError, Equatable {
    case unsupportedFormat(sampleRate: Double, channels: Int)
    case noOutputUnit
    case deviceSwitchFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let rate, let channels):
            return "Cannot create an output format for \(channels) channels at \(rate) Hz."
        case .noOutputUnit:
            return "The audio output unit is unavailable."
        case .deviceSwitchFailed(let status):
            return "The audio device refused the switch (CoreAudio status \(status))."
        }
    }
}
