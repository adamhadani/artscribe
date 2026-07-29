import ArtscribeKit
import AudioDecode
import Synchronization
import TimeStretch

/// Pulls source frames through a `TimeStretcher` and writes rendered output.
///
/// `render` runs on the CoreAudio render thread: no allocation, no locks, no ARC, no
/// Foundation collections. Every reference type it would otherwise touch
/// (`DecodedAudio.storage`, the scratch `AudioStorage`s) has its channel pointers hoisted
/// into flat C-style tables at `init` time, so `render` sees only pointers and scalars.
///
/// All mutable playback state is owned by the render thread. The main actor communicates
/// in one direction through `CommandRing` and reads back through atomics it polls.
public final class PlaybackEngine: @unchecked Sendable {
    // MARK: Immutable configuration

    /// Held for the lifetime of the channel pointers in `sourceChannels`. **Never read on
    /// the render path** — touching it would mean touching `AudioStorage`, a class.
    private let audio: DecodedAudio
    let stretcher: TimeStretcher
    private let ring: CommandRing
    /// The number of channels `render` writes — always the source's. Public because it is
    /// the precondition on `render`'s pointer table, which the render thread cannot check
    /// and therefore cannot report: a caller that cannot read this count has no way to
    /// size the table correctly. `AudioOutput` takes its channel count from here rather
    /// than being told one, so the two cannot disagree.
    public let channelCount: Int
    let maxBlock: Int
    /// `internal`, not `private`, only because the two extension files read it and Swift's
    /// `private` is file-scoped. Still render-thread-owned; nothing else writes it.
    let totalFrames: FrameIndex

    // MARK: Flat pointer tables, built once in `init`
    //
    // The three the source feed writes through are `internal` rather than `private` only
    // because `PlaybackEngine+Source.swift` is a separate file and Swift's `private` is
    // file-scoped. Nothing outside this class touches any of them.

    /// The source audio, one pointer per channel. Read only through `copySource`.
    let sourceChannels: UnsafeMutablePointer<UnsafePointer<Float>?>
    /// Staging buffer handed to `TimeStretcher.process`, `maxBlock` frames per channel.
    private let feedStorage: AudioStorage
    let feedChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    let feedInput: UnsafeMutablePointer<UnsafePointer<Float>?>
    /// Sink for output that must go nowhere: start-delay priming, and any channel the
    /// caller passed as `nil` (Rubber Band's C `retrieve` does not null-check).
    private let scratchStorage: AudioStorage
    private let scratchChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    /// Rebuilt each `retrieve` to point into the caller's buffer at the write offset.
    private let outChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    // MARK: Render-thread-owned state

    /// Owned by the render thread. The ones `audiblePosition` and `feedSource` need are
    /// `internal` rather than `private` only because those live in
    /// `PlaybackEngine+Position.swift` and `PlaybackEngine+Source.swift`, and Swift's
    /// `private` is file-scoped; nothing outside this class writes any of them.
    ///
    /// How far source has been *fed into* the stretcher. Runs ahead of what is audible.
    var readCursor: FrameIndex = 0
    var loop = LoopRegion()
    private var playing = false
    /// Output frames of start-delay padding still to be thrown away.
    private var primingRemaining = 0
    /// Output frames the stretcher still owes for source already fed, excluding priming.
    /// This is the whole basis of the audible-position compensation; see `audiblePosition`.
    var pendingOutput: Double = 0
    var timeRatio: Double = 1.0
    /// Set once `process(final: true)` has been issued; the stream cannot be fed again
    /// without a `reset`.
    var sourceExhausted = false

    // MARK: Render thread → main actor (polled, never pushed)

    private let positionFrame = Atomic<Int64>(0)
    private let playingFlag = Atomic<Bool>(false)
    private let stallCounter = Atomic<UInt64>(0)
    private let rejectedCounter = Atomic<UInt64>(0)

