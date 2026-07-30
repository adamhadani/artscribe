import CSignalsmithStretch

/// Signalsmith Stretch (MIT) behind `TimeStretcher`.
///
/// The portable backend. Rubber Band comes from Homebrew as a macOS dylib and
/// cannot be shipped to a phone; this one is vendored source that we compile,
/// so it builds wherever Swift does. It is also the independent quality
/// reference the Rubber Band A/B needs, and — being MIT rather than
/// GPL-or-commercial — the only one of the two that can go into an App Store
/// build without a licence purchase. See `docs/LICENSING.md`.
///
/// ## Why this class holds a buffer, and Rubber Band's wrapper does not
///
/// The two libraries disagree about who decides how much output exists.
///
/// Rubber Band is push-then-pull: hand it input with `process()`, ask
/// `available()` how much came out, take it with `retrieve()`. The amount is
/// the library's business and varies from call to call. `TimeStretcher` is
/// shaped that way because Rubber Band was the first backend.
///
/// Signalsmith is a single call — *consume exactly N, produce exactly M* — and
/// the ratio between the two counts **is** the time ratio. There is no setter
/// and nothing to query.
///
/// Two ways to bridge that. Widen `TimeStretcher` with a second entry point and
/// teach `PlaybackEngine.render` to pick per backend; or absorb the difference
/// here, behind the protocol that already exists. This class is the second
/// choice, deliberately:
///
/// - `PlaybackEngine.fill` stays **one** render loop rather than two. It is the
///   most safety-critical function in the project and it is already proven, by
///   a differential test, to loop without a seam. Keeping a single path means
///   that proof extends to this backend by substitution — which is exactly how
///   `signalsmithLoopingIsIndistinguishableFromAContiguousRender` is written —
///   instead of having to be re-established for a second path.
/// - The cost is one `memcpy` per block out of the ring below. Spec §5's
///   real-time rule forbids *allocation*, not copying, and every buffer here is
///   allocated in `configure`. `IdentityStretcher` already pays the same copy,
///   and Rubber Band buffers internally regardless — it just does it out of
///   sight.
///
/// If profiling ever shows that copy mattering, the widened protocol is still
/// available and this comment is the argument to revisit. It has not been
/// measured to matter, so it has not been done.
public final class SignalsmithStretcher: TimeStretcher {

    /// How the analysis is configured. Mirrors `StretchEngine`'s intent —
    /// quality against CPU — using the library's own two presets rather than
    /// inventing a third scale.
    public enum Quality: Sendable {
        /// `presetDefault`: a 120 ms analysis block at a 30 ms interval.
        case standard
        /// `presetCheaper`: a shorter block, less CPU, lower quality.
        case cheaper
    }

    /// The largest time ratio the buffer below is sized for.
    ///
    /// `SpeedState` clamps user-facing speed to `0.10...2.00` and the time ratio
    /// is its reciprocal, so 10 is the real ceiling, not a guess. Sized from the
    /// constant rather than from a literal so that widening the speed range
    /// cannot silently outgrow the buffer — but *not* imported from
    /// `ArtscribeKit`, because a stretcher must not need to know what a
    /// transport thinks. The test `ringIsSizedForTheFullSpeedRange` is what ties
    /// the two together.
    static let ratioCeiling = 10.0

    private let quality: Quality
    private var shim: OpaquePointer?

    private var channelCount = 0
    private var maxBlock = 0
    private var capacity = 0

    /// Output waiting to be `retrieve`d, planar, one allocation per channel.
    private var ring: [UnsafeMutablePointer<Float>] = []
    private var count = 0

    /// Pointer tables handed to C, refilled per call. Preallocated so that
    /// building them allocates nothing on the render thread.
    private var inputTable: UnsafeMutablePointer<UnsafePointer<Float>>?
    private var outputTable: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    /// Stands in for a null input channel, which the C shim will not accept.
    private var silence: UnsafeMutablePointer<Float>?

    /// Fractional output frames carried between calls.
    ///
    /// `frames * timeRatio` is rarely a whole number, and truncating each call
    /// independently would lose up to one frame per block — at a 512-frame block
    /// that is a drift of about 86 frames per second of audio, which the playhead
    /// would show as the position falling steadily behind the sound.
    private var outputDebt = 0.0

    /// Signalsmith's tail is drained once, by `flush`. Asking twice would append
    /// a second copy of the last few milliseconds to the end of the file.
    private var flushed = false

    private var inputLatencyFrames = 0
    private var outputLatencyFrames = 0

