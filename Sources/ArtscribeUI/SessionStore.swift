import ArtscribeKit
import CryptoKit
import Foundation

/// Where a track's session ended up.
public enum SessionLocation: Equatable, Sendable, Hashable {
    /// The `<track>.artscripture` file next to the audio, which is what spec §7
    /// asks for and what §2 chose it for: portable, shareable, and obvious.
    case sidecar(URL)
    /// The consolation prize when the track's folder will not take a file — a
    /// read-only volume, a mounted image, a NAS share with no write access.
    /// Keyed by the track's path, invisible, and **always surfaced**, because a
    /// session the user cannot see or move is only acceptable if they know it is
    /// what they have.
    case applicationSupport(URL)

    public var url: URL {
        switch self {
        case .sidecar(let url), .applicationSupport(let url): return url
        }
    }

    /// True when this is the file reopening the track will find on its own.
    public var isBesideTheTrack: Bool {
        if case .sidecar = self { return true }
        return false
    }
}

/// Why a sidecar on disk could not be taken at face value.
public enum SessionReadFailure: Equatable, Sendable {
    /// The bytes could not be read at all — permissions, a vanished volume.
    case unreadable(String)
    /// The bytes are not a session: truncated mid-write, not JSON, or JSON of
    /// the wrong shape.
    case malformed(String)

    public var message: String {
        switch self {
        case .unreadable(let detail): return detail
        case .malformed(let detail): return detail
        }
    }
}

/// One read of a track's stored session.
public struct SessionRead: Equatable, Sendable {
    public var restoration: SessionRestoration
    public var location: SessionLocation
    /// Non-`nil` when the file existed but could not be understood. The
    /// `restoration` is still usable — it is the default session — so the app
    /// opens the track normally and says what happened, rather than refusing to
    /// open it or pretending the defaults were the user's choice.
    public var failure: SessionReadFailure?
    /// The bytes exactly as they were on disk, so a later save can lay
    /// Artscripture's own keys over them instead of replacing the file. See
    /// `SessionStore.merged(ours:into:)`.
    public var original: Data?
}

/// The outcome of writing a session.
public struct SessionSave: Equatable, Sendable {
    public var location: SessionLocation
    /// True when the sidecar could not be written and the fallback was used.
    public var fellBack: Bool
    /// Why, when it fell back. Carried out rather than logged, because spec §7
    /// requires the fallback be surfaced.
    public var reason: String?
    /// The bytes that were written, which become the next write's baseline —
    /// they already carry whatever was preserved from the file before them.
    public var contents: Data
}

/// Reads and writes the `.artscripture` sidecar (spec §7).
///
/// A plain value with no state of its own beyond where the fallback lives,
/// following `RecentFiles` and `NudgeSettings`: the store is the tape, and the
/// live session is on `ViewerModel`.
public struct SessionStore: Sendable {

    public static let fileExtension = "artscripture"

    /// The extension written before the app was renamed.
    ///
    /// **Read, never written.** Sessions saved by an earlier build sit beside
    /// their audio as `<track>.artscribe`, and those files are the user's — a
    /// rename of the *app* is no reason for their loop points to disappear. So
    /// `existingLocation` looks for one when the canonical name is absent, and a
    /// subsequent save writes the new name and **leaves the old file alone**.
    ///
    /// Not deleted, deliberately. Removing a file the user can see, to tidy up
    /// after our own rename, is a bigger liberty than leaving one stale file
    /// behind; and because the save path carries the bytes it read through
    /// `preserving:`, nothing in it is lost.
    public static let legacyFileExtension = "artscribe"

    /// Where the read-only-volume fallback goes. Injectable so tests and the
    /// acceptance harness get their own directory rather than writing into the
    /// user's real Application Support — the same arrangement `NudgeSettings`
    /// and `ThemeController` use for `UserDefaults`.
    private let fallbackDirectory: URL

    /// The pre-rename fallback directory, for the same reason as
    /// `legacyFileExtension`. `nil` when the caller injected a directory, since
    /// a test or the harness has no history to migrate.
    private let legacyFallbackDirectory: URL?

    public init(fallbackDirectory: URL? = nil, legacyFallbackDirectory: URL? = nil) {
        self.fallbackDirectory = fallbackDirectory ?? Self.applicationSupport("Artscripture")
        self.legacyFallbackDirectory =
            legacyFallbackDirectory
            ?? (fallbackDirectory == nil ? Self.applicationSupport("Artscribe") : nil)
    }

