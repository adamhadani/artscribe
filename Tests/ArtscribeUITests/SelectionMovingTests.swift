import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// Moving the whole selection — spec §6.2's `selection.move` pair — as the
/// keyboard, the Edit menu and the Settings window drive it.
///
/// The clamping arithmetic itself is `Selection.translated(by:within:)`, tested
/// in `ArtscribeKitTests`. What is checked here is the model's behaviour around
/// it: the amounts, their validation, the guards, and the fact that neither the
/// playhead nor the loop is dragged along with the selection.
@MainActor
@Suite("Selection movement")
struct SelectionMovingTests {

    private static let sampleRate: Double = 44100
    /// 60 s, so an aggressive move from the middle is a real move rather than a
    /// clamp. The clamps get a track of their own below.
    private static let totalFrames = FrameIndex(60 * 44100)

    private func makeModel(frames: FrameIndex = Self.totalFrames) -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(frames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: frames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    private func select(_ model: ViewerModel, from: FrameIndex, to: FrameIndex) {
        model.selection.begin(at: from)
        model.selection.extend(to: to)
    }

    private func frames(_ seconds: Double) -> FrameIndex {
        FrameIndex((seconds * Self.sampleRate).rounded())
    }

    // MARK: - The two step sizes

    @Test("each tier moves the whole selection by its own amount, both ways")
    func bothTiersMove() {
        let model = makeModel()
        for tier in SelectionMoveTier.allCases {
            let step = frames(tier.defaultSeconds)
            select(model, from: frames(20), to: frames(25))
            model.moveSelection(tier, direction: .forward)
            #expect(model.selection.range.start == frames(20) + step)
            #expect(model.selection.range.end == frames(25) + step)
            model.moveSelection(tier, direction: .backward)
            #expect(model.selection.range == FrameRange(start: frames(20), count: frames(5)))
        }
    }

    @Test("the two tiers really are different sizes")
    func tiersDiffer() {
        #expect(
            SelectionMoveTier.gentle.defaultSeconds < SelectionMoveTier.aggressive.defaultSeconds)
    }

    // MARK: - The clamps, at both ends

    @Test("a selection pushed against the start of the file stops, keeping its length")
    func clampsAtTheStart() {
        let model = makeModel()
        select(model, from: frames(0.1), to: frames(1.1))
        let length = model.selection.range.count
        for _ in 0..<20 { model.moveSelection(.aggressive, direction: .backward) }
        #expect(model.selection.range.start == 0)
        #expect(model.selection.range.count == length)
        // And pressing again at the wall changes nothing at all.
        let parked = model.selection
        model.moveSelection(.aggressive, direction: .backward)
        #expect(model.selection == parked)
    }

    @Test("a selection pushed against the end of the file stops, keeping its length")
    func clampsAtTheEnd() {
        let model = makeModel()
        select(model, from: Self.totalFrames - frames(1.1), to: Self.totalFrames - frames(0.1))
        let length = model.selection.range.count
        for _ in 0..<20 { model.moveSelection(.aggressive, direction: .forward) }
        #expect(model.selection.range.end == Self.totalFrames)
        #expect(model.selection.range.count == length)
        let parked = model.selection
        model.moveSelection(.aggressive, direction: .forward)
        #expect(model.selection == parked)
    }

    // MARK: - Guards

    @Test("moving an empty selection does nothing — there is nothing to move")
    func emptySelection() {
        let model = makeModel()
        model.clearSelection()
        for tier in SelectionMoveTier.allCases {
            model.moveSelection(tier, direction: .forward)
        }
        #expect(model.selection.isEmpty)
    }

    @Test("moving the selection is a no-op with no track loaded")
    func withoutATrack() {
        let model = ViewerModel()
        model.moveSelection(.gentle, direction: .forward)
        #expect(model.selection.isEmpty)
    }

