import Synchronization

/// Single-producer / single-consumer lock-free ring buffer.
///
/// `push` is called from the main actor; `pop` from the render thread. One slot is always
/// left empty so full and empty are distinguishable without a separate count.
///
/// Memory ordering (this is a standard SPSC ring; verified, not merely assumed):
/// - `tail` is release-published by `push` and acquired by `pop`, so the plain (non-atomic)
///   write `buffer.advanced(by: t).initialize(to:)` happens-before the consumer's read of
///   that same slot in `pop`.
/// - `head` is release-published by `pop` and acquired by `push`, so the consumer's
///   destructive `move()` of a slot happens-before the producer is allowed to reuse (write
///   into) that same slot on the next lap around the buffer.
/// - Each side re-reads its *own* counter (the one only it writes) with `.relaxed`. That is
///   safe because a single writer always observes its own prior atomic writes in program
///   order; the cross-thread guarantee only needs to come from the acquire/release pairing
///   on the *other* counter.
/// - Because there is exactly one producer and one consumer, `head`/`tail` differ by at
///   most one "lap" at any time, so comparing raw indices mod `capacity` (no separate lap or
///   generation counter) is sufficient to distinguish full from empty at every wrap point.
public final class CommandRing: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<PlaybackCommand>
    private let head = Atomic<Int>(0)  // next slot to read  (consumer)
    private let tail = Atomic<Int>(0)  // next slot to write (producer)

    public init(capacity: Int = 256) {
        precondition(capacity >= 2)
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
    }

    deinit {
        // Deinitialize any commands still queued at teardown. `push` uses `initialize(to:)`
        // and `pop` uses `move()` (which deinitializes), so anything never popped would
        // otherwise be deallocated without being deinitialized. Every `PlaybackCommand`
        // payload today is trivial (Int64/Double/Bool), so this loop is a no-op in
        // practice -- but it costs nothing to get right, and it means the ring stays
        // correct rather than merely "correct today" if a payload ever gains a reference
        // type. No concurrent access is possible here: ARC guarantees `deinit` only runs
        // once there are no other references, so both counters are read with `.relaxed`.
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .relaxed)
        while h != t {
            buffer.advanced(by: h).deinitialize(count: 1)
            h = (h + 1) % capacity
        }
        buffer.deallocate()
    }

    /// Producer side. Returns false if the ring is full rather than blocking.
    @discardableResult
    public func push(_ command: PlaybackCommand) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let next = (t + 1) % capacity
        if next == head.load(ordering: .acquiring) { return false }
        buffer.advanced(by: t).initialize(to: command)
        tail.store(next, ordering: .releasing)
        return true
    }

    /// Consumer side. Allocation-free, lock-free, and wait-free; safe on the render thread.
    public func pop() -> PlaybackCommand? {
        let h = head.load(ordering: .relaxed)
        if h == tail.load(ordering: .acquiring) { return nil }
        let value = buffer.advanced(by: h).move()
        head.store((h + 1) % capacity, ordering: .releasing)
        return value
    }
}
