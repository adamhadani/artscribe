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
}
