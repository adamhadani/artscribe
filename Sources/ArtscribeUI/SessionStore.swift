import ArtscribeKit
import CryptoKit
import Foundation

/// Where a track's session ended up.
public enum SessionLocation: Equatable, Sendable, Hashable {
    /// The `<track>.artscribe` file next to the audio, which is what spec §7
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
}

/// The outcome of writing a session.
public struct SessionSave: Equatable, Sendable {
    public var location: SessionLocation
    /// True when the sidecar could not be written and the fallback was used.
    public var fellBack: Bool
    /// Why, when it fell back. Carried out rather than logged, because spec §7
    /// requires the fallback be surfaced.
    public var reason: String?
}

/// Reads and writes the `.artscribe` sidecar (spec §7).
///
/// A plain value with no state of its own beyond where the fallback lives,
/// following `RecentFiles` and `NudgeSettings`: the store is the tape, and the
/// live session is on `ViewerModel`.
public struct SessionStore: Sendable {

    public static let fileExtension = "artscribe"

    /// Where the read-only-volume fallback goes. Injectable so tests and the
    /// acceptance harness get their own directory rather than writing into the
    /// user's real Application Support — the same arrangement `NudgeSettings`
    /// and `ThemeController` use for `UserDefaults`.
    private let fallbackDirectory: URL

    public init(fallbackDirectory: URL? = nil) {
        self.fallbackDirectory = fallbackDirectory ?? Self.defaultFallbackDirectory()
    }

    private static func defaultFallbackDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Artscribe/Sessions", isDirectory: true)
    }

    // MARK: - Paths

    /// `Blackbird.flac` → `Blackbird.flac.artscribe`.
    ///
    /// The extension is **appended, not replaced**. Replacing it reads better —
    /// `Blackbird.artscribe` — but a transcriber routinely keeps a lossless
    /// master and a smaller copy of the same song in one folder, and one
    /// `Blackbird.artscribe` between `Blackbird.flac` and `Blackbird.mp3` means
    /// whichever you opened last silently overwrites the other's loop points.
    /// Silent loss of loop points is the exact failure spec §7 exists to
    /// prevent, so the uglier name wins.
    public static func sidecarURL(for track: URL) -> URL {
        track.appendingPathExtension(fileExtension)
    }

    /// Whether a chosen path *is* the sidecar this track reloads from — the
    /// question **Save As…** turns on.
    public static func isCanonicalSidecar(_ url: URL, for track: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath()
            == sidecarURL(for: track).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Keyed by the track's full path, hashed.
    ///
    /// SHA-256 of the standardised path rather than Swift's `hashValue`, which
    /// is seeded per process and would hand the same track a different file on
    /// every launch. The name is not meant to be readable — the readable copy is
    /// the sidecar, and this only exists when the sidecar is impossible.
    public func fallbackURL(for track: URL) -> URL {
        let key = track.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return
            fallbackDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(Self.fileExtension)
    }

    /// Where this track's session already is, if anywhere. The sidecar wins: a
    /// folder that has become writable again holds the copy the user can see.
    public func existingLocation(for track: URL) -> SessionLocation? {
        let sidecar = Self.sidecarURL(for: track)
        if FileManager.default.fileExists(atPath: sidecar.path) { return .sidecar(sidecar) }
        let fallback = fallbackURL(for: track)
        if FileManager.default.fileExists(atPath: fallback.path) {
            return .applicationSupport(fallback)
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
        func failed(_ failure: SessionReadFailure) -> SessionRead {
            SessionRead(
                restoration: SessionRestoration(state: defaults.state, repairs: []),
                location: location, failure: failure)
        }

        let data: Data
        do {
            data = try Data(contentsOf: location.url)
        } catch {
            return failed(.unreadable(error.localizedDescription))
        }
        do {
            let file = try JSONDecoder().decode(SessionFile.self, from: data)
            return SessionRead(
                restoration: SessionState.restoring(
                    file, frameCount: frameCount, sampleRate: sampleRate),
                location: location, failure: nil)
        } catch {
            return failed(.malformed(Self.describe(error)))
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
    public func save(_ state: SessionState, for track: URL) throws -> SessionSave {
        let sidecar = Self.sidecarURL(for: track)
        do {
            try write(state, to: sidecar)
            return SessionSave(location: .sidecar(sidecar), fellBack: false, reason: nil)
        } catch {
            // Deliberately not pre-checked with `isWritableFile`: that answers a
            // question about POSIX permissions, and the ways a directory refuses
            // a file here also include a full volume, an immutable flag, a
            // disconnected share and a sandbox. Attempting the write is the only
            // check that covers all of them.
            let fallback = fallbackURL(for: track)
            try write(state, to: fallback)
            return SessionSave(
                location: .applicationSupport(fallback), fellBack: true,
                reason: error.localizedDescription)
        }
    }

    /// One write, to one place. Used by `save` for both of its destinations and
    /// by **Save As…** for a path the user chose.
    public func write(_ state: SessionState, to url: URL) throws {
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
        let encoder = JSONEncoder()
        // The file is meant to be opened in a text editor (spec §7, §2), so it
        // is formatted for one: indented, keys in a stable order so two sessions
        // diff cleanly, and a trailing newline so it is a well-formed text file.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(state.fileRepresentation)
        data.append(0x0A)
        // Atomic: the failure this whole feature exists to prevent is losing
        // loop points, and a debounced autosave interrupted mid-write is exactly
        // how that happens. The temporary file lands in the same directory, so a
        // read-only folder still fails here rather than half-succeeding.
        try data.write(to: url, options: .atomic)
    }
}
