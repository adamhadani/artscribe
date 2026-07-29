import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// Moving the loop from the model — spec §6.2's `loop.move` actions, as the
/// keyboard and the Loop menu drive them.
///
/// The arithmetic itself is `LoopMoving`, tested next door against the drag's own
/// functions. What is checked here is the model's behaviour around it: the shared
/// amounts, the guards, the one `setLoop` path, and the things a loop move must
/// **not** touch.
@MainActor
@Suite("Loop movement through the model")
struct ViewerModelLoopMoveTests {

    private static let sampleRate: Double = 44100
    /// 60 s, so an aggressive move from the middle is a real move and not a clamp.
    private static let totalFrames = FrameIndex(60 * 44100)

    private func makeModel(frames: FrameIndex = Self.totalFrames) -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(frames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: frames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    private func frames(_ seconds: Double) -> FrameIndex {
        FrameIndex((seconds * Self.sampleRate).rounded())
    }

    private func setLoop(_ model: ViewerModel, from: Double, to: Double, enabled: Bool = true) {
        model.loop = LoopRegion(
            range: FrameRange(start: frames(from), count: frames(to) - frames(from)),
            isEnabled: enabled)
    }

    // MARK: - The two step sizes, shared with the selection

    /// **The loop shares the selection's amounts** rather than adding a third and
    /// fourth preference. One Settings row governs "nudge a region into place",
    /// which is the same job whichever region it is.
    @Test("each tier moves each edge by the selection-move amount for that tier")
    func bothTiersMoveEachTarget() {
        let model = makeModel()
        for tier in SelectionMoveTier.allCases {
            let step = frames(model.selectionMoveAmounts[tier])

            setLoop(model, from: 20, to: 25)
            model.moveLoop(.inPoint, tier, direction: .forward)
            #expect(model.loop.range.start == frames(20) + step, "\(tier) in forward")
            #expect(model.loop.range.end == frames(25), "\(tier) in forward keeps the out point")

            setLoop(model, from: 20, to: 25)
            model.moveLoop(.outPoint, tier, direction: .backward)
            #expect(model.loop.range.end == frames(25) - step, "\(tier) out backward")
            #expect(model.loop.range.start == frames(20), "\(tier) out backward keeps the in")

            setLoop(model, from: 20, to: 25)
            model.moveLoop(.whole, tier, direction: .forward)
            #expect(model.loop.range.start == frames(20) + step, "\(tier) whole forward")
            #expect(model.loop.range.count == frames(5), "\(tier) whole keeps its length")
        }
    }

    @Test("a Settings change to the shared amount moves the loop by the new amount")
    func settingsAmountIsHonoured() {
        let model = makeModel()
        model.setSelectionMoveAmount(0.5, for: .gentle)
        setLoop(model, from: 20, to: 25)
        model.moveLoop(.inPoint, .gentle, direction: .forward)
        #expect(model.loop.range.start == frames(20.5))
    }

    @Test("the two tiers really are different sizes")
    func tiersDiffer() {
        let model = makeModel()
        setLoop(model, from: 20, to: 25)
        model.moveLoop(.whole, .gentle, direction: .forward)
        let gentle = model.loop.range.start
        setLoop(model, from: 20, to: 25)
        model.moveLoop(.whole, .aggressive, direction: .forward)
        #expect(model.loop.range.start > gentle)
    }

    // MARK: - Guards

    @Test("with no track loaded every loop move is a no-op")
    func noTrackIsANoOp() {
        let model = ViewerModel()
        for target in LoopMoveTarget.allCases {
            model.moveLoop(target, .gentle, direction: .forward)
            #expect(model.loop == LoopRegion(), "\(target)")
        }
    }

    /// `A` pressed once with no `S` yet. There are no edges to move, and giving
    /// the region a length here would be the key inventing state.
    @Test("an empty loop region is left exactly alone")
    func emptyLoopIsANoOp() {
        let model = makeModel()
        let empty = LoopRegion(range: FrameRange(start: frames(10), count: 0), isEnabled: true)
        for target in LoopMoveTarget.allCases {
            model.loop = empty
            model.moveLoop(target, .gentle, direction: .forward)
            #expect(model.loop == empty, "\(target)")
        }
    }

    /// A loop already hard against a bound must not keep re-marking the document
    /// modified on every press. `applyLoop` returns early on a no-op, which is
    /// what makes that true — and this is the guard on it.
    @Test("a move that changes nothing leaves the document unmodified")
    func aMoveThatChangesNothingIsSilent() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.loop = LoopRegion(range: FrameRange(start: 0, count: 4410), isEnabled: true)
        model.saveSession()
        #expect(!model.isDirty)
        model.moveLoop(.whole, .gentle, direction: .backward)
        #expect(model.loop.range == FrameRange(start: 0, count: 4410))
        #expect(!model.isDirty)
    }

