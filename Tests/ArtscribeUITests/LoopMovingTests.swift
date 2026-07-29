import ArtscribeKit
import Testing

@testable import ArtscribeUI

/// Moving the loop's edges and its body by keyboard — spec §6.2's `loop.move`
/// actions.
///
/// The whole point of this type is that it is the *same* arithmetic the mouse
/// uses: `TimelineHandles.resized` and `.moved`, which Task 23 wrote for the
/// drag. So the keyboard and the mouse cannot disagree about inversion or about
/// clamping, and a user who learns one can predict the other. The tests below
/// therefore check both the behaviour and, explicitly, the agreement.
@Suite("Loop movement")
struct LoopMovingTests {

    private static let sampleRate: Double = 44100
    /// 60 s.
    private static let totalFrames = FrameIndex(60 * 44100)

    private func frames(_ seconds: Double) -> FrameIndex {
        FrameIndex((seconds * Self.sampleRate).rounded())
    }

    /// 20 s → 25 s, enabled.
    private func loop(
        from: Double = 20, to: Double = 25, enabled: Bool = true
    ) -> LoopRegion {
        LoopRegion(
            range: FrameRange(start: frames(from), count: frames(to) - frames(from)),
            isEnabled: enabled)
    }

    private func move(
        _ region: LoopRegion, _ target: LoopMoveTarget, _ seconds: Double,
        totalFrames: FrameIndex = LoopMovingTests.totalFrames
    ) -> LoopRegion {
        LoopMoving.moved(
            region, target: target, bySeconds: seconds,
            sampleRate: Self.sampleRate, totalFrames: totalFrames)
    }

    // MARK: - Each edge moves, and only that edge

    @Test("the in point moves either way and leaves the out point exactly put")
    func inPointMovesAlone() {
        let start = loop()
        let back = move(start, .inPoint, -1)
        #expect(back.range.start == frames(19))
        #expect(back.range.end == start.range.end)

        let forward = move(start, .inPoint, 1)
        #expect(forward.range.start == frames(21))
        #expect(forward.range.end == start.range.end)
    }

    @Test("the out point moves either way and leaves the in point exactly put")
    func outPointMovesAlone() {
        let start = loop()
        let back = move(start, .outPoint, -1)
        #expect(back.range.end == frames(24))
        #expect(back.range.start == start.range.start)

        let forward = move(start, .outPoint, 1)
        #expect(forward.range.end == frames(26))
        #expect(forward.range.start == start.range.start)
    }

    @Test("the whole loop moves either way with its length preserved exactly")
    func wholeLoopKeepsItsLength() {
        let start = loop()
        for seconds in [-3.0, 3.0, -0.25, 0.25] {
            let moved = move(start, .whole, seconds)
            #expect(moved.range.count == start.range.count, "by \(seconds) s")
            #expect(moved.range.start == start.range.start + frames(seconds), "by \(seconds) s")
        }
    }

    // MARK: - Inversion: swap, matching the drag

    /// Task 23 chose swap-on-crossing for dragging an edge, structurally, via
    /// `TimelineHandles.resized`'s `min`/`max`. The keyboard calls the same
    /// function, so it cannot drift.
    @Test("pushing the in point past the out point swaps rather than inverting")
    func inPointSwaps() {
        let moved = move(loop(), .inPoint, 8)  // 20 s + 8 s = 28 s, past the 25 s out point
        #expect(moved.range.start == frames(25))
        #expect(moved.range.end == frames(28))
        #expect(moved.range.count > 0)
    }

    @Test("pulling the out point past the in point swaps rather than inverting")
    func outPointSwaps() {
        let moved = move(loop(), .outPoint, -8)  // 25 s − 8 s = 17 s, before the 20 s in point
        #expect(moved.range.start == frames(17))
        #expect(moved.range.end == frames(20))
        #expect(moved.range.count > 0)
    }

    /// The agreement itself, asserted rather than assumed: the region a keyboard
    /// move produces is the region the equivalent drag produces.
    @Test("the keyboard and the mouse produce the same region when an edge crosses")
    func keyboardAgreesWithTheDrag() {
        let start = loop()
        let byKeyboard = move(start, .inPoint, 8)
        let byMouse = TimelineHandles.resized(
            anchor: start.range.end, to: start.range.start + frames(8),
            totalFrames: Self.totalFrames)
        #expect(byKeyboard.range == byMouse)

        let outByKeyboard = move(start, .outPoint, -8)
        let outByMouse = TimelineHandles.resized(
            anchor: start.range.start, to: start.range.end - frames(8),
            totalFrames: Self.totalFrames)
        #expect(outByKeyboard.range == outByMouse)
    }

