import ArtscribeKit
import AudioDecode
import Testing
import Waveform

@testable import ArtscribeUI

/// The overview strip as a scrubber: dragging along it must move the main
/// viewport continuously, not once.
@MainActor
@Suite("Overview strip scrubbing")
struct OverviewScrubTests {

    private static let totalFrames: FrameIndex = 2_000_000
    private static let stripWidth: Double = 400

    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: Self.totalFrames, storage: storage)
        let pyramid = PeakPyramid.build(audio)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: pyramid, widthPixels: 1000)
        // Zoomed in, or there is nowhere to scrub to: a fitted viewport already
        // shows the whole file and every centre request clamps to the same place.
        model.zoom(by: 8, anchorFrame: 0)
        return model
    }

    private func scrub(_ model: ViewerModel, toPixel x: Double) {
        model.centre(
            on: PixelMapping.overviewFrame(
                atPixel: x, totalFrames: model.totalFrames, width: Self.stripWidth))
    }

    @Test("dragging along the strip moves the viewport at every step")
    func everyStepMoves() {
        let model = makeModel()
        var previous = model.viewport.startFrame
        var moves = 0
        for step in 1...20 {
            scrub(model, toPixel: 40 + Double(step) * 15)
            if model.viewport.startFrame != previous { moves += 1 }
            previous = model.viewport.startFrame
        }
        #expect(moves == 20, "only \(moves) of 20 drag events moved the view")
    }

    @Test("the strip follows the finger rather than jumping to one end")
    func followsTheFinger() {
        let model = makeModel()
        scrub(model, toPixel: Self.stripWidth * 0.25)
        let quarter = model.viewport.startFrame
        scrub(model, toPixel: Self.stripWidth * 0.75)
        let threeQuarters = model.viewport.startFrame

        #expect(quarter > 0, "a quarter of the way in landed at the start: \(quarter)")
        #expect(
            threeQuarters > quarter,
            "\(quarter) then \(threeQuarters) — the view did not follow the finger")
        #expect(
            threeQuarters < Self.totalFrames,
            "three quarters of the way in landed at the end of the file")
    }

    // MARK: - Taking hold of the lens

    /// **The jerk, as one assertion.** A finger landing on the lens must not
    /// move the view at all until it moves: the reported symptom was the view
    /// teleporting the instant the strip was touched, because every event —
    /// including the first — centred on wherever the finger was.
    @Test("a touch on the lens does not move the view")
    func grabbingTheLensDoesNotJump() {
        let scrub = OverviewScrub(startPixel: 120, lensCentre: 100, lensWidth: 60)
        #expect(scrub.grabbedLens)
        #expect(scrub.centrePixel(for: 120) == 100, "the view moved before the finger did")
    }

    /// And once it does move, it moves **with** the finger, one for one.
    @Test("the lens travels exactly as far as the finger")
    func theLensFollowsTheFinger() {
        let scrub = OverviewScrub(startPixel: 120, lensCentre: 100, lensWidth: 60)
        #expect(scrub.centrePixel(for: 200) == 180)
        #expect(scrub.centrePixel(for: 40) == 20)
    }

    /// Outside the lens it still jumps, which is the behaviour the strip has
    /// always had and which every scrubber with a visible thumb shares.
    @Test("a touch away from the lens goes there")
    func touchingAwayFromTheLensJumps() {
        let scrub = OverviewScrub(startPixel: 300, lensCentre: 100, lensWidth: 60)
        #expect(!scrub.grabbedLens)
        #expect(scrub.centrePixel(for: 300) == 300)
        // …and carries from there, rather than staying absolute.
        #expect(scrub.centrePixel(for: 320) == 320)
    }

    /// A lens narrower than a fingertip is still something you can take hold
    /// of. Deeply zoomed in it is drawn as a 2pt hairline, and requiring the
    /// touch to land within 1pt of its centre would make carrying it impossible
    /// exactly when panning matters most.
    @Test("a hairline lens can still be grabbed")
    func aHairlineLensIsGrabbable() {
        let scrub = OverviewScrub(startPixel: 118, lensCentre: 100, lensWidth: 2)
        #expect(scrub.grabbedLens, "an 18pt miss on a hairline should still count")
        #expect(scrub.centrePixel(for: 118) == 100)

        let miss = OverviewScrub(startPixel: 160, lensCentre: 100, lensWidth: 2)
        #expect(!miss.grabbedLens, "60pt away is a jump, not a grab")
    }

    /// **The stale-width failure, directly.** The strip's gesture used to map
    /// the touch through an `@State` width that starts at 1, so a first event
    /// arriving before the geometry callback mapped every pixel past the first
    /// to the end of the file — a jump, and then nothing, because every later
    /// event asked for the same place.
    @Test("a width of 1 maps the whole strip to the end of the file")
    func staleWidthCollapsesTheStrip() {
        let atTen = PixelMapping.overviewFrame(atPixel: 10, totalFrames: Self.totalFrames, width: 1)
        let atThreeHundred = PixelMapping.overviewFrame(
            atPixel: 300, totalFrames: Self.totalFrames, width: 1)
        #expect(atTen == atThreeHundred)
        #expect(atTen == Self.totalFrames)
    }
}
