import ArtscribeKit
import Foundation
import Testing

@testable import ArtscribeUI

/// The `.artscribe` sidecar on disk (spec §7): where it goes, what it contains,
/// what happens when the directory refuses it, and — at length — what happens
/// when somebody has been editing it by hand.
@Suite("Session sidecar store")
struct SessionStoreTests {

    private let frames: FrameIndex = 2_000_000
    private let rate: Double = 44_100

    /// A scratch directory that cleans itself up, plus a store whose fallback
    /// lives inside it. Nothing here touches the user's real Application
    /// Support, and nothing survives the test.
    private final class Scratch {
        let root: URL
        let fallback: URL
        let store: SessionStore
        let track: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("artscribe-session-tests-\(UUID().uuidString)")
            let tracks = root.appendingPathComponent("tracks")
            fallback = root.appendingPathComponent("fallback")
            try FileManager.default.createDirectory(
                at: tracks, withIntermediateDirectories: true)
            store = SessionStore(fallbackDirectory: fallback)
            track = tracks.appendingPathComponent("Blackbird.flac")
            try Data([0]).write(to: track)
        }

        deinit {
            // Restore write permission first: a read-only-directory test would
            // otherwise leave a directory nothing can remove.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("tracks").path
            )
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func state(
        ratio: Double = 0.6, loop: FrameRange = FrameRange(start: 1000, count: 44_100),
        enabled: Bool = true, playhead: FrameIndex = 12_345
    ) -> SessionState {
        SessionState(
            speed: SpeedState(ratio: ratio, engine: .fast),
            loop: LoopRegion(range: loop, isEnabled: enabled),
            viewport: ViewportState(startFrame: 500, framesPerPixel: 128),
            playhead: playhead,
            track: TrackIdentity(sampleRate: rate, frameCount: frames))
    }

    // MARK: - Where it goes

    @Test("the sidecar sits next to the track, named after the whole file name")
    func sidecarSitsBesideTheTrack() throws {
        let scratch = try Scratch()
        let sidecar = SessionStore.sidecarURL(for: scratch.track)
        #expect(sidecar.deletingLastPathComponent() == scratch.track.deletingLastPathComponent())
        #expect(sidecar.lastPathComponent == "Blackbird.flac.artscribe")
    }

    /// The reason the extension is appended rather than replaced: a transcriber
    /// routinely has the same song as both a lossless master and a phone-sized
    /// copy in one folder, and `Blackbird.artscribe` would make one silently
    /// overwrite the other's loop points.
    @Test("two encodings of one song get two sidecars")
    func differentEncodingsDoNotCollide() throws {
        let scratch = try Scratch()
        let mp3 = scratch.track.deletingLastPathComponent()
            .appendingPathComponent("Blackbird.mp3")
        #expect(SessionStore.sidecarURL(for: scratch.track) != SessionStore.sidecarURL(for: mp3))
    }

    @Test("the fallback is keyed by the track's path and is stable across calls")
    func fallbackKeyIsStable() throws {
        let scratch = try Scratch()
        let first = scratch.store.fallbackURL(for: scratch.track)
        let second = scratch.store.fallbackURL(for: scratch.track)
        #expect(first == second)
        #expect(first.deletingLastPathComponent().path == scratch.fallback.path)
        // Not the track's own name: two tracks called `01 Intro.flac` in
        // different albums must not share one stored session.
        let other = scratch.track.deletingLastPathComponent()
            .appendingPathComponent("elsewhere/Blackbird.flac")
        #expect(scratch.store.fallbackURL(for: other) != first)
    }

    // MARK: - Round trip

