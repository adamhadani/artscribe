import ArtscribeKit
import Foundation
import Testing

@testable import ArtscribeUI

/// The sidecar is a **visible, hand-editable file**, chosen over a hidden one in
/// Application Support (spec §2) precisely because you can open it, read it,
/// edit it, and send it to somebody. That only means anything if the app treats
/// what is in it as the user's property.
///
/// Two rules, both regressions:
///
/// 1. **Opening a track never writes.** Opening is not an edit. The bug this
///    suite was written against wrote the sidecar at the top of `open(url:)`,
///    so reopening a track destroyed any hand edit before it was read.
/// 2. **A save preserves keys it did not write.** A note you added, or a field
///    a newer build wrote and this one does not know, survives a round trip.
@MainActor
@Suite("The sidecar is the user's file")
struct SessionConservationTests {

    /// A hand-edited sidecar: a real value a person would change, an unknown
    /// top-level key, and an unknown key nested inside one Artscripture owns.
    private static let handEdited = """
        {
          "schemaVersion" : 1,
          "comment" : "chorus starts at 1:12 — B section is the hard one",
          "loop" : {
            "isEnabled" : true,
            "label" : "chorus",
            "range" : { "count" : 88200, "start" : 44100 }
          },
          "playhead" : 44100,
          "speed" : { "engine" : "fast", "ratio" : 0.6 },
          "track" : { "frameCount" : 441000, "sampleRate" : 44100 },
          "viewport" : { "framesPerPixel" : 441, "startFrame" : 0 }
        }

        """

    private func writeHandEditedSidecar(_ scratch: SessionScratch) throws {
        try Data(Self.handEdited.utf8)
            .write(to: SessionStore.sidecarURL(for: scratch.track))
    }

    private func sidecarBytes(_ scratch: SessionScratch) throws -> Data {
        try Data(contentsOf: SessionStore.sidecarURL(for: scratch.track))
    }

    private func sidecarText(_ scratch: SessionScratch) throws -> String {
        try String(contentsOf: SessionStore.sidecarURL(for: scratch.track), encoding: .utf8)
    }

    // MARK: - Opening never writes

    @Test("opening a track leaves its sidecar byte-for-byte unchanged")
    func openingDoesNotTouchTheFile() throws {
        let scratch = try SessionScratch()
        try writeHandEditedSidecar(scratch)
        let before = try sidecarBytes(scratch)

        // The state `open(url:)` is called from: a track already loaded, its
        // sidecar already adopted. This is the exact arrangement that used to
        // overwrite the file on the way in.
        let model = SessionTestModel.make(scratch)
        #expect(model.speed == SpeedState(ratio: 0.6, engine: .fast))
        #expect(try sidecarBytes(scratch) == before, "adopting a session wrote to it")

        // Reopening the same track. The decode fails — the scratch "track" is a
        // single byte — but the write that used to happen was synchronous at the
        // top of `open(url:)`, before any decoding, so this reaches it.
        model.open(url: scratch.track)
        #expect(try sidecarBytes(scratch) == before, "opening a track wrote to its sidecar")
    }

    @Test("opening a different track does not touch the one being left, either")
    func openingAnotherTrackDoesNotTouchAnUntouchedSidecar() throws {
        let scratch = try SessionScratch()
        try writeHandEditedSidecar(scratch)
        let model = SessionTestModel.make(scratch)
        let before = try sidecarBytes(scratch)

        model.open(url: scratch.root.appendingPathComponent("something-else.wav"))
        #expect(try sidecarBytes(scratch) == before)
    }

    /// Closing is allowed to write — but only when there is something to write.
    /// An open-and-close that changed nothing must leave the file alone, or a
    /// hand edit dies the moment you glance at the track.
    @Test("closing a track nobody touched leaves its sidecar unchanged")
    func closingAnUntouchedTrackWritesNothing() throws {
        let scratch = try SessionScratch()
        try writeHandEditedSidecar(scratch)
        let model = SessionTestModel.make(scratch)
        let before = try sidecarBytes(scratch)

        model.performClose()
        #expect(try sidecarBytes(scratch) == before)
    }

    /// And the other side of that coin: closing after the playhead moved *does*
    /// write, because where you were is what spec §7 persists. Conservation is
    /// about not writing gratuitously, not about never writing.
    @Test("closing after the playhead moved does write")
    func closingAfterMovingWrites() throws {
        let scratch = try SessionScratch()
        try writeHandEditedSidecar(scratch)
        let model = SessionTestModel.make(scratch)

        model.seek(to: 123_456)
        model.performClose()
        let read = try #require(SessionTestModel.read(scratch))
        #expect(read.restoration.state.playhead == 123_456)
        // …and it still did not cost the user their note.
        #expect(try sidecarText(scratch).contains("chorus starts at 1:12"))
    }

