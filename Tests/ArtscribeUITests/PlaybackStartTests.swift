import ArtscribeKit
import AudioDecode
import Testing
import Waveform

@testable import ArtscribeUI

/// The one precedence rule behind `⇧Space`, exhaustively.
///
/// It exists because the app used to appear to follow two rules: the UI aimed at
/// the track start with no selection, and `PlaybackEngine`'s loop containment
/// then pulled the cursor into the loop region, so what the user got depended on
/// where the loop happened to sit. See `PlaybackStart`.
@Suite("Play-from-start precedence")
struct PlaybackStartTests {

    private static let loop = LoopRegion(
        range: FrameRange(start: 120_000, count: 140_000), isEnabled: true)
    private static let selection = Selection(anchor: 300_000, head: 340_000)

    // MARK: - The four combinations

    @Test("neither a selection nor a loop: the start of the track")
    func neither() {
        #expect(PlaybackStart.target(selection: Selection(), loop: LoopRegion()) == 0)
    }

    @Test("a selection and no loop: the selection start")
    func selectionOnly() {
        #expect(
            PlaybackStart.target(selection: Self.selection, loop: LoopRegion()) == 300_000)
    }

    @Test("an active loop and no selection: the loop's in point, not the track start")
    func loopOnly() {
        #expect(PlaybackStart.target(selection: Selection(), loop: Self.loop) == 120_000)
    }

    @Test("both: the selection wins")
    func bothSelectionWins() {
        #expect(PlaybackStart.target(selection: Self.selection, loop: Self.loop) == 300_000)
    }

    /// A backwards drag selects the same passage, and `⇧Space` must still land on
    /// its earlier edge rather than on the anchor the hand happened to start at.
    @Test("a backwards selection still starts at its earlier edge")
    func backwardsSelection() {
        let backwards = Selection(anchor: 340_000, head: 300_000)
        #expect(PlaybackStart.target(selection: backwards, loop: Self.loop) == 300_000)
    }

    // MARK: - Which loops count

    @Test("a loop the user switched off does not steer the playhead")
    func disabledLoopIsIgnored() {
        var disabled = Self.loop
        disabled.isEnabled = false
        #expect(PlaybackStart.target(selection: Selection(), loop: disabled) == 0)
    }

    /// `A` pressed once with no `S` yet, on a region that collapsed to nothing:
    /// enabled but empty. `isEnabled` alone would aim at a stale in point that
    /// the engine itself does not loop on.
    @Test("an enabled but zero-length loop does not steer the playhead either")
    func emptyLoopIsIgnored() {
        let empty = LoopRegion(range: FrameRange(start: 120_000, count: 0), isEnabled: true)
        #expect(!empty.isActive)
        #expect(PlaybackStart.target(selection: Selection(), loop: empty) == 0)
    }

    /// The engine confines playback to an active loop, so a selection outside one
    /// is the single case where the aim point and what is audible can still
    /// differ. The rule is unchanged — a selection outranks the loop at the aim
    /// point — and that is what keeps it one rule rather than two.
    @Test("a selection outside an active loop is still the aim point")
    func selectionOutsideTheLoop() {
        let before = Selection(anchor: 10_000, head: 40_000)
        #expect(PlaybackStart.target(selection: before, loop: Self.loop) == 10_000)
    }
}

/// The same rule as the keyboard and the menu reach it: through `ViewerModel`.
///
/// `loadForTesting` leaves the playback session nil, so nothing is audible here
/// and nothing needs to be — what is under test is the frame the model seeks to.
@MainActor
@Suite("Play-from-start through the model")
struct ViewerModelStartPrecedenceTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: Self.totalFrames,
            storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    // MARK: - ⇧Space precedence (Task 22 A)
    //
    // One rule, four states. `loop only` is the one that was measurably wrong at
    // this level: the old `seek(to: selection.isEmpty ? 0 : …)` aimed at the
    // track start and left `PlaybackEngine`'s loop containment to drag the cursor
    // into the region afterwards, which is what made the app read as two
    // competing rules. See `PlaybackStart`.

    /// A selection, so the loop cannot be what put the playhead there.
    private func select(_ model: ViewerModel, fromPixel: Double, toPixel: Double) -> FrameIndex {
        model.dragChanged(startPixel: fromPixel, currentPixel: fromPixel, extending: false)
        model.dragChanged(startPixel: fromPixel, currentPixel: toPixel, extending: false)
        return model.selection.range.start
    }

    private func enableLoop(_ model: ViewerModel, from start: FrameIndex, to end: FrameIndex) {
        model.seek(to: start)
        model.setLoopIn()
        model.seek(to: end)
        model.setLoopOut()
        if !model.loop.isEnabled { model.toggleLoop() }
    }

    @Test("Shift-Space with neither a selection nor a loop goes to the track start")
    func returnToStartWithNeither() {
        let model = makeModel()
        model.seek(to: 300_000)
        model.returnToStart()
        #expect(model.playhead == 0)
    }

    @Test("Shift-Space with a selection and no loop goes to the selection start")
    func returnToStartWithSelectionOnly() {
        let model = makeModel()
        let start = select(model, fromPixel: 200, toPixel: 500)
        model.seek(to: 300_000)
        model.returnToStart()
        #expect(model.playhead == start)
    }

    @Test("Shift-Space with an active loop and no selection goes to the loop start")
    func returnToStartWithLoopOnly() {
        let model = makeModel()
        enableLoop(model, from: 120_000, to: 260_000)
        model.clearSelection()
        #expect(model.loop.isActive)

        model.seek(to: 300_000)
        model.returnToStart()
        #expect(model.playhead == 120_000)
    }

    /// A selection outranks the loop, so the aim point is the selection start and
    /// nothing has to be corrected downstream. The selection here sits *inside*
    /// the loop, which is the ordinary case (`G` makes a loop out of one) and the
    /// case where the fix is also audible: the engine leaves a cursor inside the
    /// region alone.
    @Test("Shift-Space with both a selection and an active loop goes to the selection start")
    func returnToStartWithBoth() {
        let model = makeModel()
        enableLoop(model, from: 120_000, to: 260_000)
        let start = select(model, fromPixel: 400, toPixel: 600)
        #expect(model.loop.isActive)
        #expect(start != 120_000)

        model.seek(to: 300_000)
        model.returnToStart()
        #expect(model.playhead == start)
    }

    /// `isActive`, not `isEnabled`: a loop the user switched off must not steer
    /// the playhead, and neither must a zero-length one left over from a single
    /// press of `A`.
    @Test("a disabled loop does not steer Shift-Space")
    func returnToStartIgnoresADisabledLoop() {
        let model = makeModel()
        enableLoop(model, from: 120_000, to: 260_000)
        model.toggleLoop()
        model.clearSelection()
        #expect(!model.loop.isActive)
        #expect(model.loop.range.start == 120_000)

        model.seek(to: 300_000)
        model.returnToStart()
        #expect(model.playhead == 0)
    }

    @Test("play from start follows the same precedence as return to start")
    func playFromStartFollowsThePrecedence() {
        let model = makeModel()
        enableLoop(model, from: 120_000, to: 260_000)
        model.clearSelection()
        model.seek(to: 300_000)

        // No audio session in these tests, so this reports rather than plays —
        // the seek half is what is under test.
        model.playFromStart()
        #expect(model.playhead == 120_000)
    }
}