    public init(quality: Quality = .standard) {
        self.quality = quality
    }

    deinit {
        if let shim { ss_stretch_destroy(shim) }
        freeBuffers()
    }

    // MARK: - Configuration

    public func configure(sampleRate: Double, channels: Int, maxBlock: Int) {
        freeBuffers()
        if let shim { ss_stretch_destroy(shim) }
        shim = ss_stretch_create()
        guard let shim else {
            // Matches `RubberBandStretcher`'s treatment of a null state: there is
            // no recovery from "the stretcher does not exist", and carrying on
            // would mean silently playing at the wrong speed.
            preconditionFailure("ss_stretch_create returned null")
        }

        channelCount = channels
        self.maxBlock = maxBlock
        ss_stretch_configure(
            shim, Int32(channels), sampleRate, quality == .cheaper, Self.splitComputation)
        inputLatencyFrames = Int(ss_stretch_input_latency(shim))
        outputLatencyFrames = Int(ss_stretch_output_latency(shim))
        ss_stretch_set_transpose_factor(shim, Float(pitchScale))

        // Sized for the worst case at the slowest speed the transport allows,
        // never for the common one. Three terms, and the second is the one that
        // is easy to forget: a full block of output, the whole flush tail, and a
        // block that has not been drained yet.
        //
        // The tail is `startDelay` at the ceiling ratio — 30429 frames at 44.1
        // kHz, against an `outputLatency` of 3969. Sizing for the smaller number
        // and clamping the tail to fit is what the first draft did, and it lost
        // 0.94% of the track at 0.1× speed while every test at 1× stayed green.
        let blockOutput = Int((Double(maxBlock) * Self.ratioCeiling).rounded(.up))
        let tailOutput =
            Int((Double(inputLatencyFrames) * Self.ratioCeiling).rounded(.up)) + outputLatencyFrames
        capacity = blockOutput + tailOutput + maxBlock + 64

        ring = (0..<channels).map { _ in
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
            return buffer
        }
        let input = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: max(1, channels))
        let output = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(
            capacity: max(1, channels))
        let quiet = UnsafeMutablePointer<Float>.allocate(capacity: max(1, maxBlock))
        quiet.initialize(repeating: 0, count: max(1, maxBlock))
        for c in 0..<channels {
            input.advanced(by: c).initialize(to: UnsafePointer(quiet))
            output.advanced(by: c).initialize(to: ring[c])
        }
        inputTable = input
        outputTable = output
        silence = quiet