    /// The selection is not the playhead, and it is not the loop. Moving it
    /// must not seek — a seek resets the stretcher (see CLAUDE.md on looping) —
    /// and must not drag an already-set loop region with it.
    @Test("moving the selection leaves the playhead and the loop where they were")
    func movingTouchesNothingElse() {
        let model = makeModel()
        model.seek(to: frames(30))
        select(model, from: frames(10), to: frames(12))
        model.loopFromSelection()
        let loop = model.loop
        model.moveSelection(.aggressive, direction: .forward)
        #expect(model.playhead == frames(30))
        #expect(model.loop == loop)
    }

    // MARK: - The amounts

    @Test("a Settings edit reaches the action without a relaunch")
    func amountsApplyLive() {
        let model = makeModel()
        model.prefs.setSelectionMoveAmount(5, for: .gentle)
        #expect(model.prefs.selectionMoveAmounts[.gentle] == 5)
        select(model, from: frames(10), to: frames(11))
        model.moveSelection(.gentle, direction: .forward)
        #expect(model.selection.range.start == frames(15))
    }

    /// 20 ms has to be expressible, which is the whole reason these are edited
    /// in seconds with fractions rather than in whole seconds.
    @Test("a fractional amount survives being stored and moves by exactly that much")
    func fractionalAmounts() {
        let model = makeModel()
        model.prefs.setSelectionMoveAmount(0.02, for: .gentle)
        #expect(model.prefs.selectionMoveAmounts[.gentle] == 0.02)
        select(model, from: frames(10), to: frames(11))
        model.moveSelection(.gentle, direction: .forward)
        #expect(model.selection.range.start == frames(10) + FrameIndex((0.02 * 44100).rounded()))
    }

    /// Spec §8: a stored zero would be a menu item that silently does nothing.
    @Test("an amount the model is asked to store is validated first")
    func amountsAreValidated() {
        let model = makeModel()
        model.prefs.setSelectionMoveAmount(0, for: .gentle)
        #expect(model.prefs.selectionMoveAmounts[.gentle] == NudgeAmounts.minimumSeconds)
        model.prefs.setSelectionMoveAmount(-4, for: .aggressive)
        #expect(model.prefs.selectionMoveAmounts[.aggressive] == NudgeAmounts.minimumSeconds)
        model.prefs.setSelectionMoveAmount(.nan, for: .gentle)
        #expect(
            model.prefs.selectionMoveAmounts[.gentle] == SelectionMoveTier.gentle.defaultSeconds)
        model.prefs.setSelectionMoveAmount(1e9, for: .aggressive)
        #expect(model.prefs.selectionMoveAmounts[.aggressive] == NudgeAmounts.maximumSeconds)

