import ArtscribeKit
import Testing

@testable import ArtscribeUI

/// The `A` / `S` / `G` loop-editing policy.
///
/// `LoopRegion` is a dumb value; the decisions that matter are what happens when
/// the two edges cross, which is the case a transcriber hits constantly (set the
/// out point, then move the in point past it). A loop that silently collapses to
/// nothing there would be exactly the kind of quiet degradation spec §8 forbids —
/// the key would appear to do nothing.
@Suite("Loop editing")
struct LoopEditingTests {

    private static let total: FrameIndex = 1_000_000
    private static let existing = LoopRegion(
        range: FrameRange(start: 200_000, count: 300_000), isEnabled: true)

    // MARK: - Set in

    @Test("setting the in point before the out point moves only the in point")
    func setInBeforeOut() {
        let loop = LoopEditing.settingIn(at: 100_000, in: Self.existing, totalFrames: Self.total)
        #expect(loop.range == FrameRange(start: 100_000, count: 400_000))
        #expect(loop.isEnabled)
    }

    /// Rather than collapsing the region (which would read as "the key did
    /// nothing"), the out point is pushed to the end of the file: the loop stays
    /// real, and one more `S` press puts the out point where the user wants it.
    @Test("setting the in point past the out point pushes the out point to the end of the file")
    func setInPastOut() {
        let loop = LoopEditing.settingIn(at: 700_000, in: Self.existing, totalFrames: Self.total)
        #expect(loop.range == FrameRange(start: 700_000, count: 300_000))
        #expect(loop.isActive)
    }

    @Test("setting the in point with no loop yet runs it to the end of the file")
    func setInFromEmpty() {
        let loop = LoopEditing.settingIn(at: 400_000, in: LoopRegion(), totalFrames: Self.total)
        #expect(loop.range == FrameRange(start: 400_000, count: 600_000))
    }

    @Test("the in point is clamped into the file")
    func setInClamps() {
        let low = LoopEditing.settingIn(at: -50, in: Self.existing, totalFrames: Self.total)
        #expect(low.range.start == 0)
        let high = LoopEditing.settingIn(
            at: Self.total + 50, in: Self.existing, totalFrames: Self.total)
        #expect(high.range.start == Self.total)
        #expect(!high.isActive)
    }

    // MARK: - Set out

    @Test("setting the out point after the in point moves only the out point")
    func setOutAfterIn() {
        let loop = LoopEditing.settingOut(at: 900_000, in: Self.existing, totalFrames: Self.total)
        #expect(loop.range == FrameRange(start: 200_000, count: 700_000))
    }

    @Test("setting the out point before the in point pulls the in point back to zero")
    func setOutBeforeIn() {
        let loop = LoopEditing.settingOut(at: 100_000, in: Self.existing, totalFrames: Self.total)
        #expect(loop.range == FrameRange(start: 0, count: 100_000))
        #expect(loop.isActive)
    }

    @Test("the out point is clamped into the file")
    func setOutClamps() {
        let high = LoopEditing.settingOut(
            at: Self.total * 3, in: Self.existing, totalFrames: Self.total)
        #expect(high.range.end == Self.total)
    }

    // MARK: - From selection

    @Test("a selection becomes the loop region and keeps the enabled state")
    func fromSelection() {
        let range = FrameRange(start: 10_000, count: 40_000)
        let loop = LoopEditing.fromSelection(range, in: LoopRegion(), totalFrames: Self.total)
        #expect(loop.range == range)
        // G sets the region; D is what turns looping on. Verified here because
        // the acceptance script is literally "drag-select, then G, then D".
        #expect(!loop.isEnabled)
    }

    @Test("an empty selection leaves the loop untouched")
    func fromEmptySelection() {
        let loop = LoopEditing.fromSelection(
            FrameRange(start: 5, count: 0), in: Self.existing, totalFrames: Self.total)
        #expect(loop == Self.existing)
    }

    @Test("a selection running past the end of the file is clamped")
    func fromSelectionClamps() {
        let loop = LoopEditing.fromSelection(
            FrameRange(start: 900_000, count: Self.total), in: LoopRegion(),
            totalFrames: Self.total)
        #expect(loop.range == FrameRange(start: 900_000, count: 100_000))
    }
}
