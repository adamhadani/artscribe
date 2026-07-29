import Foundation
import Testing

@testable import ArtscribeKit

/// The track-marker lane's visibility, across a sidecar round trip.
@Suite("Session: track-marker visibility")
struct SessionMarkerPersistenceTests {

    private static let track = TrackIdentity(sampleRate: 44100, frameCount: 441_000)

    /// The field is new, so every sidecar written before it exists lacks the
    /// key. That must read as "show them" — the discoverable default — and must
    /// not be reported as damage.
    @Test("a sidecar without the key defaults to showing markers, and is not a repair")
    func absentKeyDefaultsToVisible() {
        let file = SessionFile(
            schemaVersion: SessionFile.currentSchemaVersion, track: Self.track)
        let restored = SessionState.restoring(file, frameCount: 441_000, sampleRate: 44100)
        #expect(restored.state.showTrackMarks)
        #expect(restored.repairs.isEmpty || !restored.repairs.contains(SessionRepair.schemaVersion))
    }

    @Test("hiding the lane survives a write and a read")
    func hiddenSurvivesRoundTrip() {
        var state = SessionState(track: Self.track)
        state.showTrackMarks = false
        let restored = SessionState.restoring(
            state.fileRepresentation, frameCount: 441_000, sampleRate: 44100)
        #expect(!restored.state.showTrackMarks)
    }

    @Test("showing it survives too, so the round trip is not just a default")
    func visibleSurvivesRoundTrip() {
        let state = SessionState(track: Self.track, showTrackMarks: true)
        let restored = SessionState.restoring(
            state.fileRepresentation, frameCount: 441_000, sampleRate: 44100)
        #expect(restored.state.showTrackMarks)
    }

    /// The three tests above all passed while `JSONEncoder` was silently
    /// dropping the field, because `SessionFile` has a hand-written
    /// `CodingKeys` and a hand-written `init(from:)` and neither knew about it.
    /// A struct round trip never touches either. This goes through **JSON**,
    /// which is what actually lands beside the audio.
    @Test("the flag survives a real JSON encode and decode, not just a struct copy")
    func survivesActualJSON() throws {
        var state = SessionState(track: Self.track)
        state.showTrackMarks = false
        let data = try JSONEncoder().encode(state.fileRepresentation)

        // The key is in the file the user can open and hand-edit (spec §2).
        let raw = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["showTrackMarks"] as? Bool == false, "key missing from the sidecar")

        let decoded = try JSONDecoder().decode(SessionFile.self, from: data)
        #expect(decoded.showTrackMarks == false)
        let restored = SessionState.restoring(decoded, frameCount: 441_000, sampleRate: 44100)
        #expect(!restored.state.showTrackMarks)
    }
}