    @Test("a saved session reads back identically")
    func roundTripThroughDisk() throws {
        let scratch = try Scratch()
        let saved = try scratch.store.save(state(), for: scratch.track)
        #expect(saved.location == .sidecar(SessionStore.sidecarURL(for: scratch.track)))
        #expect(!saved.fellBack)

        let read = try #require(
            scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate))
        #expect(read.restoration.state == state())
        #expect(read.restoration.repairs.isEmpty)
        #expect(read.failure == nil)
    }

    @Test("the JSON is the shape a person could edit")
    func jsonIsReadable() throws {
        let scratch = try Scratch()
        _ = try scratch.store.save(state(), for: scratch.track)
        let text = try String(
            contentsOf: SessionStore.sidecarURL(for: scratch.track), encoding: .utf8)
        for key in [
            "schemaVersion", "track", "sampleRate", "frameCount", "speed", "ratio", "engine",
            "loop", "range", "start", "count", "isEnabled", "viewport", "startFrame",
            "framesPerPixel", "playhead"
        ] {
            #expect(text.contains("\"\(key)\""), "missing key \(key)")
        }
        // Pretty-printed and sorted, so a diff of two sessions is readable and a
        // hand edit does not have to be made inside one enormous line.
        #expect(text.contains("\n"))
        #expect(text.hasSuffix("\n"))
    }

    @Test("no sidecar means no session, not an error")
    func absentFileIsNotAFailure() throws {
        let scratch = try Scratch()
        #expect(scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate) == nil)
        #expect(scratch.store.existingLocation(for: scratch.track) == nil)
    }

    @Test("a saved session is found again by existingLocation")
    func existingLocationFindsTheSidecar() throws {
        let scratch = try Scratch()
        _ = try scratch.store.save(state(), for: scratch.track)
        #expect(
            scratch.store.existingLocation(for: scratch.track)
                == .sidecar(SessionStore.sidecarURL(for: scratch.track)))
    }

    // MARK: - Corrupt input
    //
    // The file is user-editable by design, so these are ordinary inputs.

    private func writeSidecar(_ text: String, in scratch: Scratch) throws {
        try Data(text.utf8).write(to: SessionStore.sidecarURL(for: scratch.track))
    }

    @Test(
        "deliberately corrupt sidecars degrade to defaults rather than crashing",
        arguments: [
            // Truncated mid-write — the file was being written when the machine
            // slept, or the volume filled up.
            "{\"schemaVersion\":1,\"speed\":{\"ratio\":0.5,",
            // Not JSON at all.
            "this is not json",
            // Empty file.
            "",
            // Valid JSON, wrong shape.
            "[1, 2, 3]",
            "null",
            "\"just a string\"",
            "42"
        ])
    func malformedJsonDegradesSafely(text: String) throws {
        let scratch = try Scratch()
        try writeSidecar(text, in: scratch)
        let read = try #require(
            scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate))
        // It says so — spec §8, never degrade silently.
        #expect(read.failure != nil)
        // And it degrades to something the app can actually run on.
        #expect(read.restoration.state.speed == SpeedState())
        #expect(read.restoration.state.loop == LoopRegion())
        #expect(read.restoration.state.playhead == 0)
    }

    @Test(
        "hand-edited nonsense inside well-formed JSON is clamped and reported",
        arguments: [
            // A zero ratio: an infinite time ratio inside Rubber Band.
            #"{"schemaVersion":1,"speed":{"ratio":0,"engine":"studio"}}"#,
            // A negative ratio.
            #"{"schemaVersion":1,"speed":{"ratio":-4,"engine":"studio"}}"#,
            // Wrong types throughout.
            #"{"schemaVersion":"one","speed":"fast","loop":true,"playhead":"middle"}"#,
            // A loop past the end of the recording.
            #"{"schemaVersion":1,"loop":{"range":{"start":99999999999,"count":5}}}"#,
            // A loop of negative length.
            #"{"schemaVersion":1,"loop":{"range":{"start":10,"count":-99},"isEnabled":true}}"#,
            // Int64 overflow in the loop's end.
            #"""
            {"schemaVersion":1,"loop":{"range":{"start":9223372036854775807,\
            "count":9223372036854775807},"isEnabled":true}}
            """#,
            // A playhead beyond the file.
            #"{"schemaVersion":1,"playhead":99999999999999}"#,
            // An unknown engine name.
            #"{"schemaVersion":1,"speed":{"ratio":0.5,"engine":"telepathy"}}"#,
            // A future schema.
            #"{"schemaVersion":9999,"playhead":10}"#,
            // Every key missing.
            "{}"
        ])
    func handEditedNonsenseIsClamped(text: String) throws {
        let scratch = try Scratch()
        try writeSidecar(text.replacingOccurrences(of: "\\\n", with: ""), in: scratch)
        let read = try #require(
            scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate))
        let restored = read.restoration.state
        // Whatever it says, what comes out is inside every invariant the running
        // app depends on.
        #expect(restored.speed.ratio >= SpeedState.minRatio)
        #expect(restored.speed.ratio <= SpeedState.maxRatio)
        #expect(restored.speed.timeRatio.isFinite)
        #expect(restored.loop.range.start >= 0)
        #expect(restored.loop.range.count >= 0)
        #expect(restored.loop.range.end <= frames)
        #expect(restored.playhead >= 0)
        #expect(restored.playhead <= frames)
        #expect(restored.viewport.startFrame >= 0)
        #expect(restored.viewport.startFrame <= frames)
        #expect(restored.viewport.framesPerPixel.isFinite)
        // And the user is told it was not read as written.
        #expect(!read.restoration.repairs.isEmpty || read.failure != nil)
    }

    /// The one that matters most: a mistyped `loop` must not cost you the speed
    /// you also set, and vice versa.
    @Test("one damaged field does not take the others with it")
    func damageIsIsolatedPerField() throws {
        let scratch = try Scratch()
        try writeSidecar(
            #"""
            {"schemaVersion":1,
             "speed":{"ratio":0.5,"engine":"fast"},
             "loop":"oops",
             "viewport":{"startFrame":9,"framesPerPixel":32},
             "playhead":4321}
            """#, in: scratch)
        let read = try #require(
            scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate))
        #expect(read.restoration.state.speed == SpeedState(ratio: 0.5, engine: .fast))
        #expect(read.restoration.state.playhead == 4321)
        #expect(read.restoration.state.viewport.framesPerPixel == 32)
        #expect(read.restoration.repairs == [.loop])
    }

    @Test("a sidecar for a different-length recording still restores, clamped and flagged")
    func sidecarForAnotherRecording() throws {
        let scratch = try Scratch()
        _ = try scratch.store.save(state(), for: scratch.track)
        let read = try #require(
            scratch.store.load(for: scratch.track, frameCount: 5000, sampleRate: rate))
        #expect(read.restoration.repairs.contains(.trackIdentity))
        #expect(read.restoration.state.playhead <= 5000)
        #expect(read.restoration.state.loop.range.end <= 5000)
    }

    // MARK: - The read-only fallback (spec §7)

    @Test("a read-only directory falls back to Application Support, and says so")
    func readOnlyDirectoryFallsBack() throws {
        let scratch = try Scratch()
        let directory = scratch.track.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        let saved = try scratch.store.save(state(), for: scratch.track)
        #expect(
            saved.location == .applicationSupport(scratch.store.fallbackURL(for: scratch.track)))
        #expect(saved.fellBack)
        // Never silent: the reason the sidecar could not be written is carried
        // out, not swallowed.
        #expect(saved.reason != nil)
        #expect(FileManager.default.fileExists(atPath: saved.location.url.path))
        // And no half-written file was left beside the track.
        #expect(
            !FileManager.default.fileExists(
                atPath: SessionStore.sidecarURL(for: scratch.track).path))
    }

    @Test("a session stored in the fallback is found and loaded again")
    func fallbackIsLoadedBack() throws {
        let scratch = try Scratch()
        try scratch.store.write(state(), to: scratch.store.fallbackURL(for: scratch.track))
        #expect(
            scratch.store.existingLocation(for: scratch.track)
                == .applicationSupport(scratch.store.fallbackURL(for: scratch.track)))
        let read = try #require(
            scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate))
        #expect(read.location == .applicationSupport(scratch.store.fallbackURL(for: scratch.track)))
        #expect(read.restoration.state == state())
    }

    /// The sidecar wins. If a track's folder became writable again and a sidecar
    /// was written there, that is the newer, portable, shareable copy the user
    /// deliberately chose (spec §2), and the stale fallback must not shadow it.
    @Test("a real sidecar takes precedence over a stored fallback")
    func sidecarBeatsFallback() throws {
        let scratch = try Scratch()
        try scratch.store.write(
            state(ratio: 2.0, playhead: 1), to: scratch.store.fallbackURL(for: scratch.track))
        _ = try scratch.store.save(state(ratio: 0.5, playhead: 999), for: scratch.track)
        let read = try #require(
            scratch.store.load(for: scratch.track, frameCount: frames, sampleRate: rate))
        #expect(read.restoration.state.playhead == 999)
    }

    @Test("saving into a writable directory again leaves the fallback behind")
    func writableDirectoryPrefersTheSidecar() throws {
        let scratch = try Scratch()
        try scratch.store.write(state(), to: scratch.store.fallbackURL(for: scratch.track))
        let saved = try scratch.store.save(state(), for: scratch.track)
        #expect(!saved.fellBack)
        #expect(saved.location == .sidecar(SessionStore.sidecarURL(for: scratch.track)))
    }

    // MARK: - Save As

    @Test("Save As writes wherever it is pointed")
    func saveAsWritesAnywhere() throws {
        let scratch = try Scratch()
        let chosen = scratch.root.appendingPathComponent("shared-loops.artscribe")
        try scratch.store.write(state(), to: chosen)
        #expect(FileManager.default.fileExists(atPath: chosen.path))
    }

    /// The consequence a user has to be told about: a session file that is not
    /// named after its track, next to its track, is not the one reopening finds.
    @Test("only the canonical path is the one reopening will find")
    func canonicalPathIsTheOneThatReloads() throws {
        let scratch = try Scratch()
        let canonical = SessionStore.sidecarURL(for: scratch.track)
        #expect(SessionStore.isCanonicalSidecar(canonical, for: scratch.track))
        #expect(
            !SessionStore.isCanonicalSidecar(
                scratch.root.appendingPathComponent("elsewhere.artscribe"), for: scratch.track))
        // Compared after standardising, so `/tmp/…` and `/private/tmp/…` are one
        // path rather than two.
        let noisy = canonical.deletingLastPathComponent()
            .appendingPathComponent("./\(canonical.lastPathComponent)")
        #expect(SessionStore.isCanonicalSidecar(noisy, for: scratch.track))
    }
}
