import ArtscribeKit
import Foundation
import Testing

@testable import ArtscribeUI

/// Closing, Save As, and what the window chrome is told — the decisions the
/// AppKit sheet and save panel only present.
@MainActor
@Suite("Session closing and Save As")
struct ViewerModelSessionCloseTests {

    // MARK: - Closing

    @Test("closing a clean, never-saved track just closes")
    func cleanNeverSavedClosesSilently() throws {
        let model = SessionTestModel.make(try SessionScratch())
        #expect(model.closeAction == .close)
    }

    @Test("closing an edited, never-saved track asks")
    func editedNeverSavedAsks() throws {
        let model = SessionTestModel.make(try SessionScratch())
        model.setSpeedPreset(0.5)
        #expect(model.closeAction == .ask)
    }

    /// The other half of the resolution between spec §7's autosave and the
    /// requested prompt: once a sidecar exists, the file is kept up to date and
    /// closing writes rather than asks — the macOS rule for a document that has
    /// a location.
    @Test("closing a track that already has a sidecar saves without asking")
    func adoptedTrackSavesOnClose() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.5)
        model.saveSession()
        model.setSpeedPreset(0.75)
        #expect(model.closeAction == .saveThenClose)

        model.performClose()
        let read = try #require(
            SessionTestModel.read(scratch))
        #expect(read.restoration.state.speed.ratio == 0.75)
    }

    @Test("closing an unedited track that has a sidecar still records where you were")
    func adoptedTrackPersistsPositionOnClose() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.5)
        model.saveSession()
        model.seek(to: 99_000)
        #expect(!model.isDirty)
        #expect(model.closeAction == .saveThenClose)
        model.performClose()

        let read = try #require(
            SessionTestModel.read(scratch))
        #expect(read.restoration.state.playhead == 99_000)
    }

    @Test("closing with no track at all just closes")
    func noTrackCloses() {
        #expect(ViewerModel().closeAction == .close)
    }

    @Test("Don't Save leaves the disk untouched")
    func discardWritesNothing() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.5)
        model.discardSessionChanges()
        #expect(!model.isDirty)
        #expect(
            !FileManager.default.fileExists(
                atPath: SessionStore.sidecarURL(for: scratch.track).path))
    }

    // MARK: - Replacing the track

    /// A one-window, one-track app has exactly two ways to walk away from a
    /// session: closing the window, and loading another file. The second one is
    /// the easy one to forget, and forgetting it loses loop points silently.
    ///
    /// The guard lives in `SessionPrompt.whenSafeToLeave`, which every UI route
    /// into `open(url:)` goes through — **not** inside `open(url:)` itself.
    /// Putting it there is what made reopening a track rewrite its own sidecar
    /// before reading it; see `SessionConservationTests`.
    @Test("leaving a track for another one writes the outgoing session first")
    func leavingATrackFlushesItsSession() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.5)
        model.saveSession()
        model.seek(to: 77_000)
        model.setSpeedPreset(0.75)
        #expect(model.isDirty)

        // The load itself writes nothing at all.
        model.open(url: scratch.root.appendingPathComponent("not-a-track.wav"))
        #expect(model.isDirty)
        #expect(try #require(SessionTestModel.read(scratch)).restoration.state.speed.ratio == 0.5)

        // The guard that runs before it does.
        var proceeded = false
        SessionPrompt.whenSafeToLeave(model) { proceeded = $0 }
        #expect(proceeded)
        #expect(!model.isDirty)

        let read = try #require(SessionTestModel.read(scratch))
        #expect(read.restoration.state.speed.ratio == 0.75)
        #expect(read.restoration.state.playhead == 77_000)
    }

    @Test("leaving a track nobody edited asks nothing and writes nothing")
    func leavingAnUntouchedTrackIsSilent() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.saveSession()
        let before = try Data(contentsOf: SessionStore.sidecarURL(for: scratch.track))

        var proceeded = false
        SessionPrompt.whenSafeToLeave(model) { proceeded = $0 }
        #expect(proceeded)
        #expect(try Data(contentsOf: SessionStore.sidecarURL(for: scratch.track)) == before)
    }

    // MARK: - Save As

    @Test("Save As to the canonical path adopts it as the live sidecar")
    func saveAsToCanonicalPathAdopts() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.5)
        model.saveSession(to: SessionStore.sidecarURL(for: scratch.track))
        #expect(!model.isDirty)
        #expect(model.sessionLocation == .sidecar(SessionStore.sidecarURL(for: scratch.track)))
        #expect(model.closeAction == .saveThenClose)
    }

    /// The consequence a user has to be told about, rather than discover months
    /// later: a session file that is not named after its track, beside its
    /// track, is not the one reopening finds.
    @Test("Save As elsewhere writes a copy, says so, and does not pretend to be saved")
    func saveAsElsewhereIsACopy() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.5)
        let chosen = scratch.root.appendingPathComponent("for-the-band.artscribe")
        model.saveSession(to: chosen)

        #expect(FileManager.default.fileExists(atPath: chosen.path))
        let notice = try #require(model.sessionNotice)
        #expect(notice.contains("for-the-band.artscribe"))
        // The canonical sidecar still does not exist, so the document is still
        // unsaved and closing still asks.
        #expect(model.isDirty)
        #expect(model.closeAction == .ask)
        #expect(
            !FileManager.default.fileExists(
                atPath: SessionStore.sidecarURL(for: scratch.track).path))
    }

    @Test("the Save As panel is offered the canonical name by default")
    func saveAsDefaultsToTheCanonicalName() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        #expect(model.suggestedSessionSaveURL == SessionStore.sidecarURL(for: scratch.track))
    }

    // MARK: - The window's title and dot

    @Test("the window title names the track and never repeats the modified state")
    func windowTitle() throws {
        let scratch = try SessionScratch()
        let model = SessionTestModel.make(scratch)
        // AppKit draws the modified dot in the close button from
        // `isDocumentEdited`; spelling "(Edited)" into the title as well would
        // be saying it twice.
        #expect(model.windowTitle == "Blackbird.flac")
        model.setSpeedPreset(0.5)
        #expect(model.windowTitle == "Blackbird.flac")
        #expect(ViewerModel().windowTitle == "Artscripture")
    }
}