    @Test("a move that does change something marks the document modified")
    func aRealMoveMarksTheDocumentModified() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.loop = LoopRegion(range: FrameRange(start: 44100, count: 44100), isEnabled: true)
        model.saveSession()
        #expect(!model.isDirty)
        model.moveLoop(.inPoint, .gentle, direction: .forward)
        #expect(model.isDirty)
    }

    // MARK: - Clamping at both ends, through the model

    @Test("moving the in point back from the first second stops at zero")
    func clampsAtTheStart() {
        let model = makeModel()
        setLoop(model, from: 0.1, to: 5)
        model.moveLoop(.inPoint, .aggressive, direction: .backward)
        #expect(model.loop.range.start == 0)
        #expect(model.loop.range.end == frames(5))
    }

    @Test("moving the out point on from the last second stops at the end of the file")
    func clampsAtTheEnd() {
        let model = makeModel()
        setLoop(model, from: 55, to: 59.9)
        model.moveLoop(.outPoint, .aggressive, direction: .forward)
        #expect(model.loop.range.end == Self.totalFrames)
        #expect(model.loop.range.start == frames(55))
    }

    // MARK: - What a loop move must not touch

    /// The playhead is where you are listening from; the loop is what you are
    /// listening to. Dragging the playhead along would also mean a `.seek`, which
    /// is one of the two things that reset the stretcher (CLAUDE.md on looping).
    @Test("the playhead and the selection are left where they are")
    func nothingElseMoves() {
        let model = makeModel()
        setLoop(model, from: 20, to: 25)
        model.seek(to: frames(30))
        model.selection.begin(at: frames(2))
        model.selection.extend(to: frames(4))
        let playhead = model.playhead
        let selection = model.selection
        for target in LoopMoveTarget.allCases {
            model.moveLoop(target, .gentle, direction: .forward)
        }
        #expect(model.playhead == playhead)
        #expect(model.selection == selection)
    }

    @Test("whether the loop is switched on is never changed by moving it")
    func enablementIsPreserved() {
        let model = makeModel()
        for enabled in [true, false] {
            setLoop(model, from: 20, to: 25, enabled: enabled)
            model.moveLoop(.whole, .gentle, direction: .forward)
            #expect(model.loop.isEnabled == enabled)
        }
    }

    /// Repeated presses keep going rather than sticking, and the swap is reached
    /// through the model exactly as it is through the drag.
    @Test("holding the key past the far edge swaps and keeps moving")
    func repeatedPressesSwapAndContinue() {
        let model = makeModel()
        setLoop(model, from: 20, to: 21)
        // 2 s aggressive step over a 1 s loop: the first press crosses.
        model.moveLoop(.inPoint, .aggressive, direction: .forward)
        #expect(model.loop.range.start == frames(21))
        #expect(model.loop.range.end == frames(22))
        model.moveLoop(.inPoint, .aggressive, direction: .forward)
        #expect(model.loop.range.start == frames(22))
        #expect(model.loop.range.end == frames(23))
    }
}