    public init(
        audio: DecodedAudio, stretcher: TimeStretcher, ring: CommandRing, maxBlock: Int = 1024
    ) {
        precondition(maxBlock > 0, "maxBlock must be positive")
        precondition(audio.channels > 0, "audio must have at least one channel")
        self.audio = audio
        self.stretcher = stretcher
        self.ring = ring
        self.channelCount = audio.channels
        self.maxBlock = maxBlock
        self.totalFrames = audio.frameCount
        self.feedStorage = AudioStorage(channels: audio.channels, capacityFrames: maxBlock)
        self.scratchStorage = AudioStorage(channels: audio.channels, capacityFrames: maxBlock)
        self.sourceChannels = .allocate(capacity: audio.channels)
        self.feedChannels = .allocate(capacity: audio.channels)
        self.feedInput = .allocate(capacity: audio.channels)
        self.scratchChannels = .allocate(capacity: audio.channels)
        self.outChannels = .allocate(capacity: audio.channels)
        for c in 0..<audio.channels {
            (sourceChannels + c).initialize(to: audio.channel(c))
            (feedChannels + c).initialize(to: feedStorage.pointer(c))
            (feedInput + c).initialize(to: UnsafePointer(feedStorage.pointer(c)))
            (scratchChannels + c).initialize(to: scratchStorage.pointer(c))
            (outChannels + c).initialize(to: scratchStorage.pointer(c))
        }
        stretcher.configure(
            sampleRate: audio.sampleRate, channels: audio.channels, maxBlock: maxBlock)
        primingRemaining = stretcher.startDelay
        // Write the sanitized value **back**: otherwise the stretcher would run at the
        // caller's out-of-range ratio while `pendingOutput` accounted at 1.0, drifting the
        // position by exactly that factor — silently, which is what `sanitize` prevents.
        if let sane = Self.sanitize(stretcher.timeRatio) {
            timeRatio = sane
        } else {
            timeRatio = 1.0
            rejectedCounter.wrappingAdd(1, ordering: .relaxed)
        }
        stretcher.timeRatio = timeRatio
    }

    deinit {
        sourceChannels.deinitialize(count: channelCount)
        sourceChannels.deallocate()
        feedChannels.deinitialize(count: channelCount)
        feedChannels.deallocate()
        feedInput.deinitialize(count: channelCount)
        feedInput.deallocate()
        scratchChannels.deinitialize(count: channelCount)
        scratchChannels.deallocate()
        outChannels.deinitialize(count: channelCount)
        outChannels.deallocate()
    }

    // MARK: - Main-actor readable state

    /// The **audible** source frame: the next source frame the listener will hear, not the
    /// frame the engine has fed into the stretcher. See `audiblePosition`.
    public var currentFrame: FrameIndex { positionFrame.load(ordering: .relaxed) }

    public var isPlaying: Bool { playingFlag.load(ordering: .relaxed) }

    /// Number of render blocks that could not be filled because the stretcher stopped
    /// making progress. The render thread cannot throw, log, or block, so a counter for
    /// the UI to poll is how "never degrade silently" (spec §8) is honoured here: the
    /// block is silence-filled, but the silence is never unaccounted for.
    ///
    /// **A stall does not stop playback**, deliberately: a transient one should recover on
    /// the next block rather than dumping the user out of transport. The consequence is
    /// that a *permanent* stall presents as "playing, playhead frozen, silence, forever" —
    /// `isPlaying` stays true and `currentFrame` stops advancing. Whatever surfaces this
    /// counter is therefore reporting a condition the engine will not clear by itself, and
    /// a rising count during playback is the only signal the user will get.
    public var renderStallCount: UInt64 { stallCounter.load(ordering: .relaxed) }

    /// Number of time ratios refused rather than applied — non-finite, or outside
    /// `SpeedState`'s range expressed as a time ratio. Counts both `setTimeRatio` commands
    /// and a ratio the stretcher was already carrying at `init`.
    ///
    /// `SpeedState` is the real gate. This counter exists so that a gate failure surfaces
    /// as a visible anomaly instead of quietly playing at the wrong speed.
    public var rejectedCommandCount: UInt64 { rejectedCounter.load(ordering: .relaxed) }

    // MARK: - Render thread

    /// Render thread entry point. Returns frames written; always fills `frames`, with
    /// silence wherever there is nothing to play.
    ///
    /// - Parameters:
    ///   - output: A table of per-channel write pointers. **Must point to at least
    ///     `channelCount` entries** — every entry in `0..<channelCount` is read. This is
    ///     unchecked: the render thread cannot afford a bounds check and has no way to
    ///     report a violation, so a shorter table reads out of bounds. `channelCount` is
    ///     public so that every caller can size the table from it. Individual entries
    ///     may be `nil`; that channel is skipped and its output discarded, which keeps the
    ///     other channels' frame counts correct.
    ///     Each non-`nil` entry must have room for `frames` values.
    ///   - frames: Frames to produce. Zero is legal and is a no-op returning 0.
    public func render(
        into output: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, frames: Int
    ) -> Int {
        drainCommands()

        guard frames > 0 else {
            positionFrame.store(audiblePosition(), ordering: .relaxed)
            return 0
        }

        // Silence up front, so every exit path below leaves the buffer fully defined.
        for c in 0..<channelCount {
            if let dst = output[c] { dst.update(repeating: 0, count: frames) }
        }

        if playing {
            fill(output, frames: frames)
        }

        positionFrame.store(audiblePosition(), ordering: .relaxed)
        return frames
    }

