import ArtscribeKit
import AudioDecode
import CoreGraphics
import Testing
import Waveform

@testable import ArtscribeUI

/// Task 23 at the model level: the loop and selection edges dragged through the
/// same door the real `DragGesture` uses, `laneDragChanged`/`laneDragEnded`.
///
/// The half worth guarding hardest is not that an edge moves — it is that
/// **nothing else stopped working**. The lanes now carry an eighth gesture, and
/// every test below that ends in "still selects", "still zooms" or "still
/// extends" is there because that is where this task fails if it fails.
@MainActor
@Suite("ViewerModel edge drag")
struct ViewerModelEdgeDragTests {

    /// 2 000 000 frames across 1000 points: 2000 frames per point, so every
    /// expectation can be written in whole points.
    private static let totalFrames: FrameIndex = 2_000_000
    private static let framesPerPoint: FrameIndex = 2000
    private static let laneHeight: Double = 300

    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: Self.totalFrames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        // The lanes' height decides where the loop's top and bottom bars are,
        // so a body drag cannot be tested without it.
        model.laneSize = CGSize(width: 1000, height: Self.laneHeight)
        return model
    }

    private func frame(_ point: Double) -> FrameIndex {
        FrameIndex(point) * Self.framesPerPoint
    }

    /// A loop from 200 pt to 600 pt, enabled.
    private func withLoop(_ model: ViewerModel) {
        model.loop = LoopRegion(
            range: FrameRange(start: frame(200), count: frame(400)), isEnabled: true)
    }

    /// A selection from 700 pt to 900 pt, clear of the loop above.
    private func withSelection(_ model: ViewerModel) {
        model.selection = Selection(anchor: frame(700), head: frame(900))
    }

    /// One gesture, walked the way `DragGesture` walks it: an `onChanged` per
    /// step with a stable `startLocation`, then an `onEnded`.
    private func drag(
        _ model: ViewerModel,
        from start: CGPoint,
        toX endX: Double,
        option: Bool = false,
        shift: Bool = false,
        now: Double = 0
    ) {
        model.laneDragChanged(start: start, current: start, option: option, shift: shift)
        for step in 1...8 {
            let x = start.x + (endX - start.x) * Double(step) / 8
            model.laneDragChanged(
                start: start, current: CGPoint(x: x, y: start.y), option: option, shift: shift)
        }
        model.laneDragEnded(start: start, end: CGPoint(x: endX, y: start.y), now: now)
    }

    private var midLane: Double { Self.laneHeight / 2 }

    // MARK: - Loop edges

    @Test("dragging the loop's in point moves it and leaves the out point alone")
    func loopInPointFollowsTheDrag() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 200, y: midLane), toX: 300)
        #expect(model.loop.range == FrameRange(start: frame(300), count: frame(300)))
        #expect(model.loop.isEnabled)
    }

    @Test("dragging the loop's out point moves it and leaves the in point alone")
    func loopOutPointFollowsTheDrag() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 600, y: midLane), toX: 750)
        #expect(model.loop.range == FrameRange(start: frame(200), count: frame(550)))
    }

    /// The inversion decision, driven end to end: the drag carries on past the
    /// other edge and the region reappears on the far side, never inverted and
    /// never stuck at zero length.
    @Test("dragging the in point past the out point swaps rather than collapsing")
    func loopEdgesSwap() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 200, y: midLane), toX: 800)
        #expect(model.loop.range == FrameRange(start: frame(600), count: frame(200)))
        #expect(model.loop.range.count > 0)
    }

    @Test("a loop edge dragged off the end of the file stops at the file")
    func loopEdgeClampsAtTheFile() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 600, y: midLane), toX: 4000)
        #expect(
            model.loop.range == FrameRange(start: frame(200), count: Self.totalFrames - frame(200)))
    }

    /// Grabbing an edge is not clicking on the waveform: it must not seek, must
    /// not clear the selection, and must not chain into a double-click.
    @Test("a loop edge drag leaves the playhead and the selection alone")
    func loopEdgeDragTouchesNothingElse() {
        let model = makeModel()
        withLoop(model)
        withSelection(model)
        model.seek(to: frame(50))
        let selectionBefore = model.selection
        drag(model, from: CGPoint(x: 200, y: midLane), toX: 300)
        #expect(model.playhead == frame(50))
        #expect(model.selection == selectionBefore)
    }

    @Test("two edge grabs in quick succession are not a double-click")
    func edgeGrabsDoNotPlay() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 200, y: midLane), toX: 200, now: 0)
        drag(model, from: CGPoint(x: 200, y: midLane), toX: 200, now: 0.1)
        // With no audio session, an attempt to play raises this notice and
        // nothing else in the drag path does — see `ViewerModelInteractionTests`.
        #expect(model.playbackNotice == nil)
        #expect(model.playhead == 0)
    }

    // MARK: - The loop body

    @Test("dragging the loop's top bar moves the whole loop, preserving its length")
    func loopBodyMoves() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 400, y: 2), toX: 500)
        #expect(model.loop.range == FrameRange(start: frame(300), count: frame(400)))
    }

    @Test("the loop's bottom bar moves it too")
    func loopBottomBarMoves() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 400, y: Self.laneHeight - 2), toX: 300)
        #expect(model.loop.range == FrameRange(start: frame(100), count: frame(400)))
    }

    @Test("a loop pushed against the end of the file keeps its length")
    func loopBodyClampsWithLengthIntact() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 400, y: 2), toX: 4000)
        #expect(model.loop.range.count == frame(400))
        #expect(model.loop.range.end == Self.totalFrames)
    }

    // MARK: - Selection edges

    @Test("dragging a selection edge moves that edge only")
    func selectionEdgeFollowsTheDrag() {
        let model = makeModel()
        withSelection(model)
        drag(model, from: CGPoint(x: 700, y: midLane), toX: 600)
        #expect(model.selection.range == FrameRange(start: frame(600), count: frame(300)))
        drag(model, from: CGPoint(x: 900, y: midLane), toX: 950)
        #expect(model.selection.range == FrameRange(start: frame(600), count: frame(350)))
    }

    @Test("a selection edge dragged past the other swaps rather than collapsing")
    func selectionEdgesSwap() {
        let model = makeModel()
        withSelection(model)
        drag(model, from: CGPoint(x: 700, y: midLane), toX: 950)
        #expect(model.selection.range == FrameRange(start: frame(900), count: frame(50)))
    }

    @Test("a selection edge drag does not move the playhead")
    func selectionEdgeDragLeavesThePlayhead() {
        let model = makeModel()
        withSelection(model)
        model.seek(to: frame(50))
        drag(model, from: CGPoint(x: 700, y: midLane), toX: 600)
        #expect(model.playhead == frame(50))
    }

    /// `G` puts the loop exactly on top of the selection. The loop's edge wins,
    /// so this drag has to move the loop and leave the selection where it was.
    @Test("with the loop on top of the selection, the drag takes the loop")
    func loopWinsWhenTheyCoincide() {
        let model = makeModel()
        withSelection(model)
        model.loopFromSelection()
        let selectionBefore = model.selection
        drag(model, from: CGPoint(x: 700, y: midLane), toX: 600)
        #expect(model.loop.range == FrameRange(start: frame(600), count: frame(300)))
        #expect(model.selection == selectionBefore)
    }

    // MARK: - Everything that was already there

    @Test("a plain drag through the middle of the loop still selects")
    func plainDragInsideTheLoopStillSelects() {
        let model = makeModel()
        withLoop(model)
        drag(model, from: CGPoint(x: 300, y: midLane), toX: 500)
        #expect(model.selection.range == FrameRange(start: frame(300), count: frame(200)))
        #expect(model.loop.range == FrameRange(start: frame(200), count: frame(400)))
    }

    /// The escape hatch, and the reason a modifier outranks a handle: ⌥ on top
    /// of a loop edge is still a zoom.
    @Test("an Option-drag starting on a loop edge still zooms and moves no edge")
    func optionOnAnEdgeStillZooms() {
        let model = makeModel()
        withLoop(model)
        let before = model.zoomFactor
        model.laneDragChanged(
            start: CGPoint(x: 200, y: midLane), current: CGPoint(x: 200, y: midLane),
            option: true, shift: false)
        model.laneDragChanged(
            start: CGPoint(x: 200, y: midLane),
            current: CGPoint(x: 200, y: midLane + ViewerModel.zoomDragPointsPerDoubling),
            option: true, shift: false)
        model.laneDragEnded(
            start: CGPoint(x: 200, y: midLane),
            end: CGPoint(x: 200, y: midLane + ViewerModel.zoomDragPointsPerDoubling), now: 0)
        #expect(model.zoomFactor > before * 1.5)
        #expect(model.loop.range == FrameRange(start: frame(200), count: frame(400)))
    }

    /// And ⇧ on top of a selection edge still extends from the existing anchor,
    /// which is what keeps a selection edge reachable even when a loop edge is
    /// sitting exactly on it.
    @Test("a Shift-drag starting on a selection edge still extends the selection")
    func shiftOnAnEdgeStillExtends() {
        let model = makeModel()
        withSelection(model)
        let anchorBefore = model.selection.anchor
        drag(model, from: CGPoint(x: 700, y: midLane), toX: 950, shift: true)
        #expect(model.selection.anchor == anchorBefore)
        #expect(model.selection.head == frame(950))
    }

    @Test("a click well away from any edge still places the playhead and clears the selection")
    func plainClickStillWorks() {
        let model = makeModel()
        withLoop(model)
        withSelection(model)
        drag(model, from: CGPoint(x: 400, y: midLane), toX: 400)
        #expect(model.playhead == frame(400))
        #expect(model.selection.isEmpty)
    }

    // MARK: - The live readout

    @Test("the drag publishes the moving edge's frame, and clears when the gesture ends")
    func theReadoutFollowsTheDraggedEdge() {
        let model = makeModel()
        withLoop(model)
        let start = CGPoint(x: 200, y: midLane)
        model.laneDragChanged(start: start, current: start, option: false, shift: false)
        #expect(model.edgeDrag?.handle == .loopStart)
        model.laneDragChanged(
            start: start, current: CGPoint(x: 350, y: midLane), option: false, shift: false)
        #expect(model.edgeDrag?.currentFrame == frame(350))
        #expect(model.edgeDrag?.side == .leading)
        // Past the out point: the guide is now the region's trailing edge, and
        // the cursor and the wash have to follow it there.
        model.laneDragChanged(
            start: start, current: CGPoint(x: 800, y: midLane), option: false, shift: false)
        #expect(model.edgeDrag?.side == .trailing)
        model.laneDragEnded(start: start, end: CGPoint(x: 800, y: midLane), now: 0)
        #expect(model.edgeDrag == nil)
    }

    @Test("a body drag reports the region's start, so the readout says where it lands")
    func theReadoutFollowsABodyDrag() {
        let model = makeModel()
        withLoop(model)
        let start = CGPoint(x: 400, y: 2)
        model.laneDragChanged(start: start, current: start, option: false, shift: false)
        model.laneDragChanged(
            start: start, current: CGPoint(x: 500, y: 2), option: false, shift: false)
        #expect(model.edgeDrag?.handle == .loopBody)
        #expect(model.edgeDrag?.currentFrame == frame(300))
    }

    // MARK: - Hover

    @Test("the hover hit test answers for the lanes' real height")
    func hoverHitTestUsesTheLaneHeight() {
        let model = makeModel()
        withLoop(model)
        #expect(model.timelineHandle(at: CGPoint(x: 200, y: midLane)) == .loopStart)
        #expect(model.timelineHandle(at: CGPoint(x: 400, y: 2)) == .loopBody)
        #expect(model.timelineHandle(at: CGPoint(x: 400, y: midLane)) == nil)
    }

    @Test("nothing is grabbable with no track loaded")
    func noTrackOffersNoHandle() {
        let model = ViewerModel()
        #expect(model.timelineHandle(at: CGPoint(x: 200, y: 10)) == nil)
        model.laneDragChanged(
            start: CGPoint(x: 200, y: 10), current: CGPoint(x: 300, y: 10), option: false,
            shift: false)
        #expect(model.edgeDrag == nil)
        #expect(model.loop.range.isEmpty)
    }
}