        count = 0
        outputDebt = 0
        flushed = false
    }

    /// Spreading each spectral block's work across the calls that follow it,
    /// rather than doing all of it in the call that triggers it.
    ///
    /// True, always, because every call site of this class is a render thread.
    /// The library defaults it off for `presetDefault`, which suits offline use:
    /// off means one call in every interval — about one in three at a 512-frame
    /// block — does an entire FFT block's work while its neighbours do almost
    /// none. Offline that is the cheaper total; on a render thread it is a
    /// periodic spike against a hard deadline, which is the shape a dropout has.
    /// The price is one interval of extra output latency, which `startDelay`
    /// already accounts for.
    private static let splitComputation = true

    private func freeBuffers() {
        for buffer in ring {
            buffer.deinitialize(count: capacity)
            buffer.deallocate()
        }
        ring = []
        if let inputTable {
            inputTable.deinitialize(count: max(1, channelCount))
            inputTable.deallocate()
        }
        if let outputTable {
            outputTable.deinitialize(count: max(1, channelCount))
            outputTable.deallocate()
        }
        if let silence {
            silence.deinitialize(count: max(1, maxBlock))
            silence.deallocate()
        }
        inputTable = nil
        outputTable = nil
        silence = nil
    }

    // MARK: - Ratios

    public var timeRatio: Double = 1.0

    public var pitchScale: Double = 1.0 {
        didSet {
            if let shim { ss_stretch_set_transpose_factor(shim, Float(pitchScale)) }
        }
    }

    /// Output frames of priming to discard after `configure`/`reset`.
    ///
    /// The library reports its latency in two halves that are **not** in the same
    /// units, and adding them directly is the mistake this property exists to
    /// avoid: `inputLatency` counts *input* frames and `outputLatency` counts
    /// *output* frames. One input frame becomes `timeRatio` output frames, so the
    /// analysis half has to be converted before the two can be summed.
    ///
    /// The same conversion, in the other direction, is what the library's own
    /// `outputSeekLength(rate) = inputLatency + rate*outputLatency` does — that
    /// helper answers in input frames, this answers in output frames, and the
    /// engine wants output frames because `primingRemaining` counts what it
    /// discards from `retrieve`.
    ///
    /// Getting this wrong does not crash and does not sound wrong. It makes the
    /// playhead lie by a fixed offset, which is why `measuredStartDelayMatchesTheReportedOne`
    /// checks the number against an impulse rather than against this arithmetic.
    public var startDelay: Int {
        Int((Double(inputLatencyFrames) * timeRatio).rounded()) + outputLatencyFrames
    }

    // MARK: - The render-thread path

    /// How much input to ask for next.
    ///
    /// Chosen so the *output* block lands near `maxBlock` whatever the speed:
    /// the engine sizes its buffers by output, and a fixed input block would
    /// produce ten times as much output at 0.1× speed as at 1×.
    public func samplesRequired() -> Int {
        guard maxBlock > 0, timeRatio > 0 else { return 0 }
        let wanted = (Double(maxBlock) / timeRatio).rounded()
        return Swift.max(1, Swift.min(Int(wanted), maxBlock))
    }

    public func available() -> Int { count }

    public func process(_ input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool) {
        guard let shim, let inputTable, let outputTable, let silence else { return }

        if frames > 0 {
            outputDebt += Double(frames) * timeRatio
            // At least one frame: `process` with a zero output count still
            // consumes its input, so a zero here would swallow audio whenever a
            // very short feed rounded down.
            let produce = Swift.max(1, Int(outputDebt))
            outputDebt -= Double(produce)
            // Loud, never clamped. Clamping here is how the flush tail lost most
            // of itself at 0.1× speed while looking fine at 1×, and a stretcher
            // that quietly emits less than it was asked for is the silent
            // degradation spec §8 forbids. Reaching this means `timeRatio` went
            // past `ratioCeiling`, which `PlaybackEngine` sanitises against.
            precondition(
                count + produce <= capacity,
                "SignalsmithStretcher overflow: drain available() before pushing more"
            )
            for c in 0..<channelCount {
                inputTable[c] = input[c] ?? UnsafePointer(silence)
                outputTable[c] = ring[c] + count
            }
            ss_stretch_process(
                shim, inputTable, Int32(frames), outputTable, Int32(produce))
            count += produce
        }

        // The tail. Its length is `startDelay`, not `outputLatencyFrames` — the
        // same two-part sum, for the same reason, at the other end of the file.
        // Draining only the synthesis half measured 2646 frames short at ratio
        // 1.0 (60 ms of the track's ending, silently missing); the analysis half
        // is still holding `inputLatency` input frames, which are worth
        // `inputLatency * timeRatio` frames of output.
        if final && !flushed {
            flushed = true
            let tail = startDelay
            precondition(count + tail <= capacity, "SignalsmithStretcher: no room for the tail")
            guard tail > 0 else { return }
            for c in 0..<channelCount {
                outputTable[c] = ring[c] + count
            }
            ss_stretch_flush(shim, outputTable, Int32(tail), Float(1.0 / timeRatio))
            count += tail
        }
    }

    public func retrieve(
        _ output: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int
    ) -> Int {
        let taken = Swift.min(frames, count)
        guard taken > 0 else { return 0 }
        let remaining = count - taken
        for c in 0..<channelCount {
            if let destination = output[c] {
                destination.update(from: ring[c], count: taken)
            }
            if remaining > 0 {
                // Overlapping when `remaining > taken`, so memmove semantics are
                // required — the same reason `IdentityStretcher.retrieve` reaches
                // for `copyMemory` rather than `update(from:count:)`.
                UnsafeMutableRawPointer(ring[c]).copyMemory(
                    from: UnsafeRawPointer(ring[c].advanced(by: taken)),
                    byteCount: remaining * MemoryLayout<Float>.stride)
            }
        }
        count = remaining
        return taken
    }

    /// Drops every trace of the stream so far.
    ///
    /// **Never call this at a loop boundary.** Spec §5.1's central rule, and it
    /// binds this backend exactly as it binds Rubber Band: the phase-vocoder
    /// state that makes a wrap inaudible is precisely what this throws away. In
    /// `PlaybackEngine` it is reachable only from an explicit seek and from
    /// resuming after end-of-file, and
    /// `signalsmithLoopingIsIndistinguishableFromAContiguousRender` is what keeps
    /// it that way.
    public func reset() {
        guard let shim else { return }
        ss_stretch_reset(shim)
        count = 0
        outputDebt = 0
        flushed = false
    }
}
