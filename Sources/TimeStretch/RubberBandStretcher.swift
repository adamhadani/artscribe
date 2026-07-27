import ArtscribeKit
import CRubberBand

/// Wraps the Rubber Band C API behind `TimeStretcher`. R3 "Finer" (`.studio`) is the
/// quality core of the product; R2 "Faster" (`.fast`) trades quality for headroom.
public final class RubberBandStretcher: TimeStretcher {
    private var state: RubberBandState?
    private let engine: StretchEngine
    private var pendingRatio: Double = 1.0

    public init(engine: StretchEngine) {
        self.engine = engine
    }

    deinit {
        if let state { rubberband_delete(state) }
    }

    public func configure(sampleRate: Double, channels: Int, maxBlock: Int) {
        if let state { rubberband_delete(state) }
        let engineFlag =
            engine == .studio
            ? RubberBandOptionEngineFiner.rawValue
            : RubberBandOptionEngineFaster.rawValue
        let opts = RubberBandOptions(RubberBandOptionProcessRealTime.rawValue | engineFlag)
        let newState = rubberband_new(UInt32(sampleRate), UInt32(channels), opts, pendingRatio, 1.0)
        state = newState
        // Pre-size so process()/retrieve() never allocate on the render thread.
        rubberband_set_max_process_size(newState, UInt32(maxBlock))
    }

    public var timeRatio: Double {
        get { state.map { rubberband_get_time_ratio($0) } ?? pendingRatio }
        set {
            pendingRatio = newValue
            if let state { rubberband_set_time_ratio(state, newValue) }
        }
    }

    /// Output frames of priming to discard after configure/reset. 2048 for R3 at 44.1 kHz.
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
