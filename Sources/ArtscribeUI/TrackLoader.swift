import ArtscribeKit
import AudioDecode
import Foundation
import Synchronization
import Waveform

/// A decoded file and everything derived from it that the viewer needs.
///
/// `DecodedAudio` hands out raw pointers into its storage, so this value has to
/// stay alive for as long as anything draws from it — the model holds it.
struct LoadedTrack: Sendable {
    let audio: DecodedAudio
    let pyramid: PeakPyramid
}

/// Turns a file URL into a `LoadedTrack`, off the main actor.
enum TrackLoader {

    /// `nonisolated` so it never adopts the caller's actor: decoding a
    /// ten-minute file on the main actor would freeze the window for seconds.
    nonisolated static func load(url: URL, reporter: ProgressReporter) async throws -> LoadedTrack {
        let audio = try await AudioFileDecoder.decode(url: url, progress: reporter.callback)
        try Task.checkCancellation()
        return LoadedTrack(audio: audio, pyramid: PeakPyramid.build(audio))
    }

    /// The text the inline banner shows. `DecodeError` supplies a real reason;
    /// anything else at least gets its own description rather than a shrug.
    nonisolated static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Bridges the decoder's `@Sendable` progress callback onto the main actor
/// without spawning a hop per decoded chunk: only whole-percent changes are
/// forwarded, which is all the progress bar can show anyway.
final class ProgressReporter: Sendable {
    private let lastPercent = Mutex<Int>(-1)
    private let deliver: @Sendable (Double) -> Void

    init(deliver: @escaping @Sendable (Double) -> Void) {
        self.deliver = deliver
    }

    var callback: @Sendable (Double) -> Void {
        { [self] value in
            let percent = Int((value * 100).rounded())
            let shouldDeliver = lastPercent.withLock { stored -> Bool in
                guard percent != stored else { return false }
                stored = percent
                return true
            }
            if shouldDeliver { deliver(value) }
        }
    }
}