    private static func applicationSupport(_ folder: String) -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("\(folder)/Sessions", isDirectory: true)
    }

    // MARK: - Paths

    /// `Blackbird.flac` → `Blackbird.flac.artscripture`.
    ///
    /// The extension is **appended, not replaced**. Replacing it reads better —
    /// `Blackbird.artscripture` — but a transcriber routinely keeps a lossless
    /// master and a smaller copy of the same song in one folder, and one
    /// `Blackbird.artscripture` between `Blackbird.flac` and `Blackbird.mp3` means
    /// whichever you opened last silently overwrites the other's loop points.
    /// Silent loss of loop points is the exact failure spec §7 exists to
    /// prevent, so the uglier name wins.
    public static func sidecarURL(for track: URL) -> URL {
        track.appendingPathExtension(fileExtension)
    }

    /// The same path under the pre-rename extension. Read-only; see
    /// `legacyFileExtension`.
    public static func legacySidecarURL(for track: URL) -> URL {
        track.appendingPathExtension(legacyFileExtension)
    }

    /// Whether a chosen path *is* the sidecar this track reloads from — the
    /// question **Save As…** turns on.
    ///
    /// **Either extension counts.** The question is "will reopening this track
    /// pick this file up again", and a `.artscribe` file left by an older build
    /// still will. Answering `false` for one would make Save As… treat the
    /// user's own session file as a foreign export.
    public static func isCanonicalSidecar(_ url: URL, for track: URL) -> Bool {
        let chosen = url.standardizedFileURL.resolvingSymlinksInPath()
        return [sidecarURL(for: track), legacySidecarURL(for: track)]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .contains(chosen)
    }

    /// Keyed by the track's full path, hashed.
    ///
    /// SHA-256 of the standardised path rather than Swift's `hashValue`, which
    /// is seeded per process and would hand the same track a different file on
    /// every launch. The name is not meant to be readable — the readable copy is
    /// the sidecar, and this only exists when the sidecar is impossible.
    public func fallbackURL(for track: URL) -> URL {
        Self.fallbackURL(for: track, in: fallbackDirectory, extension: Self.fileExtension)
    }

    private static func fallbackURL(
        for track: URL, in directory: URL, extension ext: String
    ) -> URL {
        let key = track.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// Where this track's session already is, if anywhere.
    ///
    /// Four places, in order of preference: the sidecar wins over the fallback
    /// because a folder that has become writable again holds the copy the user
    /// can see, and the current extension wins over the pre-rename one because
    /// if both exist the current one is the more recent save.
    public func existingLocation(for track: URL) -> SessionLocation? {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }

        let sidecar = Self.sidecarURL(for: track)
        if exists(sidecar) { return .sidecar(sidecar) }
        let legacySidecar = Self.legacySidecarURL(for: track)
        if exists(legacySidecar) { return .sidecar(legacySidecar) }

        let fallback = fallbackURL(for: track)
        if exists(fallback) { return .applicationSupport(fallback) }
        if let legacyDirectory = legacyFallbackDirectory {
            let legacy = Self.fallbackURL(
                for: track, in: legacyDirectory, extension: Self.legacyFileExtension)
            if exists(legacy) { return .applicationSupport(legacy) }
        }
        return nil
    }

    // MARK: - Reading

    /// The stored session for a track, or `nil` when there is none.
    ///
    /// - Parameters:
    ///   - frameCount: the length of the recording actually loaded. Everything
    ///     read is clamped against it — see `SessionState.restoring`.
    ///   - sampleRate: likewise, and used to report a mismatch.
    public func load(
        for track: URL, frameCount: FrameIndex, sampleRate: Double
    ) -> SessionRead? {
        guard let location = existingLocation(for: track) else { return nil }
        return read(at: location, frameCount: frameCount, sampleRate: sampleRate)
    }

    public func read(
        at location: SessionLocation, frameCount: FrameIndex, sampleRate: Double
    ) -> SessionRead {
        let defaults = SessionState.restoring(
            SessionFile(), frameCount: frameCount, sampleRate: sampleRate)
        // A file that exists but says nothing is not a restoration; it is a
        // failure that happens to have a usable answer. `repairs` is cleared so
        // the user is told one thing — "this file could not be read" — instead
        // of five field-level complaints about a file that had no fields.
        func failed(_ failure: SessionReadFailure, original: Data?) -> SessionRead {
            SessionRead(
                restoration: SessionRestoration(state: defaults.state, repairs: []),
                location: location, failure: failure, original: original)
        }

        let data: Data
        do {
            data = try Data(contentsOf: location.url)
        } catch {
            return failed(.unreadable(error.localizedDescription), original: nil)
        }
        do {
            let file = try JSONDecoder().decode(SessionFile.self, from: data)
            return SessionRead(
                restoration: SessionState.restoring(
                    file, frameCount: frameCount, sampleRate: sampleRate),
                location: location, failure: nil, original: data)
        } catch {
            // The bytes are carried out even here. Merging into them will fail
            // (they are not an object), so a save replaces them — which is the
            // only option — but a caller that wants to show or back them up has
            // them rather than having to read the file a second time.
            return failed(.malformed(Self.describe(error)), original: data)
        }
    }

    /// Decoding errors read like compiler diagnostics; this is what the user is
    /// shown, so it says which of the two things went wrong in their terms.
    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted:
            return "it is not valid JSON, or it was truncated while being written"
        case .typeMismatch, .valueNotFound, .keyNotFound:
            return "it is JSON, but not a session"
        @unknown default:
            return "it could not be read"
        }
    }

    // MARK: - Writing

    /// Writes a session next to its track, falling back to Application Support
    /// when the track's folder will not take it (spec §7).
    ///
    /// Throws only when **both** fail, which means the session genuinely cannot
    /// be stored anywhere; the caller turns that into something the user sees.
    @discardableResult
    public func save(
        _ state: SessionState, for track: URL, preserving previous: Data? = nil
    ) throws -> SessionSave {
        let sidecar = Self.sidecarURL(for: track)
        do {
            let contents = try write(state, to: sidecar, preserving: previous)
            return SessionSave(
                location: .sidecar(sidecar), fellBack: false, reason: nil, contents: contents)
        } catch {
            // Deliberately not pre-checked with `isWritableFile`: that answers a
            // question about POSIX permissions, and the ways a directory refuses
            // a file here also include a full volume, an immutable flag, a
            // disconnected share and a sandbox. Attempting the write is the only
            // check that covers all of them.
            let fallback = fallbackURL(for: track)
            let contents = try write(state, to: fallback, preserving: previous)
            return SessionSave(
                location: .applicationSupport(fallback), fellBack: true,
                reason: error.localizedDescription, contents: contents)
        }
    }

    /// Lays the keys Artscripture owns over the ones that were already in the file.
    ///
    /// The sidecar is hand-editable by design (spec §2 chose a visible file over
    /// a hidden one precisely so it could be read, edited and shared), so a save
    /// must not silently delete a note somebody typed into it — or a field a
    /// newer build wrote that this one does not know about yet. Anything not in
    /// `ours` is left exactly as it was found.
    ///
    /// Recurses into objects that appear in both, so an unknown key nested
    /// inside a `loop` Artscripture does own survives too. On a type clash — the
    /// file says `"loop": "chorus"` and we hold an object — **ours wins**, since
    /// the alternative is an app that cannot save its own state.
    static func merged(ours: [String: Any], into theirs: [String: Any]) -> [String: Any] {
        var result = theirs
        for (key, value) in ours {
            let ourObject = value as? [String: Any]
            let theirObject = result[key] as? [String: Any]
            if let ourObject, let theirObject {
                result[key] = merged(ours: ourObject, into: theirObject)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// One write, to one place. Used by `save` for both of its destinations and
    /// by **Save As…** for a path the user chose.
    ///
    /// - Parameter previous: the bytes this session was read from, if any.
    ///   Artscripture's keys are laid over them, so anything in the file that is
    ///   not ours survives. Bytes that are not a JSON object are ignored — there
    ///   is nothing to merge into — and the file is replaced.
    /// - Returns: exactly what was written, which is the baseline for the next
    ///   write.
    @discardableResult
    public func write(
        _ state: SessionState, to url: URL, preserving previous: Data? = nil
    ) throws -> Data {
        let directory = url.deletingLastPathComponent()
        // Only for a directory we own. Creating one beside the user's music
        // would be presumptuous, and `Data.write` reports the real reason it
        // could not when the folder is missing.
        // Compared by path, not by `URL`: `deletingLastPathComponent()` leaves a
        // trailing slash and `URL` equality counts that as a different location,
        // which silently skipped this and left `Data.write` with nowhere to put
        // its temporary file.
        if directory.standardizedFileURL.path == fallbackDirectory.standardizedFileURL.path {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        var object = try Self.jsonObject(of: state)
        if let previous, let theirObject = Self.jsonObject(of: previous) {
            object = Self.merged(ours: object, into: theirObject)
        }
        // The file is meant to be opened in a text editor (spec §7, §2), so it
        // is formatted for one: indented, keys in a stable order so two sessions
        // diff cleanly, and a trailing newline so it is a well-formed text file.
        //
        // Serialised rather than encoded, on both paths, so a merged file and a
        // fresh one come out in the same shape. `JSONEncoder` cannot emit keys
        // it has no type for, which is the whole point of the merge.
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        // Atomic: the failure this whole feature exists to prevent is losing
        // loop points, and a debounced autosave interrupted mid-write is exactly
        // how that happens. The temporary file lands in the same directory, so a
        // read-only folder still fails here rather than half-succeeding.
        try data.write(to: url, options: .atomic)
        return data
    }

    /// Bytes as a JSON object, or `nil` when they are not one. `nil` is the
    /// ordinary answer for a truncated or hand-mangled sidecar, and it means
    /// there is nothing to preserve — a save replaces the file.
    private static func jsonObject(of data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The session as a JSON object, via `JSONEncoder` so every value still goes
    /// through the `Codable` conformances rather than being assembled by hand.
    private static func jsonObject(of state: SessionState) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(state.fileRepresentation)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
            // Unreachable: `SessionFile` is a struct and encodes to an object.
            // Answered rather than trapped, because this runs on a save.
            return [:]
        }
        return object
    }
}
