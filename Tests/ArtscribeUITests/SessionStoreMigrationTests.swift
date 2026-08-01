import ArtscribeKit
import CryptoKit
import Foundation
import Testing

@testable import ArtscribeUI

/// Reading sessions written before the app was renamed from Artscribe to
/// Artscripture.
///
/// The rename changed the sidecar extension, and a sidecar is the user's file —
/// it holds the loop points they spent an evening finding. Renaming our own app
/// is not a reason for those to stop being found, so the store reads the old
/// extension and the old Application Support folder, writes only the new ones,
/// and never deletes anything.
///
/// Every one of these was checked against the pre-migration code first: each
/// fails without the corresponding branch in `existingLocation`.
@Suite("Session sidecar migration")
struct SessionStoreMigrationTests {

    private let frames: FrameIndex = 2_000_000
    private let rate: Double = 44_100

    /// A track with its own scratch directory, plus both fallback directories,
    /// so the legacy path can be exercised without touching real Application
    /// Support.
    private final class Scratch {
        let root: URL
        let store: SessionStore
        let track: URL
        let legacyFallback: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("artscripture-migration-\(UUID().uuidString)")
            let tracks = root.appendingPathComponent("tracks")
            let fallback = root.appendingPathComponent("fallback")
            legacyFallback = root.appendingPathComponent("legacy-fallback")
            for directory in [tracks, fallback, legacyFallback] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
            store = SessionStore(
                fallbackDirectory: fallback, legacyFallbackDirectory: legacyFallback)
            track = tracks.appendingPathComponent("Blackbird.flac")
            try Data([0]).write(to: track)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func state(playhead: FrameIndex) -> SessionState {
        SessionState(
            speed: SpeedState(ratio: 0.6, engine: .fast),
            loop: LoopRegion(range: FrameRange(start: 1000, count: 44_100), isEnabled: true),
            viewport: ViewportState(startFrame: 500, framesPerPixel: 128),
            playhead: playhead,
            track: TrackIdentity(sampleRate: rate, frameCount: frames))
    }

    /// Writes a session at an arbitrary URL, the way an older build would have.
    private func writeSession(_ state: SessionState, to url: URL) throws {
        let data = try JSONEncoder().encode(state.fileRepresentation)
        try data.write(to: url)
    }

    // MARK: - The extension beside the track

    /// The whole point: an evening's loop points do not vanish because the app
    /// changed its name.
    @Test("a .artscribe sidecar beside the track is still found")
    func legacySidecarIsFound() throws {
        let scratch = try Scratch()
        let legacy = SessionStore.legacySidecarURL(for: scratch.track)
        try writeSession(state(playhead: 99_000), to: legacy)

        let read = scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate)
        #expect(read?.restoration.state.playhead == 99_000)
        #expect(read?.location == .sidecar(legacy))
    }

