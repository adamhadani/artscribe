import ArtscribeKit
import Dispatch
import Foundation
import Testing

@testable import Playback

@Test func popOnEmptyRingReturnsNil() {
    let ring = CommandRing(capacity: 8)
    #expect(ring.pop() == nil)
}

@Test func preservesFIFOOrder() {
    let ring = CommandRing(capacity: 8)
    #expect(ring.push(.seek(100)))
    #expect(ring.push(.setTimeRatio(2.0)))
    #expect(ring.push(.setPlaying(true)))

    #expect(ring.pop() == .seek(100))
    #expect(ring.pop() == .setTimeRatio(2.0))
    #expect(ring.pop() == .setPlaying(true))
    #expect(ring.pop() == nil)
}

@Test func rejectsPushWhenFull() {
    let ring = CommandRing(capacity: 4)  // usable slots = capacity - 1
    #expect(ring.push(.seek(1)))
    #expect(ring.push(.seek(2)))
    #expect(ring.push(.seek(3)))
    #expect(!ring.push(.seek(4)))  // full
}

@Test func wrapsAroundCorrectly() {
    let ring = CommandRing(capacity: 4)
    for round in 0..<20 {
        #expect(ring.push(.seek(FrameIndex(round))))
        #expect(ring.pop() == .seek(FrameIndex(round)))
    }
    #expect(ring.pop() == nil)
}

@Test func carriesLoopPayload() {
    let ring = CommandRing(capacity: 4)
    let range = FrameRange(start: 500, count: 1000)
    #expect(ring.push(.setLoop(range, true)))
    #expect(ring.pop() == .setLoop(range, true))
}

/// Collects the consumer's outcome across threads. Written only by the consumer thread,
/// read only after `consumerDone` has been signalled, so the semaphore's signal/wait pair
/// (a release/acquire synchronization point) is what makes this safe, not any locking here.
private final class ConsumerOutcome: @unchecked Sendable {
    var receivedCount = 0
    var orderPreserved = true
}

/// Exercises the SPSC ring under real concurrent producer/consumer pressure.
///
/// This deliberately uses real OS `Thread`s rather than `async let` / structured
/// concurrency. Both sides busy-spin (the producer retries on a full ring; the consumer
/// retries on an empty one) without ever suspending. Swift's cooperative thread pool backing
/// `async`/`await` has a bounded number of worker threads (tied to core count), and a
/// non-suspending child task occupies one of those workers for its entire lifetime. Two
/// such spinning tasks racing for a small, fixed pool risk starving each other -- the
/// producer can fill the ring and never be preempted in favor of the consumer, deadlocking
/// the test. Real `Thread`s are preemptively scheduled by the OS kernel, not the cooperative
/// pool, so they don't have this failure mode; this also better models the real deployment,
/// where producer (main actor) and consumer (CoreAudio render callback) are genuinely
/// separate OS threads. A hard wall-clock timeout is still asserted so that a real
/// regression (e.g. a broken ordering that drops a push) fails loudly rather than hanging
/// the test suite forever.
@Test func survivesConcurrentProducerAndConsumer() {
    let ring = CommandRing(capacity: 1024)
    let total = 50_000

    let producerDone = DispatchSemaphore(value: 0)
    let consumerDone = DispatchSemaphore(value: 0)
    let outcome = ConsumerOutcome()

    let producer = Thread {
        var sent = 0
        while sent < total {
            if ring.push(.seek(FrameIndex(sent))) {
                sent += 1
            }
        }
        producerDone.signal()
    }
    producer.start()

    let consumer = Thread {
        var received = 0
        var expected: FrameIndex = 0
        while received < total {
            if case .seek(let v)? = ring.pop() {
                // FIFO must hold exactly, with no drops or reordering.
                if v != expected {
                    outcome.orderPreserved = false
                    break
                }
                expected += 1
                received += 1
            }
        }
        outcome.receivedCount = received
        consumerDone.signal()
    }
    consumer.start()

    let deadline = DispatchTime.now() + .seconds(10)
    let producerFinished = producerDone.wait(timeout: deadline) == .success
    let consumerFinished = consumerDone.wait(timeout: deadline) == .success

    #expect(producerFinished, "producer did not finish within the timeout -- possible hang")
    #expect(consumerFinished, "consumer did not finish within the timeout -- possible hang")
    #expect(outcome.orderPreserved)
    #expect(outcome.receivedCount == total)
}