        // The point of the validation: the action still moves.
        select(model, from: frames(10), to: frames(11))
        model.moveSelection(.gentle, direction: .forward)
        #expect(model.selection.range.start > frames(10))
    }

    @Test("Restore Defaults puts both amounts back")
    func restoreDefaults() {
        let model = makeModel()
        model.prefs.setSelectionMoveAmount(7, for: .gentle)
        model.prefs.restoreDefaultSelectionMoveAmounts()
        #expect(model.prefs.selectionMoveAmounts == SelectionMoveAmounts.defaults)
    }

    /// The Settings tab has one Restore Defaults button for three sections, so
    /// it has to reach all of them — a button that silently left the zoom
    /// direction inverted would be the same class of lie as an amount of zero.
    @Test("the one Restore Defaults button restores everything on the tab")
    func restoreEverything() {
        let model = makeModel()
        #expect(!model.prefs.hasNonDefaultPreferences)
        model.prefs.setSelectionMoveAmount(7, for: .gentle)
        model.prefs.setNudgeAmount(9, for: .normal)
        model.prefs.setInvertZoomDrag(true)
        #expect(model.prefs.hasNonDefaultPreferences)

        model.prefs.restoreDefaults()
        #expect(model.prefs.selectionMoveAmounts == SelectionMoveAmounts.defaults)
        #expect(model.prefs.nudgeAmounts == NudgeAmounts.defaults)
        #expect(!model.prefs.invertZoomDrag)
        #expect(!model.prefs.hasNonDefaultPreferences)
    }

    // MARK: - Extending, which the Edit menu also carries

    @Test("extending moves the head by the normal nudge amount and keeps the anchor")
    func extendSelection() {
        let model = makeModel()
        select(model, from: frames(10), to: frames(12))
        model.extendSelection(.forward)
        #expect(model.selection.anchor == frames(10))
        #expect(model.selection.head == frames(12) + frames(2))
        model.extendSelection(.backward)
        #expect(model.selection.head == frames(12))
    }

    @Test("extending with no selection starts one at the playhead")
    func extendFromNothing() {
        let model = makeModel()
        model.seek(to: frames(20))
        model.clearSelection()
        model.extendSelection(.forward)
        #expect(model.selection.range == FrameRange(start: frames(20), count: frames(2)))
    }

    @Test("extending clamps at both ends of the file")
    func extendClamps() {
        let model = makeModel()
        select(model, from: frames(1), to: frames(2))
        for _ in 0..<40 { model.extendSelection(.backward) }
        #expect(model.selection.head == 0)
        for _ in 0..<80 { model.extendSelection(.forward) }
        #expect(model.selection.head == Self.totalFrames)
    }

    @Test("extending is a no-op with no track loaded")
    func extendWithoutATrack() {
        let model = ViewerModel()
        model.extendSelection(.forward)
        #expect(model.selection.isEmpty)
    }

    // MARK: - Persistence

    @Test("the amounts are stored, validated on the way back in, and adopted")
    func persistence() {
        let name = "com.artscripture.tests.move.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create a defaults suite")
            return
        }
        var stored = SelectionMoveAmounts.defaults
        stored[.aggressive] = 4.5
        InteractionSettings(defaults: defaults).save(
            InteractionPreferences(invertZoomDrag: true, selectionMove: stored))

        let model = makeModel()
        model.prefs.adopt(interaction: InteractionSettings(defaults: defaults))
        #expect(model.prefs.selectionMoveAmounts[.aggressive] == 4.5)
        #expect(model.prefs.invertZoomDrag)

        // And an edit goes back out to the same store.
        model.prefs.setSelectionMoveAmount(0.02, for: .gentle)
        let reloaded = InteractionSettings(defaults: defaults).load()
        #expect(reloaded.selectionMove[.gentle] == 0.02)
    }

    /// Storage is not a trusted source: an older build, a `defaults write`, or
    /// a half-finished save must not be able to install an amount of zero.
    @Test("a nonsense stored amount is repaired on load, never installed")
    func storedNonsenseIsRepaired() {
        let name = "com.artscripture.tests.move.bad.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create a defaults suite")
            return
        }
        defaults.set(0, forKey: InteractionSettings.key(for: .gentle))
        defaults.set("not a number", forKey: InteractionSettings.key(for: .aggressive))
        let loaded = InteractionSettings(defaults: defaults).load()
        #expect(loaded.selectionMove[.gentle] == NudgeAmounts.minimumSeconds)
        #expect(loaded.selectionMove[.aggressive] == SelectionMoveTier.aggressive.defaultSeconds)
    }

    @Test("an amount back at its default is removed rather than pinned")
    func defaultsAreNotPinned() {
        let name = "com.artscripture.tests.move.clean.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create a defaults suite")
            return
        }
        let settings = InteractionSettings(defaults: defaults)
        var amounts = SelectionMoveAmounts.defaults
        amounts[.gentle] = 3
        settings.save(InteractionPreferences(invertZoomDrag: false, selectionMove: amounts))
        #expect(defaults.object(forKey: InteractionSettings.key(for: .gentle)) != nil)
        settings.save(
            InteractionPreferences(invertZoomDrag: false, selectionMove: .defaults))
        #expect(defaults.object(forKey: InteractionSettings.key(for: .gentle)) == nil)
        #expect(settings.load().selectionMove == SelectionMoveAmounts.defaults)
    }
}