    // MARK: - A save preserves what it did not write

    @Test("an explicit Save keeps unknown keys, top level and nested")
    func saveKeepsUnknownKeys() throws {
        let scratch = try SessionScratch()
        try writeHandEditedSidecar(scratch)
        let model = SessionTestModel.make(scratch)

        model.setSpeedPreset(0.5)
        model.saveSession()

        let text = try sidecarText(scratch)
        #expect(text.contains("chorus starts at 1:12 — B section is the hard one"))
        #expect(text.contains("\"label\""))
        #expect(text.contains("\"chorus\""))
        // And the thing the user actually did is in there.
        let read = try #require(SessionTestModel.read(scratch))
        #expect(read.restoration.state.speed.ratio == 0.5)
        #expect(read.restoration.state.loop.range == FrameRange(start: 44100, count: 88200))
    }

    @Test("unknown keys survive repeated saves, not just the first")
    func unknownKeysSurviveRepeatedSaves() throws {
        let scratch = try SessionScratch()
        try writeHandEditedSidecar(scratch)
        let model = SessionTestModel.make(scratch)

        for ratio in [0.5, 0.75, 1.25] {
            model.setSpeedPreset(ratio)
            model.saveSession()
        }
        #expect(try sidecarText(scratch).contains("chorus starts at 1:12"))
        #expect(try sidecarText(scratch).contains("\"label\""))
    }

    @Test("Save As carries the preserved keys into the copy")
    func saveAsCarriesPreservedKeys() throws {
        let scratch = try SessionScratch()
        try writeHandEditedSidecar(scratch)
        let model = SessionTestModel.make(scratch)

        let chosen = scratch.root.appendingPathComponent("for-the-band.artscribe")
        model.saveSession(to: chosen)
        let text = try String(contentsOf: chosen, encoding: .utf8)
        #expect(text.contains("chorus starts at 1:12"))
    }

    /// A field a *newer* Artscripture wrote, opened by this build. It is not
    /// understood, so it is not applied — but it is not destroyed either, and
    /// the newer build finds it again.
    @Test("a field from a future version survives a round trip through this one")
    func futureFieldsSurvive() throws {
        let scratch = try SessionScratch()
        try Data(
            #"""
            {"schemaVersion":2,"speed":{"ratio":0.5,"engine":"studio"},
             "markers":[{"frame":1000,"name":"solo"}],
             "pitchShiftSemitones":-2}
            """#.utf8
        ).write(to: SessionStore.sidecarURL(for: scratch.track))

        let model = SessionTestModel.make(scratch)
        model.setSpeedPreset(0.75)
        model.saveSession()

        let text = try sidecarText(scratch)
        #expect(text.contains("\"markers\""))
        #expect(text.contains("\"solo\""))
        #expect(text.contains("\"pitchShiftSemitones\""))
        // The version we actually wrote is ours, because the file is now ours.
        #expect(text.contains("\"schemaVersion\" : 1"))
    }

    /// The one case where conservation has to give way: bytes that are not JSON
    /// cannot be merged into. Replacing them is the only option, and the user
    /// was already told the file could not be read when the track opened.
    @Test("a save over an unparseable sidecar replaces it rather than failing")
    func unparseableSidecarIsReplaced() throws {
        let scratch = try SessionScratch()
        try Data("{ truncated".utf8).write(to: SessionStore.sidecarURL(for: scratch.track))
        let model = SessionTestModel.make(scratch)
        #expect(model.sessionNotice != nil)

        model.setSpeedPreset(0.5)
        model.saveSession()
        let read = try #require(SessionTestModel.read(scratch))
        #expect(read.failure == nil)
        #expect(read.restoration.state.speed.ratio == 0.5)
    }

    // MARK: - The store's merge, on its own

    @Test("merging keeps their keys, takes ours, and recurses into shared objects")
    func mergeRule() {
        let merged = SessionStore.merged(
            ours: ["a": 1, "nested": ["x": 1]],
            into: ["a": 99, "b": 2, "nested": ["x": 99, "y": 2]])
        #expect(merged["a"] as? Int == 1)
        #expect(merged["b"] as? Int == 2)
        let nested = merged["nested"] as? [String: Any]
        #expect(nested?["x"] as? Int == 1)
        #expect(nested?["y"] as? Int == 2)
    }

    /// Ours wins on a type clash rather than trying to be clever: if the file
    /// says `"loop": "chorus"` and we hold a loop object, the object is the one
    /// that has to survive, or the app cannot save its own state.
    @Test("a type clash resolves in favour of what the app holds")
    func mergeResolvesTypeClashes() {
        let merged = SessionStore.merged(
            ours: ["loop": ["start": 1]], into: ["loop": "chorus"])
        #expect(merged["loop"] is [String: Any])
    }
}
