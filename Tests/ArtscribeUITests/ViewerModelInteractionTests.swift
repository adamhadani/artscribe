import ArtscribeKit
import AudioDecode
import Testing
import Waveform

@testable import ArtscribeUI

/// Covers the drag and click state machine in `ViewerModel+Interaction`
/// directly, with no view involved: `ViewerModel` is a plain `@MainActor`
/// class, so it needs none.
///
/// This is the highest-value gap the prior implementation left untested —
/// the drag path was the one acceptance item that could not be driven end to
/// end (the machine's screen was locked, so no window could become key and
/// AppKit refused to deliver clicks). These tests exercise the same entry
/// points (`dragChanged`/`dragEnded`) the real `DragGesture` calls.
@MainActor
@Suite("ViewerModel drag and click")
struct ViewerModelInteractionTests {

    private static let totalFrames: FrameIndex = 2_000_000

    /// A model with a track "loaded" via the test-only seam, at a fixed
    /// whole-file viewport width of 1000 points. The pyramid's content is
    /// irrelevant here: none of these tests touch rendering, only the drag
    /// and click state machine.
    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: Self.totalFrames, storage: storage)
        let pyramid = PeakPyramid.build(audio)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: pyramid, widthPixels: 1000)
        return model
    }

    // MARK: - dragChanged

    @Test("a drag begins a selection at the start pixel")
    func dragBeginsAtStartPixel() {
        let model = makeModel()
        model.dragChanged(startPixel: 100, currentPixel: 100, extending: false)
        #expect(model.selection.isEmpty)

        model.dragChanged(startPixel: 100, currentPixel: 400, extending: false)
        let expected = PixelMapping.range(fromPixel: 100, toPixel: 400, in: model.viewport)
        #expect(model.selection.range == expected)
        #expect(model.playhead == PixelMapping.frame(atPixel: 100, in: model.viewport))
    }

    @Test("shift-drag extends the existing selection without moving the anchor")
    func extendingDragKeepsAnchor() {
        let model = makeModel()
        model.selection.begin(at: 500_000)
        model.selection.extend(to: 2_000_000)
        let anchorBefore = model.selection.anchor

        model.dragChanged(startPixel: 700, currentPixel: 900, extending: true)

        #expect(model.selection.anchor == anchorBefore)
        #expect(model.selection.head == PixelMapping.frame(atPixel: 900, in: model.viewport))
    }

    @Test("a plain drag (not extending) replaces the previous selection")
    func nonExtendingDragReplacesSelection() {
        let model = makeModel()
        model.selection.begin(at: 500_000)
        model.selection.extend(to: 2_000_000)

        model.dragChanged(startPixel: 700, currentPixel: 900, extending: false)

        #expect(model.selection.anchor == PixelMapping.frame(atPixel: 700, in: model.viewport))
    }

    @Test("dragChanged is a no-op with no track loaded")
    func dragChangedNoTrackIsNoOp() {
        let model = ViewerModel()
        model.dragChanged(startPixel: 100, currentPixel: 400, extending: false)
        #expect(model.selection.isEmpty)
        #expect(model.playhead == 0)
    }

    /// Regression test for the sticky `dragOrigin` fix: `dragChanged` used to
    /// decide "is this a new drag?" by checking `dragOrigin == nil`, which is
    /// only reset in `dragEnded`'s `defer`. If SwiftUI ever drops the end
    /// phase (a cancelled gesture, or another gesture winning the
    /// recognizer), the next drag would skip `selection.begin()` and
    /// silently extend the *previous* selection from a stale anchor. The fix
    /// compares against `startPixel` instead, which is stable for one drag's
    /// lifetime and therefore self-correcting regardless of whether the
    /// previous drag's end phase ever ran.
    @Test("a drag whose end phase never ran does not leak its anchor into the next drag")
    func abandonedDragDoesNotLeakAnchor() {
        let model = makeModel()

        // First drag: 100 -> 300. Its `dragEnded` is deliberately never called,
        // simulating a cancelled or superseded gesture.
        model.dragChanged(startPixel: 100, currentPixel: 100, extending: false)
        model.dragChanged(startPixel: 100, currentPixel: 300, extending: false)
        #expect(model.selection.anchor == PixelMapping.frame(atPixel: 100, in: model.viewport))

        // A second, unrelated drag starts at 700. If `dragOrigin` were still
        // stuck at 100, this would be read as a continuation and extend from
        // the old anchor instead of beginning a fresh selection at 700.
        model.dragChanged(startPixel: 700, currentPixel: 700, extending: false)
        let freshAnchor = PixelMapping.frame(atPixel: 700, in: model.viewport)
        #expect(model.selection.anchor == freshAnchor)
        #expect(model.selection.isEmpty)

        model.dragChanged(startPixel: 700, currentPixel: 900, extending: false)
        let expected = PixelMapping.range(fromPixel: 700, toPixel: 900, in: model.viewport)
        #expect(model.selection.range == expected)
    }

    // MARK: - dragEnded / click / double-click

    @Test(
        "a drag that never really moved is a click: it places the playhead and clears the selection"
    )
    func clickPlacesPlayheadAndClears() {
        let model = makeModel()
        model.selection.begin(at: 100)
        model.selection.extend(to: 900_000)

        model.dragEnded(startPixel: 300, endPixel: 300, now: 0)

        #expect(model.selection.isEmpty)
        #expect(model.playhead == PixelMapping.frame(atPixel: 300, in: model.viewport))
    }

    @Test("dragEnded past the click-slop distance leaves the drag's selection alone")
    func realDragLeavesSelectionAlone() {
        let model = makeModel()
        model.dragChanged(startPixel: 100, currentPixel: 100, extending: false)
        model.dragChanged(startPixel: 100, currentPixel: 500, extending: false)

        model.dragEnded(startPixel: 100, endPixel: 500, now: 0)

        let expected = PixelMapping.range(fromPixel: 100, toPixel: 500, in: model.viewport)
        #expect(model.selection.range == expected)
    }

    /// These tests have no audio session (`loadForTesting` leaves it nil), so
    /// `play()` cannot latch to playing — it reports "there is no audio output"
    /// instead. That notice is therefore the model-level evidence that playback
    /// was *asked for*, and nothing else in the click path raises one. The
    /// audible half is driven for real by the acceptance run.
    private func playWasRequested(_ model: ViewerModel) -> Bool {
        model.playbackNotice != nil
    }

    @Test("a single click places the playhead without starting playback")
    func singleClickDoesNotPlay() {
        let model = makeModel()
        model.dragEnded(startPixel: 300, endPixel: 300, now: 0)

        #expect(model.playhead == PixelMapping.frame(atPixel: 300, in: model.viewport))
        #expect(!playWasRequested(model))
    }

    /// Task 22 B: the gesture used to be Select All, which `⌘A` still is.
    @Test("two clicks in quick succession, close together, play from the click point")
    func doubleClickPlaysFromTheClickPoint() {
        let model = makeModel()
        model.dragEnded(startPixel: 300, endPixel: 300, now: 0)
        model.dragEnded(startPixel: 301, endPixel: 301, now: 0.1)

        #expect(model.playhead == PixelMapping.frame(atPixel: 301, in: model.viewport))
        #expect(playWasRequested(model))
        // Emphatically not the old behaviour.
        #expect(model.selection.range != FrameRange(start: 0, count: Self.totalFrames))
        #expect(model.selection.isEmpty)
    }

    /// How B composes with A. `⇧Space` (play from start) aims at the selection
    /// start, else an active loop's in point — but a double-click is an
    /// *explicit* cursor placement and must play from where the finger landed,
    /// so it must not be routed through that precedence.
    ///
    /// The selection is re-made between the two clicks because the first click
    /// clears it, exactly as `⌘A` between two clicks would: what is under test is
    /// the state `dragEnded` sees when it decides.
    @Test("a double-click plays from the click point, not the selection or loop start")
    func doubleClickIgnoresTheSelectionAndLoopStart() {
        let model = makeModel()
        model.seek(to: 200_000)
        model.setLoopIn()
        model.seek(to: 900_000)
        model.setLoopOut()
        model.toggleLoop()
        #expect(model.loop.isActive)

        model.dragEnded(startPixel: 600, endPixel: 600, now: 0)
        model.selectAll()
        #expect(!model.selection.isEmpty)
        model.dragEnded(startPixel: 600, endPixel: 600, now: 0.1)

        let clicked = PixelMapping.frame(atPixel: 600, in: model.viewport)
        #expect(clicked != model.loop.range.start)
        #expect(clicked != 0)
        #expect(model.playhead == clicked)
        #expect(playWasRequested(model))
    }

    @Test("a second click after the double-click window is a plain click, not a double-click")
    func secondClickTooLateIsNotADoubleClick() {
        let model = makeModel()
        model.dragEnded(startPixel: 300, endPixel: 300, now: 0)
        model.dragEnded(startPixel: 300, endPixel: 300, now: 1.0)

        #expect(model.selection.isEmpty)
        #expect(model.playhead == PixelMapping.frame(atPixel: 300, in: model.viewport))
        #expect(!playWasRequested(model))
    }

    @Test("a second click too far away is a plain click, not a double-click")
    func secondClickTooFarIsNotADoubleClick() {
        let model = makeModel()
        model.dragEnded(startPixel: 100, endPixel: 100, now: 0)
        model.dragEnded(startPixel: 500, endPixel: 500, now: 0.1)

        #expect(model.selection.isEmpty)
        #expect(model.playhead == PixelMapping.frame(atPixel: 500, in: model.viewport))
        #expect(!playWasRequested(model))
    }

    @Test("three clicks: the third does not chain into a second play")
    func thirdClickDoesNotChain() {
        let model = makeModel()
        model.dragEnded(startPixel: 300, endPixel: 300, now: 0)
        model.dragEnded(startPixel: 300, endPixel: 300, now: 0.1)
        #expect(playWasRequested(model))

        // The double-click consumes `lastClick`, so an immediate third click is
        // just a plain click: it places the playhead and does not play again.
        model.dismissPlaybackNotice()
        model.dragEnded(startPixel: 320, endPixel: 320, now: 0.15)
        #expect(model.playhead == PixelMapping.frame(atPixel: 320, in: model.viewport))
        #expect(!playWasRequested(model))
    }

    @Test("dragEnded is a no-op with no track loaded")
    func dragEndedNoTrackIsNoOp() {
        let model = ViewerModel()
        model.dragEnded(startPixel: 100, endPixel: 100, now: 0)
        #expect(model.playhead == 0)
        #expect(model.selection.isEmpty)
    }
}
