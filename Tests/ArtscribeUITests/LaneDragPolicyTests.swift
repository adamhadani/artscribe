import ArtscribeKit
import AudioDecode
import Testing
import Waveform

@testable import ArtscribeUI

/// Pressing down in the lanes moves the playhead with a mouse and not with a
/// finger — and a tap moves it either way.
///
/// Reported from an iPhone: reaching for a passage to select *while the track
/// was playing* moved the playhead to wherever the finger landed, interrupting
/// playback at the moment the user was trying to mark it. Reproduced on a
/// simulator by press-holding and dragging in the lanes: the selection came out
/// right and the readout had jumped to the drag's start.
@MainActor
@Suite("Pressing in the lanes")
struct LaneDragPolicyTests {

    private static let totalFrames: FrameIndex = 2_000_000

    private func makeModel(seeksOnPress: Bool) -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: Self.totalFrames, storage: storage)
        let pyramid = PeakPyramid.build(audio)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: pyramid, widthPixels: 1000)
        model.prefs.seeksOnSelectionPress = seeksOnPress
        return model
    }

    @Test("a pointer moves the playhead on press, a finger does not")
    func theRuleItself() {
        #expect(LaneDragPolicy.seeksOnPress(on: .desktop))
        #expect(!LaneDragPolicy.seeksOnPress(on: .tabletWithDrop))
        #expect(!LaneDragPolicy.seeksOnPress(on: .phone))
    }

    /// The bug, as the model sees it.
    @Test("dragging out a selection under a finger leaves the playhead alone")
    func touchDragDoesNotSeek() {
        let model = makeModel(seeksOnPress: false)
        model.seek(to: 1_500_000)

        model.dragChanged(startPixel: 100, currentPixel: 100, extending: false)
        model.dragChanged(startPixel: 100, currentPixel: 400, extending: false)

        #expect(model.playhead == 1_500_000, "the press moved the playhead to \(model.playhead)")
        #expect(
            model.selection.range
                == PixelMapping.range(fromPixel: 100, toPixel: 400, in: model.viewport),
            "and the selection has to still come out right")
    }

    /// The other half: with a pointer nothing changed. This is the behaviour
    /// every acceptance check and the whole macOS build depend on.
    @Test("dragging out a selection with a pointer still moves the playhead")
    func pointerDragStillSeeks() {
        let model = makeModel(seeksOnPress: true)
        model.seek(to: 1_500_000)

        model.dragChanged(startPixel: 100, currentPixel: 400, extending: false)

        #expect(model.playhead == PixelMapping.frame(atPixel: 100, in: model.viewport))
    }

    /// **Nothing is lost on touch — it is deferred.** A tap is a drag that went
    /// nowhere, and `dragEnded`'s click path is what seeks. If this ever stops
    /// being true, a phone has no way to place the playhead at all.
    @Test("a tap still moves the playhead under a finger")
    func tapStillSeeks() {
        let model = makeModel(seeksOnPress: false)
        model.seek(to: 1_500_000)

        model.dragChanged(startPixel: 250, currentPixel: 250, extending: false)
        model.dragEnded(startPixel: 250, endPixel: 250, now: 100)

        #expect(model.playhead == PixelMapping.frame(atPixel: 250, in: model.viewport))
        #expect(model.selection.isEmpty, "a tap clears the selection, as it always has")
    }
}
