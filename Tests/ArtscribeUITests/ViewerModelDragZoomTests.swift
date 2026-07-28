import ArtscribeKit
import AudioDecode
import CoreGraphics
import Testing
import Waveform

@testable import ArtscribeUI

/// Drag-to-zoom at the model level: the vertical drag on the time ruler, and
/// the ⌥-drag in the lanes that does the same thing without taking the plain
/// left-drag away from selection.
///
/// The two things worth guarding are the *anchor* — the frame under the
/// pointer when the drag began must stay under it — and the *latch*: what a
/// drag means is decided when the mouse goes down and cannot change halfway
/// through, or a modifier pressed mid-drag would silently turn a selection
/// into a zoom.
@MainActor
@Suite("ViewerModel drag zoom")
struct ViewerModelDragZoomTests {

    private static let totalFrames: FrameIndex = 2_000_000
    private static let laneWidth: Double = 1000

    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: Self.totalFrames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(
            audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: Int(Self.laneWidth))
        model.setLaneFrame(CGRect(x: 0, y: 122, width: Self.laneWidth, height: 500))
        model.setOverviewFrame(CGRect(x: 0, y: 40, width: Self.laneWidth, height: 58))
        return model
    }

    /// One pixel of slack: the anchor round-trips through `FrameIndex`, so it
    /// can land a fraction of a pixel away at the new scale.
    private func expectFrame(
        _ frame: FrameIndex, staysAtPixel pixel: Double, in model: ViewerModel
    ) {
        let after = model.viewport.pixel(forFrame: frame)
        #expect(abs(after - pixel) <= 1, "anchor moved from \(pixel) to \(after)")
    }

    /// Walks a drag the way `DragGesture` does: one `onChanged` per point.
    private func dragRuler(in model: ViewerModel, from start: CGPoint, toY endY: Double) {
        let step = endY < start.y ? -1.0 : 1.0
        var y = start.y
        while abs(y - endY) > 0.5 {
            y += step
            model.zoomDragChanged(start: start, current: CGPoint(x: start.x, y: y))
        }
        model.zoomDragEnded()
    }

    // MARK: - A: the time ruler

    @Test("a vertical drag up the ruler zooms in, anchored where it started")
    func rulerDragZoomsIn() {
        let model = makeModel()
        let start = CGPoint(x: 250, y: 12)
        let anchored = PixelMapping.frame(atPixel: 250, in: model.viewport)

        dragRuler(in: model, from: start, toY: 12 - 2 * ZoomDrag.pointsPerDoubling)

        #expect(abs(model.zoomFactor - 4) < 0.05)
        expectFrame(anchored, staysAtPixel: 250, in: model)
    }

    @Test("a vertical drag down the ruler zooms out")
    func rulerDragZoomsOut() {
        let model = makeModel()
        model.zoom(by: 16, anchorFrame: Self.totalFrames / 2)
        let before = model.zoomFactor

        dragRuler(
            in: model, from: CGPoint(x: 500, y: 12), toY: 12 + ZoomDrag.pointsPerDoubling)

        #expect(model.zoomFactor < before)
        #expect(abs(model.zoomFactor - before / 2) < before * 0.02)
    }

    /// Horizontal travel is deliberately ignored: the gesture's contract is
    /// that the frame under the cursor stays put, and panning at the same time
    /// would move it.
    @Test("horizontal travel during a ruler drag changes nothing")
    func horizontalTravelIsIgnored() {
        let straight = makeModel()
        let diagonal = makeModel()
        let start = CGPoint(x: 250, y: 12)

        for offset in 1...120 {
            let y = 12 - Double(offset)
            straight.zoomDragChanged(start: start, current: CGPoint(x: 250, y: y))
            diagonal.zoomDragChanged(
                start: start, current: CGPoint(x: 250 + Double(offset) * 3, y: y))
        }

        #expect(straight.viewport == diagonal.viewport)
    }

    @Test("a ruler drag moves neither the playhead nor the selection")
    func rulerDragLeavesSelectionAlone() {
        let model = makeModel()
        model.laneDragChanged(
            start: CGPoint(x: 100, y: 300), current: CGPoint(x: 100, y: 300),
            option: false, shift: false)
        model.laneDragChanged(
            start: CGPoint(x: 100, y: 300), current: CGPoint(x: 400, y: 300),
            option: false, shift: false)
        model.laneDragEnded(
            start: CGPoint(x: 100, y: 300), end: CGPoint(x: 400, y: 300), now: 0)
        let selection = model.selection.range
        let playhead = model.playhead
        #expect(!selection.isEmpty)

        dragRuler(in: model, from: CGPoint(x: 700, y: 12), toY: -60)

        #expect(model.selection.range == selection)
        #expect(model.playhead == playhead)
    }

    @Test("a ruler drag with no track loaded is a no-op")
    func rulerDragNoTrack() {
        let model = ViewerModel()
        model.zoomDragChanged(start: CGPoint(x: 250, y: 12), current: CGPoint(x: 250, y: -100))
        model.zoomDragEnded()
        #expect(model.viewport.startFrame == 0)
    }

    // MARK: - B: ⌥-drag in the lanes

    @Test("an Option-drag in the lanes zooms, anchored where it started")
    func optionDragZooms() {
        let model = makeModel()
        let start = CGPoint(x: 300, y: 400)
        let anchored = PixelMapping.frame(atPixel: 300, in: model.viewport)

        for offset in 0...Int(ZoomDrag.pointsPerDoubling) {
            model.laneDragChanged(
                start: start, current: CGPoint(x: 300, y: 400 - Double(offset)),
                option: true, shift: false)
        }
        model.laneDragEnded(start: start, end: CGPoint(x: 300, y: 280), now: 0)

        #expect(abs(model.zoomFactor - 2) < 0.05)
        expectFrame(anchored, staysAtPixel: 300, in: model)
        #expect(model.selection.isEmpty)
    }

    /// The pre-existing gesture, routed through the new entry point: a plain
    /// left-drag still selects, exactly as before.
    @Test("a plain left-drag in the lanes still selects and does not zoom")
    func plainDragStillSelects() {
        let model = makeModel()
        let before = model.viewport
        let start = CGPoint(x: 200, y: 300)

        model.laneDragChanged(
            start: start, current: start, option: false, shift: false)
        model.laneDragChanged(
            start: start, current: CGPoint(x: 600, y: 120), option: false, shift: false)
        model.laneDragEnded(start: start, end: CGPoint(x: 600, y: 120), now: 0)

        #expect(model.viewport == before)
        #expect(model.selection.range.start == PixelMapping.frame(atPixel: 200, in: before))
        #expect(model.selection.range.end == PixelMapping.frame(atPixel: 600, in: before))
    }

    @Test("Shift-drag in the lanes still extends the existing selection")
    func shiftDragStillExtends() {
        let model = makeModel()
        let first = CGPoint(x: 200, y: 300)
        model.laneDragChanged(start: first, current: first, option: false, shift: false)
        model.laneDragChanged(
            start: first, current: CGPoint(x: 400, y: 300), option: false, shift: false)
        model.laneDragEnded(start: first, end: CGPoint(x: 400, y: 300), now: 0)
        let anchor = model.selection.range.start

        let second = CGPoint(x: 800, y: 300)
        model.laneDragChanged(start: second, current: second, option: false, shift: true)
        model.laneDragChanged(
            start: second, current: CGPoint(x: 900, y: 300), option: false, shift: true)
        model.laneDragEnded(start: second, end: CGPoint(x: 900, y: 300), now: 0)

        #expect(model.selection.range.start == anchor)
        #expect(model.selection.range.end == PixelMapping.frame(atPixel: 900, in: model.viewport))
    }

    // MARK: - The latch

    /// Pressing ⌥ halfway through a selection drag must not turn it into a
    /// zoom. The gesture is what it was when the mouse went down.
    @Test("Option pressed mid-drag does not convert a selection into a zoom")
    func optionMidDragDoesNotBecomeAZoom() {
        let model = makeModel()
        let before = model.viewport
        let start = CGPoint(x: 200, y: 300)

        model.laneDragChanged(start: start, current: start, option: false, shift: false)
        for offset in 1...200 {
            model.laneDragChanged(
                start: start, current: CGPoint(x: 200 + Double(offset), y: 300 - Double(offset)),
                option: true, shift: false)
        }
        model.laneDragEnded(start: start, end: CGPoint(x: 400, y: 100), now: 0)

        #expect(model.viewport == before)
        #expect(!model.selection.isEmpty)
    }

    /// And the mirror: releasing ⌥ halfway through a zoom drag must not start
    /// selecting.
    @Test("Option released mid-drag does not convert a zoom into a selection")
    func optionReleasedMidDragStaysAZoom() {
        let model = makeModel()
        let start = CGPoint(x: 300, y: 400)

        model.laneDragChanged(start: start, current: start, option: true, shift: false)
        for offset in 1...120 {
            model.laneDragChanged(
                start: start, current: CGPoint(x: 300 + Double(offset), y: 400 - Double(offset)),
                option: false, shift: false)
        }
        model.laneDragEnded(start: start, end: CGPoint(x: 420, y: 280), now: 0)

        #expect(model.selection.isEmpty)
        #expect(model.zoomFactor > 1.9)
    }

    /// An ⌥-drag that never moved is not a click: it must not seek, and it must
    /// not throw away the selection you already had.
    @Test("an Option-click does not seek or clear the selection")
    func optionClickIsNotAClick() {
        let model = makeModel()
        let first = CGPoint(x: 200, y: 300)
        model.laneDragChanged(start: first, current: first, option: false, shift: false)
        model.laneDragChanged(
            start: first, current: CGPoint(x: 600, y: 300), option: false, shift: false)
        model.laneDragEnded(start: first, end: CGPoint(x: 600, y: 300), now: 0)
        let selection = model.selection.range
        let playhead = model.playhead

        let click = CGPoint(x: 900, y: 300)
        model.laneDragChanged(start: click, current: click, option: true, shift: false)
        model.laneDragEnded(start: click, end: click, now: 0.5)

        #expect(model.selection.range == selection)
        #expect(model.playhead == playhead)
    }

    /// Two zoom drags in a row must each start from where the viewport actually
    /// is, not from where the first one began — the second drag's first event
    /// would otherwise snap the zoom back.
    @Test("a second zoom drag starts from the zoom the first one left")
    func consecutiveDragsDoNotSnapBack() {
        let model = makeModel()
        let start = CGPoint(x: 400, y: 12)

        dragRuler(in: model, from: start, toY: 12 - ZoomDrag.pointsPerDoubling)
        let afterFirst = model.zoomFactor

        // Same start point, so a gesture keyed on it alone would be mistaken
        // for a continuation of the first.
        model.zoomDragChanged(start: start, current: start)
        #expect(abs(model.zoomFactor - afterFirst) < 0.01)

        dragRuler(in: model, from: start, toY: 12 - ZoomDrag.pointsPerDoubling)
        #expect(abs(model.zoomFactor - afterFirst * 2) < afterFirst * 0.05)
    }

    @Test("a lane drag with no track loaded is a no-op")
    func laneDragNoTrack() {
        let model = ViewerModel()
        model.laneDragChanged(
            start: CGPoint(x: 200, y: 300), current: CGPoint(x: 200, y: 100),
            option: true, shift: false)
        model.laneDragEnded(
            start: CGPoint(x: 200, y: 300), end: CGPoint(x: 200, y: 100), now: 0)
        #expect(model.viewport.startFrame == 0)
        #expect(model.selection.isEmpty)
    }
}