    /// The one degenerate landing: a step that exactly equals the loop's length
    /// leaves the two edges coincident. It is the same instant a drag passes
    /// through, and `LoopRegion.isActive` already treats an empty region as not
    /// looping, so nothing downstream needs to know — but by keyboard it is a
    /// *resting* state rather than a passing one, which is worth pinning.
    @Test("a step exactly equal to the loop's length collapses it, as the drag does")
    func exactCrossingCollapses() {
        let five = loop(from: 20, to: 25)
        let collapsed = move(five, .inPoint, 5)
        #expect(collapsed.range.count == 0)
        #expect(collapsed.range.start == frames(25))
        #expect(
            collapsed.range
                == TimelineHandles.resized(
                    anchor: five.range.end, to: five.range.start + frames(5),
                    totalFrames: Self.totalFrames))
    }

    // MARK: - Clamping at both file bounds

    @Test("the in point stops at the start of the file")
    func inPointClampsAtZero() {
        let moved = move(loop(from: 1, to: 5), .inPoint, -30)
        #expect(moved.range.start == 0)
        #expect(moved.range.end == frames(5))
    }

    @Test("the out point stops at the end of the file")
    func outPointClampsAtTheEnd() {
        let moved = move(loop(from: 50, to: 55), .outPoint, 30)
        #expect(moved.range.end == Self.totalFrames)
        #expect(moved.range.start == frames(50))
    }

    /// Clamped as a whole, so a loop pushed against an end keeps its length
    /// instead of shrinking against the wall — `TimelineHandles.moved`'s rule.
    @Test("the whole loop stops at either bound with its length intact")
    func wholeLoopClampsAtBothBounds() {
        let length = loop().range.count
        let atStart = move(loop(), .whole, -100)
        #expect(atStart.range.start == 0)
        #expect(atStart.range.count == length)

        let atEnd = move(loop(), .whole, 100)
        #expect(atEnd.range.end == Self.totalFrames)
        #expect(atEnd.range.count == length)
    }

    /// A region longer than the file — which nothing in the app can make, but a
    /// hand-edited sidecar can — has no legal position and is clamped to the file.
    @Test("a region longer than the file is clamped to the file")
    func oversizedRegion() {
        let huge = LoopRegion(
            range: FrameRange(start: 0, count: Self.totalFrames * 2), isEnabled: true)
        let moved = move(huge, .whole, 5)
        #expect(moved.range.start == 0)
        #expect(moved.range.end == Self.totalFrames)
    }

    // MARK: - The things that must not change

    @Test("whether the loop is switched on is never changed by moving it")
    func enablementIsPreserved() {
        for enabled in [true, false] {
            for target in LoopMoveTarget.allCases {
                let moved = move(loop(enabled: enabled), target, 1)
                #expect(moved.isEnabled == enabled, "\(target) enabled=\(enabled)")
            }
        }
    }

    /// `A` pressed once with no `S` yet: an empty region has no edges to move,
    /// and inventing a length here would be the key doing something the user did
    /// not ask for.
    @Test("an empty loop is left exactly alone")
    func emptyLoopIsUntouched() {
        let empty = LoopRegion(range: FrameRange(start: frames(10), count: 0), isEnabled: true)
        for target in LoopMoveTarget.allCases {
            #expect(move(empty, target, 2) == empty, "\(target)")
        }
    }

    /// Nothing loaded, or a corrupted rate: no answer is possible, so nothing
    /// moves rather than moving to nowhere.
    @Test("an unusable sample rate or an empty file moves nothing")
    func unusableInputsAreNoOps() {
        let start = loop()
        for target in LoopMoveTarget.allCases {
            #expect(
                LoopMoving.moved(
                    start, target: target, bySeconds: 1, sampleRate: 0,
                    totalFrames: Self.totalFrames) == start, "\(target) rate 0")
            #expect(
                LoopMoving.moved(
                    start, target: target, bySeconds: .nan, sampleRate: Self.sampleRate,
                    totalFrames: Self.totalFrames) == start, "\(target) NaN")
            #expect(
                LoopMoving.moved(
                    start, target: target, bySeconds: 1, sampleRate: Self.sampleRate,
                    totalFrames: 0) == start, "\(target) empty file")
        }
    }

    /// A corrupted preference cannot be turned into a trap: `NudgeStepping`
    /// saturates rather than overflowing, and the clamp makes the result
    /// indistinguishable from any other out-of-range one.
    @Test("an absurd amount saturates instead of overflowing")
    func absurdAmountsSaturate() {
        for target in LoopMoveTarget.allCases {
            let far = move(loop(), target, 1e18)
            #expect(far.range.start >= 0, "\(target)")
            #expect(far.range.end <= Self.totalFrames, "\(target)")
            let back = move(loop(), target, -1e18)
            #expect(back.range.start >= 0, "\(target)")
            #expect(back.range.end <= Self.totalFrames, "\(target)")
        }
    }
}
