import ArtscribeKit
import AudioDecode
import Testing
import Waveform

@testable import ArtscribeUI

/// `⌘9` falling back to the loop when nothing is selected.
///
/// The key's job is "show me the bit I care about", and with a loop set and no
/// selection it used to do nothing at all.
@MainActor
@Suite("Zoom to selection or loop")
struct ViewerModelZoomTargetTests {

    private func makeModel() -> ViewerModel {
        let frames: FrameIndex = 441_000
        let storage = AudioStorage(channels: 1, capacityFrames: Int(frames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: frames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    @Test("with no selection and no loop there is nothing to zoom to")
    func nothingToZoomTo() {
        let model = makeModel()
        model.fitWholeFile()
        let before = model.framesPerPixel
        #expect(model.zoomTarget == nil)
        model.zoomToSelection()
        #expect(model.framesPerPixel == before)
    }

    /// The behaviour that was asked for.
    @Test("with a loop and no selection it zooms to the loop")
    func fallsBackToTheLoop() {
        let model = makeModel()
        model.fitWholeFile()
        let before = model.framesPerPixel
        // A loop narrow enough that zooming to it is visibly not a whole-file
        // fit, and no selection at all.
        model.applyLoop(
            LoopRegion(range: FrameRange(start: 44_100, count: 44_100), isEnabled: false))
        #expect(model.selection.isEmpty)
        #expect(model.zoomTarget == model.loop.range)
        model.zoomToSelection()
        #expect(model.framesPerPixel < before, "the view did not zoom in on the loop")
    }

    /// A loop that is merely *marked* still counts. Refusing to zoom to a region
    /// you can plainly see, because playback is not currently cycling it, is a
    /// distinction without a difference.
    @Test("a disengaged loop is still a zoom target")
    func disengagedLoopStillCounts() {
        let model = makeModel()
        model.applyLoop(
            LoopRegion(range: FrameRange(start: 1000, count: 5000), isEnabled: false))
        #expect(!model.loop.isEnabled)
        #expect(model.zoomTarget == model.loop.range)
    }

    /// The selection is the more transient of the two, so it wins: you drag one
    /// out to look at something, and a loop set ten minutes ago should not
    /// override what you just did.
    @Test("a selection beats a loop when both exist")
    func selectionWins() {
        let model = makeModel()
        model.applyLoop(
            LoopRegion(range: FrameRange(start: 200_000, count: 5000), isEnabled: true))
        model.selection.begin(at: 1000)
        model.selection.extend(to: 4000)
        #expect(model.zoomTarget == model.selection.range)
        #expect(model.zoomTarget != model.loop.range)
    }
}
