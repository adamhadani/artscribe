// Homebrew's Rubber Band is a macOS dylib; there is no iOS build of it to link
// against, so the module simply is not there for an iOS destination. Guarding on
// `canImport` rather than `os(macOS)` keeps the condition to the actual fact —
// whether the library is available — and matches the conditional dependency in
// `Package.swift`.
#if canImport(CRubberBand)

import CRubberBand

/// Wraps the Rubber Band C API behind `TimeStretcher`. R3 "Finer" (`.studio`) is the
/// quality core of the product; R2 "Faster" (`.fast`) trades quality for headroom.
///
/// That trade-off is measured, not assumed: `StretchQualityTests.halfSpeedPreservesPitch`
/// holds `.studio` to within a couple of cents of true pitch and `.fast` to within ~30
/// cents, because R2's phase vocoder genuinely drifts pitch by a frequency- and
/// ratio-dependent amount (measured up to ~26 cents) that R3 does not exhibit. See that
/// test's doc comment for the full measured table. This is intentionally asymmetric —
/// widening `.studio`'s bound to match would hide a real regression in the engine this
/// whole product exists to showcase.
public final class RubberBandStretcher: TimeStretcher {

    /// Which of Rubber Band's two engines to build.
    ///
    /// Its **own** enum rather than `ArtscribeKit.StretchEngine`, which is what
    /// this used to take. That type now names four backends, only two of which
    /// are Rubber Band, and the mapping here was `engine == .studio ? Finer :
    /// Faster` — a comparison, not a switch, so `.signalsmith` reaching this
    /// initialiser would have quietly built R2 Faster and played the wrong
    /// engine with nothing to show for it. A type that cannot express the
    /// question is a better fix than remembering to ask it correctly.
    ///
    /// `PlatformStretcher` is now the single place that translates between the
    /// two, and its switch is exhaustive.
    public enum Core: Sendable {
        /// R3 "Finer" — the quality core of the product.
        case finer
        /// R2 "Faster" — low CPU, and it drifts pitch. See `StretchQualityTests`.
        case faster
    }

    private var state: RubberBandState?
    private let core: Core
    private var pendingRatio: Double = 1.0
    private var pendingPitch: Double = 1.0

    public init(core: Core = .finer) {
        self.core = core
    }

    deinit {
        if let state { rubberband_delete(state) }
    }

    public func configure(sampleRate: Double, channels: Int, maxBlock: Int) {
        if let state { rubberband_delete(state) }
        let engineFlag =
            switch core {
            case .finer: RubberBandOptionEngineFiner.rawValue
            case .faster: RubberBandOptionEngineFaster.rawValue
            }
        let opts = RubberBandOptions(RubberBandOptionProcessRealTime.rawValue | engineFlag)
        let newState = rubberband_new(
            UInt32(sampleRate), UInt32(channels), opts, pendingRatio, pendingPitch)
        // Not expected to fail under normal parameters (there's no documented
        // failure mode for rubberband_new), but proceeding silently on a null
        // state would contradict "never degrade silently" — fail loudly instead.
        precondition(newState != nil, "rubberband_new returned a null state")
        state = newState
        // Pre-size so process()/retrieve() never allocate on the render thread.
        rubberband_set_max_process_size(newState, UInt32(maxBlock))
        // Re-applied here for the same reason `pendingRatio` is: a pitch chosen
        // before the engine existed, or before an engine switch rebuilt it,
        // would otherwise be silently dropped on the floor.
        rubberband_set_pitch_scale(newState, pendingPitch)
    }

    public var timeRatio: Double {
        get { state.map { rubberband_get_time_ratio($0) } ?? pendingRatio }
        set {
            pendingRatio = newValue
            if let state { rubberband_set_time_ratio(state, newValue) }
        }
    }

    public var pitchScale: Double {
        get { state.map { rubberband_get_pitch_scale($0) } ?? pendingPitch }
        set {
            pendingPitch = newValue
            if let state { rubberband_set_pitch_scale(state, newValue) }
        }
    }

    /// Output frames of priming to discard after configure/reset. Measured at 44.1 kHz in
    /// real-time mode: 2048 for `.studio` (R3), 1024 for `.fast` (R2). Both are non-zero and
    /// both must be compensated the same way; only the magnitude differs between engines.
    public var startDelay: Int {
        guard let state else { return 0 }
        return Int(rubberband_get_start_delay(state))
    }

    public func samplesRequired() -> Int {
        guard let state else { return 0 }
        return Int(rubberband_get_samples_required(state))
    }

    public func available() -> Int {
        guard let state else { return 0 }
        // `rubberband_available` can return a negative value at end-of-stream; that
        // means "no more data, and stream is finished", which we treat as zero.
        return Swift.max(0, Int(rubberband_available(state)))
    }

    public func process(_ input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool) {
        guard let state else { return }
        rubberband_process(state, input, UInt32(frames), final ? 1 : 0)
    }

    public func retrieve(
        _ output: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int
    ) -> Int {
        guard let state else { return 0 }
        return Int(rubberband_retrieve(state, output, UInt32(frames)))
    }

    public func reset() {
        guard let state else { return }
        rubberband_reset(state)
    }
}

#endif
