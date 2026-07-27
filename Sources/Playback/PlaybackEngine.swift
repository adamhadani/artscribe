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
    private let stretcher: TimeStretcher
    private let ring: CommandRing
    private let channels: Int
    private let maxBlock: Int
    private let totalFrames: FrameIndex

    // MARK: Flat pointer tables, built once in `init`

    /// The source audio, one pointer per channel. Read only through `copySource`.
    private let sourceChannels: UnsafeMutablePointer<UnsafePointer<Float>?>
    /// Staging buffer handed to `TimeStretcher.process`, `maxBlock` frames per channel.
    private let feedStorage: AudioStorage
    private let feedChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let feedInput: UnsafeMutablePointer<UnsafePointer<Float>?>
    /// Sink for output that must go nowhere: start-delay priming, and any channel the
    /// caller passed as `nil` (Rubber Band's C `retrieve` does not null-check).
    private let scratchStorage: AudioStorage
    private let scratchChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    /// Rebuilt each `retrieve` to point into the caller's buffer at the write offset.
    private let outChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    // MARK: Render-thread-owned state

    /// How far source has been *fed into* the stretcher. Runs ahead of what is audible.
    private var readCursor: FrameIndex = 0
    private var loop = LoopRegion()
    private var playing = false
    /// Output frames of start-delay padding still to be thrown away.
    private var primingRemaining = 0
    /// Output frames the stretcher still owes for source already fed, excluding priming.
    /// This is the whole basis of the audible-position compensation; see `audiblePosition`.
    private var pendingOutput: Double = 0
    private var timeRatio: Double = 1.0
    /// Set once `process(final: true)` has been issued; the stream cannot be fed again
    /// without a `reset`.
    private var sourceExhausted = false

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
        self.channels = audio.channels
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
        sourceChannels.deinitialize(count: channels)
        sourceChannels.deallocate()
        feedChannels.deinitialize(count: channels)
        feedChannels.deallocate()
        feedInput.deinitialize(count: channels)
        feedInput.deallocate()
        scratchChannels.deinitialize(count: channels)
        scratchChannels.deallocate()
        outChannels.deinitialize(count: channels)
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
    ///     `audio.channels` entries** — every entry in `0..<audio.channels` is read. This
    ///     is unchecked: the render thread cannot afford a bounds check and has no way to
    ///     report a violation, so a shorter table reads out of bounds. Individual entries
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
        for c in 0..<channels {
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
                for c in 0..<channels {
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
            case .setLoop(let range, let enabled):
                loop = LoopRegion(range: range.clamped(to: totalFrames), isEnabled: enabled)
                // Re-entering a loop after the stream was finalised needs a fresh stream;
                // this is not a loop boundary, so §5.1 does not apply.
                if sourceExhausted && loop.isActive { restartStream() }
            case .setPlaying(let value):
                if value && sourceExhausted { restartStream() }
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

    // MARK: - Source

    /// The one place on the render path that reads source audio.
    ///
    /// Stem separation (spec §11.3) replaces the single `sourceChannels` table with N stem
    /// tables summed here; no other part of the render path reads samples, so that swap
    /// stays contained. Nothing is built for it now.
    @inline(__always)
    private func copySource(from frame: FrameIndex, into offset: Int, count: Int) {
        let base = Int(frame)
        for c in 0..<channels {
            guard let src = sourceChannels[c], let dst = feedChannels[c] else { continue }
            (dst + offset).update(from: src + base, count: count)
        }
    }

    /// Pushes one block of source into the stretcher, wrapping across the loop boundary
    /// **without** resetting (spec §5.1). Returns false when there is nothing left to feed.
    private func feedSource() -> Bool {
        let required = max(1, min(stretcher.samplesRequired(), maxBlock))
        let looping = loop.isActive

        var produced = 0
        while produced < required {
            // The single wrap point. When looping, `loop.range.count > 0` (that is what
            // `isActive` means), so after a wrap `remaining == count >= 1` and `produced`
            // strictly increases — the loop cannot spin however short the region is.
            if looping && readCursor >= loop.range.end { readCursor = loop.range.start }
            let end = looping ? loop.range.end : totalFrames
            let remaining = end - readCursor
            // Only reachable when not looping: end of file.
            if remaining <= 0 { break }
            let n = Int(min(FrameIndex(required - produced), remaining))
            copySource(from: readCursor, into: produced, count: n)
            readCursor += FrameIndex(n)
            produced += n
        }

        // Tell the stretcher the stream ended, or its tail — the last fraction of a second
        // of the file — is never flushed and the file ends early.
        let atEndOfFile = !looping && readCursor >= totalFrames

        guard produced > 0 else {
            guard atEndOfFile && !sourceExhausted else { return false }
            stretcher.process(UnsafePointer(feedInput), frames: 0, final: true)
            sourceExhausted = true
            return true
        }

        stretcher.process(UnsafePointer(feedInput), frames: produced, final: atEndOfFile)
        pendingOutput += Double(produced) * timeRatio
        if atEndOfFile { sourceExhausted = true }
        return true
    }

    // MARK: - Position

    /// The audible source position (spec §5): where the listener is, not where the feed
    /// cursor is.
    ///
    /// `readCursor` runs ahead of the sound by whatever the stretcher still holds.
    /// `pendingOutput` tracks that backlog in *output* frames — incremented by
    /// `producedFrames × timeRatio` on every feed, decremented by every frame retrieved —
    /// so dividing by `timeRatio` converts it back to source frames, and rewinding the
    /// cursor by that much lands on the next frame to be heard. Start-delay priming is
    /// excluded by construction: it is discarded without touching `pendingOutput`, because
    /// it corresponds to no source at all.
    ///
    /// Exact whenever `timeRatio` is constant. A ratio change leaves the in-flight backlog
    /// briefly mis-scaled (produced at the old ratio), an error bounded by one backlog that
    /// drains within a block or two.
    ///
    /// This is the position at the end of the block just rendered; the further offset to
    /// the DAC belongs to the output layer, which knows the device buffer size.
    private func audiblePosition() -> FrameIndex {
        guard pendingOutput.isFinite, pendingOutput > 0, timeRatio > 0 else {
            return clampToFile(readCursor)
        }
        let backlog = (pendingOutput / timeRatio).rounded()
        guard backlog.isFinite, backlog >= 1 else { return clampToFile(readCursor) }
        let steps = FrameIndex(min(backlog, Double(Int32.max)))
        return clampToFile(rewind(readCursor, by: steps))
    }

    /// Walks `cursor` back `frames` source frames, *through* the loop wrap when one is
    /// active — inside a loop the source position of already-emitted output is not
    /// `cursor - frames`.
    private func rewind(_ cursor: FrameIndex, by frames: FrameIndex) -> FrameIndex {
        let range = loop.range
        guard loop.isActive, cursor >= range.start, cursor <= range.end else {
            return max(0, cursor - frames)
        }
        var offset = (cursor - range.start - frames) % range.count
        if offset < 0 { offset += range.count }
        return range.start + offset
    }

    private func clampToFile(_ frame: FrameIndex) -> FrameIndex {
        max(0, min(frame, totalFrames))
    }
}
