import ArtscribeKit
import AudioDecode
import Foundation
import Waveform

@testable import ArtscribeUI

/// A scratch folder, a track file in it, and a `SessionStore` whose fallback
/// lives outside that folder — shared by every session test.
///
/// Nothing here touches the user's real Application Support and nothing
/// survives the test: the whole tree goes in `deinit`, with the track's folder
/// made writable again first so the read-only test cannot leave a directory
/// that nothing can remove.
final class SessionScratch {
    let root: URL
    /// The track's own folder, which the read-only test makes unwritable. The
    /// fallback deliberately lives outside it, exactly as the real one lives in
    /// Application Support rather than beside the music.
    let tracks: URL
    let track: URL
    let store: SessionStore

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("artscribe-model-session-\(UUID().uuidString)")
        tracks = root.appendingPathComponent("tracks")
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        track = tracks.appendingPathComponent("Blackbird.flac")
        try Data([0]).write(to: track)
        store = SessionStore(fallbackDirectory: root.appendingPathComponent("fallback"))
    }

    deinit {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tracks.path)
        try? FileManager.default.removeItem(at: root)
    }
}

enum SessionTestModel {
    static let sampleRate: Double = 44100
    static let totalFrames: FrameIndex = 441_000  // 10 s

    /// A model with a track loaded and a scratch store attached, in exactly the
    /// state `open(url:)` would leave it — including the sidecar restore.
    @MainActor
    static func make(_ scratch: SessionScratch) -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: sampleRate, frameCount: totalFrames, storage: storage)
        let model = ViewerModel()
        model.attach(sessions: scratch.store)
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        model.adoptSession(for: scratch.track)
        return model
    }

    /// The stored session for a scratch track, read back through the store.
    @MainActor
    static func read(_ scratch: SessionScratch) -> SessionRead? {
        scratch.store.load(
            for: scratch.track, frameCount: totalFrames, sampleRate: sampleRate)
    }
}