    private func fill(
        _ output: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, frames: Int
    ) {
        var written = 0
        var iterations = 0
        // Backstop against a stretcher that stops making progress. Every healthy
        // iteration either emits at least one output frame or feeds at least one source
        // frame, so this can only be reached by a misbehaving stretcher.
        let iterationLimit = frames * 8 + 64

        while written < frames {
            iterations += 1
            if iterations > iterationLimit {
                stall()
                return
            }

            let ready = stretcher.available()
            if ready > 0 {
                if primingRemaining > 0 {
                    // Discard start-delay padding into scratch. `got` is subtracted
                    // honestly: a zero return is a stall, not an excuse to fake progress.
                    let want = min(min(ready, primingRemaining), maxBlock)
                    let got = stretcher.retrieve(UnsafePointer(scratchChannels), frames: want)
                    if got <= 0 {
                        stall()
                        return
                    }
                    primingRemaining -= got
                    continue
                }

                let want = min(min(ready, frames - written), maxBlock)
                for c in 0..<channelCount {
                    if let dst = output[c] {
                        outChannels[c] = dst + written
                    } else {
                        outChannels[c] = scratchChannels[c]
                    }
                }
                let got = stretcher.retrieve(UnsafePointer(outChannels), frames: want)
                if got <= 0 {
                    stall()
                    return
                }
                written += got
                pendingOutput -= Double(got)
                if pendingOutput < 0 { pendingOutput = 0 }
                continue
            }

            // Nothing ready. Either feed more source, or the stream really is over.
            if sourceExhausted || !feedSource() {
                playing = false
                playingFlag.store(false, ordering: .relaxed)
                return
            }
        }
    }

    private func stall() {
        stallCounter.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Commands

    private func drainCommands() {
        while let command = ring.pop() {
            switch command {
            case .seek(let frame):
                readCursor = max(0, min(frame, totalFrames))
                restartStream()
            case .setTimeRatio(let ratio):
                if let sane = Self.sanitize(ratio) {
                    stretcher.timeRatio = sane
                    timeRatio = sane
                } else {
                    rejectedCounter.wrappingAdd(1, ordering: .relaxed)
                }
            case .setPitchScale(let scale):
                // Same sanitiser as the time ratio: both are multipliers a
                // hand-edited sidecar or an arithmetic slip could make NaN, and
                // handing NaN to Rubber Band poisons the whole output stream.
                // The bounds coincide too — one octave either way is inside
                // SpeedState's 0.1...2.0 window.
                if let sane = Self.sanitize(scale) {
                    stretcher.pitchScale = sane
                } else {
                    rejectedCounter.wrappingAdd(1, ordering: .relaxed)
                }
            case .setLoop(let range, let enabled):
                loop = LoopRegion(range: range.clamped(to: totalFrames), isEnabled: enabled)
                if sourceExhausted && loop.isActive { resumeAfterEndOfFile() }
            case .setPlaying(let value):
                if value && sourceExhausted { resumeAfterEndOfFile() }
                playing = value
                playingFlag.store(value, ordering: .relaxed)
            }
        }
    }

    /// Rejects ratios that would poison the position arithmetic below — a NaN
    /// `pendingOutput` would trap on the `Double` → `Int64` conversion. The bounds are
    /// `SpeedState`'s speed range expressed as time ratios (its reciprocal, hence the swap).
    private static func sanitize(_ ratio: Double) -> Double? {
        guard ratio.isFinite else { return nil }
        guard ratio >= 1.0 / SpeedState.maxRatio, ratio <= 1.0 / SpeedState.minRatio else {
            return nil
        }
        return ratio
    }

    /// Re-primes the stretcher after a genuine discontinuity (a seek, or resuming a stream
    /// that was finalised at end of file).
    ///
    /// **Never called at a loop boundary.** Resetting there flushes Rubber Band's internal
    /// overlap state and clicks on every repetition — spec §5.1, the single most important
    /// detail in this engine. `feedSource` wraps by feeding continuously instead.
    private func restartStream() {
        stretcher.reset()
        primingRemaining = stretcher.startDelay
        pendingOutput = 0
        sourceExhausted = false
    }

    /// The stream was finalised at end of file and something has asked for audio again —
    /// `.setPlaying(true)`, or a loop switched on while parked on the last frame.
    ///
    /// A cursor sitting at the end of the file has nothing left to play, so an active loop
    /// takes it back to its in point. That is not in tension with honouring an explicit
    /// seek: `sourceExhausted` is the discriminator, and it is only ever true because
    /// playback *ran off the end*, never because the user asked to be here — `.seek` clears
    /// it through `restartStream`. Without this, pressing play at end of file with a loop
    /// running would finalise the stream again inside the same render call and nothing
    /// would be heard, which is the trap `TransportLatch.rewindTarget` documents and
    /// deliberately leaves to the engine when a loop is active.
    ///
    /// Not a loop boundary, so §5.1 does not apply — and `restartStream` resets anyway.
    private func resumeAfterEndOfFile() {
        if loop.isActive && readCursor >= loop.range.end { readCursor = loop.range.start }
        restartStream()
    }

    // The source feed and the loop wrap live in `PlaybackEngine+Source.swift`; the
    // audible-position arithmetic lives in `PlaybackEngine+Position.swift`.
}