    /// If both exist, the current extension is the more recent save.
    @Test("the current extension wins over the legacy one")
    func currentExtensionWins() throws {
        let scratch = try Scratch()
        try writeSession(state(playhead: 11), to: SessionStore.legacySidecarURL(for: scratch.track))
        try writeSession(state(playhead: 22), to: SessionStore.sidecarURL(for: scratch.track))

        let read = scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate)
        #expect(read?.restoration.state.playhead == 22)
    }

    /// Saving migrates the name — and **leaves the old file where it was**.
    /// Deleting a file the user can see, to tidy up after our own rename, is a
    /// larger liberty than leaving one stale file behind.
    @Test("a save writes the new extension and does not delete the old file")
    func saveMigratesWithoutDeleting() throws {
        let scratch = try Scratch()
        let legacy = SessionStore.legacySidecarURL(for: scratch.track)
        try writeSession(state(playhead: 99_000), to: legacy)

        try scratch.store.save(state(playhead: 5), for: scratch.track)

        let current = SessionStore.sidecarURL(for: scratch.track)
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path), "the old file was deleted")
    }

    /// Content survives the migration rather than being reset to defaults —
    /// a save that "worked" but lost the loop would be the worst outcome here.
    @Test("the migrated session keeps what the old file said")
    func contentSurvivesMigration() throws {
        let scratch = try Scratch()
        try writeSession(
            state(playhead: 77_000), to: SessionStore.legacySidecarURL(for: scratch.track))

        let before = try #require(
            scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate))
        try scratch.store.save(
            before.restoration.state, for: scratch.track, preserving: before.original)

        // Re-read: the current extension now exists, so this reads the new file.
        let after = scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate)
        #expect(after?.location == .sidecar(SessionStore.sidecarURL(for: scratch.track)))
        #expect(after?.restoration.state.playhead == 77_000)
        #expect(after?.restoration.state.loop.range.start == 1000)
    }

    // MARK: - Save As… treats it as the user's own file

    /// `isCanonicalSidecar` answers "will reopening this track find this file",
    /// and for a legacy sidecar the answer is yes. Saying no would make Save As…
    /// treat the user's own session as a foreign export.
    @Test("a legacy sidecar still counts as canonical")
    func legacySidecarIsCanonical() throws {
        let scratch = try Scratch()
        #expect(
            SessionStore.isCanonicalSidecar(
                SessionStore.legacySidecarURL(for: scratch.track), for: scratch.track))
        #expect(
            SessionStore.isCanonicalSidecar(
                SessionStore.sidecarURL(for: scratch.track), for: scratch.track))
    }

    /// …but an unrelated file still is not, or Save As… would silently overwrite
    /// the sidecar whenever the user exported somewhere else.
    @Test("an unrelated file is still not canonical")
    func unrelatedFileIsNotCanonical() throws {
        let scratch = try Scratch()
        let elsewhere = scratch.root.appendingPathComponent("Exported.artscripture")
        #expect(!SessionStore.isCanonicalSidecar(elsewhere, for: scratch.track))
    }

    // MARK: - The Application Support fallback

    /// The fallback is keyed by a hash and lives in a folder named after the
    /// app, so the rename moved *both* halves. Sessions for tracks on read-only
    /// volumes are only reachable if the old folder is searched too.
    @Test("a session in the pre-rename Application Support folder is found")
    func legacyFallbackIsFound() throws {
        let scratch = try Scratch()
        let legacy = legacyFallbackURL(for: scratch.track, in: scratch.legacyFallback)
        try writeSession(state(playhead: 31_337), to: legacy)

        let read = scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate)
        #expect(read?.restoration.state.playhead == 31_337)
        #expect(read?.location == .applicationSupport(legacy))
    }

    /// A sidecar the user can see beats a hidden fallback, whichever extension
    /// each carries — the ordering the pre-rename store already had.
    @Test("a legacy sidecar still beats a current-extension fallback")
    func sidecarBeatsFallbackAcrossTheRename() throws {
        let scratch = try Scratch()
        try writeSession(
            state(playhead: 1), to: scratch.store.fallbackURL(for: scratch.track))
        try writeSession(
            state(playhead: 2), to: SessionStore.legacySidecarURL(for: scratch.track))

        let read = scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate)
        #expect(read?.restoration.state.playhead == 2)
    }

    /// An injected fallback directory means a test or the acceptance harness,
    /// neither of which has history to migrate — so no legacy directory is
    /// invented for them.
    @Test("an injected fallback directory gets no legacy search")
    func injectedDirectoryHasNoLegacy() throws {
        let scratch = try Scratch()
        let store = SessionStore(fallbackDirectory: scratch.legacyFallback)
        let stray = legacyFallbackURL(for: scratch.track, in: scratch.legacyFallback)
        try writeSession(state(playhead: 4), to: stray)

        // Same directory, but the legacy *extension* is not searched, so this
        // file is invisible to a store that was handed its own directory.
        #expect(store.existingLocation(for: scratch.track) == nil)
    }

    /// Mirrors the store's own hashing so the test names the file the way an
    /// older build would have.
    private func legacyFallbackURL(for track: URL, in directory: URL) -> URL {
        let key = track.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
            .appendingPathExtension(SessionStore.legacyFileExtension)
    }
}
