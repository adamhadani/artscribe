/// A 1:1 passthrough with zero latency, ignoring `timeRatio`.
///
/// Not test scaffolding: `PlaybackEngine` (Task 8) depends on this type to keep
/// sample positions and loop-wrap behaviour exactly assertable — with a real
/// stretcher's latency and internal priming in the way, those assertions are
/// impossible. Because it is reached through the same `TimeStretcher` protocol
/// that governs the render-thread-facing `RubberBandStretcher`, it upholds the
/// same "allocation-free after `configure`" contract using manually managed raw
/// buffers rather than nested Swift arrays, whose in-place-mutation behaviour
/// under `[[Float]]` double subscripting is not a documented guarantee.
public final class IdentityStretcher: TimeStretcher {
    private var channelCount = 0
    private var maxBlock = 0
    private var capacity = 0
    private var buffers: [UnsafeMutablePointer<Float>] = []
    private var count = 0

    public init() {}

    public var timeRatio: Double = 1.0
    /// Recorded and otherwise ignored. This stretcher passes audio through
    /// untouched by definition, so honouring a pitch scale would make it not an
    /// identity — the tests that use it are asserting what the *rest* of the
    /// graph does, and a resampling pass here would corrupt that.
    public var pitchScale: Double = 1.0
    public var startDelay: Int { 0 }

    public func configure(sampleRate: Double, channels: Int, maxBlock: Int) {
        freeBuffers()
        channelCount = channels
        self.maxBlock = maxBlock
        capacity = maxBlock * 8
        buffers = (0..<channels).map { _ in
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            buf.initialize(repeating: 0, count: capacity)
            return buf
        }
        count = 0
    }

    deinit {
        freeBuffers()
    }

    private func freeBuffers() {
        for buf in buffers {
            buf.deinitialize(count: capacity)
            buf.deallocate()
        }
        buffers = []
    }

    public func samplesRequired() -> Int { maxBlock }
    public func available() -> Int { count }

    public func process(_ input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool) {
        guard frames > 0 else { return }
        // A programming-contract violation (caller pushed more than it drained)
        // should fail loudly rather than silently drop samples — see design
        // principle "never degrade silently".
        precondition(
            count + frames <= capacity,
            "IdentityStretcher overflow: caller must drain available() before pushing more"
        )
        for c in 0..<channelCount {
            guard let src = input[c] else { continue }
            buffers[c].advanced(by: count).update(from: src, count: frames)
        }
        count += frames
    }

    public func retrieve(
        _ output: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int
    ) -> Int {
        let n = Swift.min(frames, count)
        guard n > 0 else { return 0 }
        let remaining = count - n
        for c in 0..<channelCount {
            if let dst = output[c] {
                dst.update(from: buffers[c], count: n)
            }
            if remaining > 0 {
                // `update(from:count:)` requires non-overlapping source/destination
                // (it is a memcpy), but shifting the unread tail down within the
                // same buffer is inherently an overlapping copy when `remaining > n`.
                // `copyMemory(from:byteCount:)` is explicitly memmove-safe for that.
                UnsafeMutableRawPointer(buffers[c]).copyMemory(
                    from: UnsafeRawPointer(buffers[c].advanced(by: n)),
                    byteCount: remaining * MemoryLayout<Float>.stride)
            }
        }
        count = remaining
        return n
    }

    public func reset() { count = 0 }
}
