import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// Dirty tracking and the save/close decisions, driven against the model.
///
/// The AppKit halves — the save panel and the close sheet — are not here; they
/// are driven for real in the acceptance run. What is here is every decision
/// those two only *present*, so the answer is testable without a window.
@MainActor
@Suite("Session persistence in the model")
struct ViewerModelSessionTests {

    // MARK: - What counts as dirty

    @Test("a freshly opened track is clean")
    func freshTrackIsClean() throws {
        let model = SessionTestModel.make(try SessionScratch())
        #expect(!model.isDirty)
        #expect(model.sessionLocation == nil)
    }

    @Test("changing the speed is an edit")
    func speedIsAnEdit() throws {
        let model = SessionTestModel.make(try SessionScratch())
        model.setSpeedPreset(0.5)
        #expect(model.isDirty)
    }

    @Test("switching the stretch engine is an edit")
    func engineIsAnEdit() throws {
        let model = SessionTestModel.make(try SessionScratch())
        model.setStretchEngine(.fast)
        #expect(model.isDirty)
    }

    @Test("setting or clearing the loop is an edit")
    func loopIsAnEdit() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.seek(to: 1000)
        model.setLoopIn()
        model.seek(to: 5000)
        model.setLoopOut()
        #expect(model.isDirty)

        model.saveSession()
        #expect(!model.isDirty)
        model.toggleLoop()
        #expect(model.isDirty)
    }

    /// The decision the whole feature turns on. A playhead that ticks sixty
    /// times a second would leave the document permanently modified, the close
    /// prompt permanently on screen, and the modified dot meaningless.
    @Test("moving the playhead is not an edit")
    func playheadIsNotAnEdit() throws {
        let model = SessionTestModel.make(try SessionScratch())
        model.seek(to: 220_500)
        #expect(!model.isDirty)
    }

    @Test("zooming and scrolling are not edits")
    func viewChangesAreNotEdits() throws {
        let model = SessionTestModel.make(try SessionScratch())
        model.zoomIn()
        model.zoomIn()
        model.scrollRight()
        model.fitWholeFile()
        #expect(!model.isDirty)
    }

    @Test("selecting is not an edit")
    func selectionIsNotAnEdit() throws {
        let model = SessionTestModel.make(try SessionScratch())
        model.selectAll()
        model.extendSelection(.backward)
        #expect(!model.isDirty)
    }

    @Test("the volume is not part of the session and is not an edit")
    func volumeIsNotAnEdit() throws {
        let model = SessionTestModel.make(try SessionScratch())
        model.volumeDown(fine: false)
        model.toggleMute()
        #expect(!model.isDirty)
    }

    @Test("a change that changes nothing is not an edit")
    func noOpIsNotAnEdit() throws {
        let model = SessionTestModel.make(try SessionScratch())
        model.setSpeedPreset(1.0)
        #expect(!model.isDirty)
    }

    // MARK: - Save

    @Test("Save writes the sidecar beside the track and clears the dirty flag")
    func saveWritesTheSidecar() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.5)
        model.saveSession()

        #expect(!model.isDirty)
        #expect(model.sessionLocation == .sidecar(SessionStore.sidecarURL(for: scratch.track)))
        #expect(
            FileManager.default.fileExists(
                atPath: SessionStore.sidecarURL(for: scratch.track).path))
    }

    @Test("Save is a no-op with no track, rather than writing something nameless")
    func saveWithoutATrackDoesNothing() {
        let model = ViewerModel()
        model.saveSession()
        #expect(model.sessionLocation == nil)
        #expect(!model.canSaveSession)
    }

    @Test("Save captures the view position as well as the edits")
    func savePersistsPositionToo() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.seek(to: 12_345)
        model.zoomIn()
        model.setSpeedPreset(0.5)
        model.saveSession()

        let read = try #require(
            SessionTestModel.read(scratch))
        #expect(read.restoration.state.playhead == 12_345)
        #expect(read.restoration.state.viewport.framesPerPixel == model.viewport.framesPerPixel)
    }

    // MARK: - Autosave (spec §7, "debounced during editing")

    /// Waits for the pending autosave to land. Polls rather than sleeping a
    /// fixed span: the suite runs in parallel, and a fixed wait is a flaky test
    /// waiting for a busy machine.
    private func waitForAutosave(_ model: ViewerModel) async {
        let deadline = Date().addingTimeInterval(10)
        while model.isDirty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("an edit to a track that has a sidecar is written without being asked")
    func autosaveWritesTheAdoptedSidecar() async throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.autosaveDelay = .milliseconds(20)
        model.setSpeedPreset(0.5)
        model.saveSession()

        model.setSpeedPreset(0.75)
        #expect(model.isDirty)
        await waitForAutosave(model)
        #expect(!model.isDirty)

        let read = try #require(SessionTestModel.read(scratch))
        #expect(read.restoration.state.speed.ratio == 0.75)
    }

    /// The other half of the rule, and the reason the close prompt is reachable
    /// at all: Artscripture does not drop a visible file into somebody's music
    /// folder without being asked.
    @Test("an edit to a track with no sidecar autosaves nothing")
    func autosaveDoesNotCreateTheFirstSidecar() async throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.autosaveDelay = .milliseconds(20)
        model.setSpeedPreset(0.5)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.isDirty)
        #expect(
            !FileManager.default.fileExists(
                atPath: SessionStore.sidecarURL(for: scratch.track).path))
    }

    @Test("a burst of edits debounces into one write, carrying the last value")
    func autosaveDebouncesABurst() async throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.autosaveDelay = .milliseconds(20)
        model.saveSession()

        // No `await` inside the burst, deliberately: the debounce task cannot
        // run while the main actor is held, so "still dirty afterwards" is a
        // fact rather than a race with the clock.
        for ratio in [0.9, 0.8, 0.7, 0.6, 0.5] { model.setSpeedPreset(ratio) }
        #expect(model.isDirty)
        await waitForAutosave(model)

        let read = try #require(SessionTestModel.read(scratch))
        #expect(read.restoration.state.speed.ratio == 0.5)
    }

    // MARK: - Restore

    @Test("reopening a track restores speed, loop, engine, viewport and playhead")
    func reopeningRestoresEverything() throws {
        let scratch = try SessionScratch()
        let first = SessionTestModel.make(scratch)
        first.setSpeedPreset(0.5)
        first.setStretchEngine(.fast)
        first.seek(to: 1000)
        first.setLoopIn()
        first.seek(to: 60_000)
        first.setLoopOut()
        first.toggleLoop()
        first.zoomIn()
        first.zoomIn()
        first.seek(to: 33_333)
        first.saveSession()

        let second = SessionTestModel.make(scratch)
        #expect(second.speed == first.speed)
        #expect(second.loop == first.loop)
        #expect(second.playhead == 33_333)
        #expect(second.viewport.framesPerPixel == first.viewport.framesPerPixel)
        #expect(second.viewport.startFrame == first.viewport.startFrame)
        // Restoring is not editing: the window must not open already modified.
        #expect(!second.isDirty)
        #expect(second.sessionLocation?.isBesideTheTrack == true)
    }

    @Test("a damaged sidecar opens the track on defaults and says so")
    func damagedSidecarIsSurfaced() throws {
        let scratch = try SessionScratch()
        try Data("{ truncated".utf8)
            .write(to: SessionStore.sidecarURL(for: scratch.track))
        let model = SessionTestModel.make(scratch)
        #expect(model.speed == SpeedState())
        #expect(model.loop == LoopRegion())
        #expect(model.sessionNotice != nil)
        #expect(!model.isDirty)
    }

    @Test("a partly damaged sidecar restores what it can and names what it could not")
    func partialDamageIsNamed() throws {
        let scratch = try SessionScratch()
        try Data(#"{"schemaVersion":1,"speed":{"ratio":0.25},"loop":"nope"}"#.utf8)
            .write(to: SessionStore.sidecarURL(for: scratch.track))
        let model = SessionTestModel.make(scratch)
        #expect(model.speed.ratio == 0.25)
        let notice = try #require(model.sessionNotice)
        #expect(notice.contains("loop"))
    }

    // MARK: - The read-only fallback (spec §7)

    @Test("a read-only folder saves to Application Support and surfaces it")
    func readOnlyFolderFallsBack() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.5)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: scratch.tracks.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scratch.tracks.path)
        }

        model.saveSession()
        #expect(!model.isDirty)
        #expect(model.sessionLocation?.isBesideTheTrack == false)
        #expect(model.isSessionStoredAwayFromTheTrack)
        // Loop points must never be silently lost because a directory was
        // read-only, so the fact that they moved is on screen.
        //
        // Asserted through the **standing banner**, not the dismissible notice.
        // Both used to fire and the user saw one condition described twice, in
        // two orders of words, one dismissible and one not. The condition does
        // not go away, so the banner is the honest home for it — and this test
        // now checks the surface that actually exists rather than the one that
        // happened to be easiest to reach.
        #expect(
            model.isSessionStoredAwayFromTheTrack,
            "the standing banner is what tells the user, and it is not showing")
        #expect(
            ViewerModel.fallbackNotice(reason: model.sessionFallbackReason)
                .contains("Application Support"))
        #expect(
            model.sessionNotice == nil,
            "a second, dismissible notice about the same condition is back")
    }
}
