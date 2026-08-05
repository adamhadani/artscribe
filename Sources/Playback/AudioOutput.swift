import AVFAudio
import ArtscribeKit
import Foundation
import Synchronization

#if os(macOS)
import CoreAudio
#endif

/// The only place CoreAudio touches the engine.
///
/// The render block does nothing but validate the buffer layout and forward to
/// `PlaybackEngine.render`. Everything else here — starting, stopping, switching
/// device, reacting to a route change — happens on the main actor, never on the
/// render thread. The block itself lives in `AudioOutput+Render.swift`: it is the
/// one piece of this class that runs under spec §5's real-time rules, and keeping
/// it in its own file is what stops main-actor code drifting into it.
///
/// Portable, and the two platform differences are both narrow. Choosing an output
/// device is a macOS idea, so `setOutputDevice` has a HAL implementation there and
/// is a documented no-op elsewhere. Being interrupted is an iOS idea, so the
/// session that reports it is injected (`AudioSessionCoordinator`) and is
/// `UnmanagedAudioSession` — correctly inert — on the Mac.
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
    ///
    /// `internal` rather than `fileprivate` only because the render block that
    /// captures it lives in `AudioOutput+Render.swift`; nothing outside this class
    /// touches it.
    final class RenderContext: Sendable {
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
    private let session: any AudioSessionCoordinator

    public private(set) var isRunning = false
    /// Set when a route change forced a reconfiguration. Never overwritten with
    /// `nil` by the engine itself — the UI clears it once it has been shown.
    public private(set) var notice: String?

    /// How the graph reaches the transport above it, and asks it what it thinks.
    ///
    /// A required `init` parameter rather than the two optional properties this
    /// replaced — see `TransportLink` for the bug that cost.
    private let transport: TransportLink

    /// Whether the transport was playing when the current interruption began.
    /// Remembered here because the session cannot tell us: by the time the
    /// interruption *ends*, `isRunning` has long since been false.
    private var wasPlayingWhenInterrupted = false

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
    ///
    /// - Parameter session: the platform's audio session. Defaults to the right one for
    ///   the platform; the tests pass a double so that interruption handling can be
    ///   driven on a Mac, where no interruption can actually happen.
    public init(
        engine: PlaybackEngine, sampleRate: Double,
        session: any AudioSessionCoordinator = PlatformAudio.makeSession(),
        transport: TransportLink
    ) throws {
        self.engine = engine
        self.sourceSampleRate = sampleRate
        self.session = session
        self.transport = transport
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

        // After the graph exists, so an event arriving during configuration has
        // something to act on.
        session.onEvent = { [weak self] event in self?.handle(event) }
        try session.configure()
    }

    isolated deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        avEngine.stop()
        // After the engine, and unconditionally: a loaded track being replaced by
        // another one destroys this object without necessarily passing through
        // `stop()`, and an iOS session left active would keep another app's audio
        // ducked for a track that no longer exists.
        session.deactivate()
        channelPointers.deinitialize(count: Int(format.channelCount))
        channelPointers.deallocate()
    }

    // MARK: - Transport

    public func start() throws {
        guard !isRunning else { return }
        // Before `prepare()`: on iOS the session's activation is what decides the
        // hardware sample rate and buffer size the engine then negotiates
        // against, so preparing first would negotiate against the old route.
        try session.activate()
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
        // After the engine, so nothing is still rendering into a session we have
        // handed back. Non-throwing by design — see `deactivate`.
        session.deactivate()
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

    #if !os(macOS)

    /// iOS and iPadOS route output themselves.
    ///
    /// There is no equivalent of `kAudioOutputUnitProperty_CurrentDevice`, and
    /// there should not be: the user picks the destination in Control Centre or
    /// with the AirPlay picker, and an app that overrode that would be taking a
    /// decision that is not its to take. `CurrentRouteDeviceSource` reports
    /// whatever the system chose as the single available device, so
    /// `OutputDeviceController` asks for exactly that one and this succeeds
    /// without doing anything.
    ///
    /// Succeeding rather than throwing is the point: a throw here would make the
    /// controller publish "could not switch output", which would be a false
    /// alarm about a switch nobody asked for.
    public func setOutputDevice(_ id: AudioDeviceIdentifier) throws {}

    #else

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

    #endif

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

    /// Turns a platform event into the graph work it implies, and hands the rest
    /// to the owner.
    ///
    /// The *decision* is not made here — `AudioSessionPolicy` makes it, so that
    /// it can be tested on a platform where none of these events occur. This
    /// function only carries it out, and its one piece of real logic is which
    /// "was playing" to ask about.
    private func handle(_ event: AudioSessionEvent) {
        // The transport is asked, not the graph. `isRunning` was the previous
        // answer and it is true from the moment a track is opened — so it called
        // a paused file "playing" and resumed one nobody had started. See
        // `TransportLink.isPlaying`.
        //
        // The *end* of an interruption cannot ask at all: the transport was
        // brought into line when it began, so by now it correctly reads paused.
        // What was true at the start is what has to be consulted at the end.
        if case .interruptionBegan = event { wasPlayingWhenInterrupted = transport.isPlaying() }
        let wasPlaying: Bool
        if case .interruptionEnded = event {
            wasPlaying = wasPlayingWhenInterrupted
            // Consumed, not merely read. The system does repeat these, and a flag
            // left standing would resume a track the user has since paused.
            wasPlayingWhenInterrupted = false
        } else {
            wasPlaying = transport.isPlaying()
        }

        switch AudioSessionPolicy.response(to: event, wasPlaying: wasPlaying) {
        case .none:
            break

        case .pause:
            // Stop before notifying, so `isRunning` is already honest when the
            // owner reads it from inside the callback.
            stop()
            notice = Self.pauseNotice(for: event)
            transport.onInterrupted()

        case .resume:
            transport.onResumeRequested()

        case .reconfigure:
            handleConfigurationChange()
        }
    }

    /// Spec §8: never degrade silently. Playback has stopped on its own, so the
    /// user is owed the reason — the two causes want different words, and
    /// "audio was interrupted" for unplugged headphones would be a puzzle rather
    /// than an explanation.
    private static func pauseNotice(for event: AudioSessionEvent) -> String {
        switch event {
        case .outputDeviceDisappeared:
            return "Playback paused: the output device was disconnected."
        default:
            return "Playback was interrupted by another app or by the system."
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
