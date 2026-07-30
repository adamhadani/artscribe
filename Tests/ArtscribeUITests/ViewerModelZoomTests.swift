import ArtscribeKit
import AudioDecode
import CoreGraphics
import Testing
import Waveform

@testable import ArtscribeUI

/// Pointer-anchored zoom at the model level: the frame under the pointer must
/// stay under the pointer, which is the whole difference between scroll-zoom
/// that feels right and scroll-zoom that feels broken.
@MainActor
@Suite("ViewerModel pointer zoom")
struct ViewerModelZoomTests {

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

    @Test("zooming with the pointer over the lanes keeps that frame under the pointer")
    func lanesAnchor() {
        let model = makeModel()
        let pointer = CGPoint(x: 250, y: 300)
        let anchored = PixelMapping.frame(atPixel: 250, in: model.viewport)

        model.zoom(by: 4, at: pointer)

        #expect(model.zoomFactor > 3.9)
        expectFrame(anchored, staysAtPixel: 250, in: model)
    }

    /// The playhead is at 0 and the pointer is far to the right, so anchoring on
    /// the wrong one is unmistakable in the result.
    @Test("the pointer anchor is used instead of the playhead")
    func pointerBeatsPlayhead() {
        let model = makeModel()
        model.seek(to: 0)
        let anchored = PixelMapping.frame(atPixel: 800, in: model.viewport)

        model.zoom(by: 8, at: CGPoint(x: 800, y: 300))

        expectFrame(anchored, staysAtPixel: 800, in: model)
        #expect(model.viewport.startFrame > 0)
    }

    /// Keyboard zoom is unchanged: `E`/`R` still anchor on the playhead.
    @Test("keyboard zoom still anchors on the playhead")
    func keyboardAnchorsOnPlayhead() {
        let model = makeModel()
        model.seek(to: Self.totalFrames / 2)
        let pixelBefore = model.viewport.pixel(forFrame: model.playhead)

        model.zoomIn()

        expectFrame(model.playhead, staysAtPixel: pixelBefore, in: model)
    }

    /// In the strip the pointer picks a frame out of the whole file, and the
    /// *main* viewport zooms toward it — the strip itself never zooms.
    @Test("zooming over the overview moves the main viewport toward that frame")
    func overviewAnchor() {
        let model = makeModel()
        let anchored = PixelMapping.overviewFrame(
            atPixel: 750, totalFrames: Self.totalFrames, width: Self.laneWidth)

        for _ in 0..<8 { model.zoom(by: 1.5, at: CGPoint(x: 750, y: 60)) }

        let visible = model.viewport.startFrame...model.viewport.endFrame
        #expect(visible.contains(anchored))
        #expect(model.zoomFactor > 1)
    }

    @Test("a zoom with the pointer over neither lane falls back to the playhead")
    func fallsBackToPlayhead() {
        let model = makeModel()
        model.seek(to: Self.totalFrames / 2)
        let pixelBefore = model.viewport.pixel(forFrame: model.playhead)

        model.zoom(by: 2, at: CGPoint(x: 640, y: 700))

        expectFrame(model.playhead, staysAtPixel: pixelBefore, in: model)
    }

    @Test("a zoom with no pointer at all falls back to the playhead")
    func noPointer() {
        let model = makeModel()
        model.seek(to: Self.totalFrames / 2)
        let pixelBefore = model.viewport.pixel(forFrame: model.playhead)

        model.zoom(by: 2, at: nil)

        expectFrame(model.playhead, staysAtPixel: pixelBefore, in: model)
    }

    @Test("pointer zoom is a no-op with no track loaded")
    func noTrack() {
        let model = ViewerModel()
        model.zoom(by: 2, at: CGPoint(x: 250, y: 300))
        #expect(model.viewport.startFrame == 0)
    }

    // MARK: - Pinch (iPad)

    /// A pinch anchors on the frame under the fingers, not on the playhead.
    ///
    /// This is the property the whole method exists for. Anchoring on the
    /// playhead — which is what plain `zoom(by:)` does, and what you get by
    /// forgetting to pass an anchor — slides the passage being pinched out from
    /// under the fingers doing the pinching.
    @Test("a pinch keeps the frame under the fingers under the fingers")
    func pinchAnchorsUnderTheFingers() {
        let model = makeModel()
        model.seek(to: 0)
        let x: CGFloat = 750
        let anchored = model.viewport.frame(atPixel: Double(x))

        model.pinchZoom(by: 2.0, atLaneX: x)
        expectFrame(anchored, staysAtPixel: Double(x), in: model)
    }

    /// Magnification above 1 is a pinch *out*, and must zoom in — fewer frames
    /// per pixel. The two conventions agree, but only by luck: `MagnifyGesture`
    /// and `Viewport.zoom(by:)` were written by different people for different
    /// reasons, and a reciprocal here would be invisible until someone pinched.
    @Test("pinching out zooms in, pinching in zooms out")
    func pinchDirection() {
        let model = makeModel()
        let start = model.framesPerPixel

        model.pinchZoom(by: 2.0, atLaneX: 500)
        #expect(model.framesPerPixel < start, "pinching out did not zoom in")

        let zoomedIn = model.framesPerPixel
        model.pinchZoom(by: 0.5, atLaneX: 500)
        #expect(model.framesPerPixel > zoomedIn, "pinching in did not zoom out")
    }

    /// A gesture that reports a nonsense scale must not corrupt the viewport.
    /// `MagnifyGesture` deltas are a division, and a division can produce these.
    @Test("a non-finite or non-positive pinch is ignored")
    func pinchRejectsNonsense() {
        let model = makeModel()
        let start = model.framesPerPixel
        for factor in [0.0, -1.0, Double.nan, Double.infinity] {
            model.pinchZoom(by: factor, atLaneX: 500)
            #expect(model.framesPerPixel == start, "factor \(factor) changed the viewport")
        }
        model.pinchZoom(by: 2.0, atLaneX: .nan)
        #expect(model.framesPerPixel == start, "a NaN anchor changed the viewport")
    }
}
