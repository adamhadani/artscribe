import ArtscribeKit
import AudioDecode
import Foundation
import Waveform

/// Opening a file: the async decode pipeline, its progress reporting, and what
/// a finished, cancelled or failed load does to the model.
///
/// Split out of `ViewerModel` to keep that file inside the project's 400-line
/// limit, alongside the extensions for interaction, playback, nudging,
/// rendering and selection. The stored state it works on — `loadTask` and
/// `loadToken` — has to stay on the class, because Swift has no stored
/// properties in extensions.
extension ViewerModel {

    public func open(url: URL) {
        // **Nothing is written here, deliberately.** Opening a track is not an
        // edit, and this method used to flush the outgoing session at exactly
        // this point — which meant reopening a track rewrote its sidecar
        // *before* reading it, destroying any hand edit. The sidecar is a
        // visible, hand-editable file by design (spec §2), so that was data
        // loss, and it was reported by the user.
        //
        // Leaving a session behind is still handled, one level up:
        // `SessionPrompt.whenSafeToLeave` runs before every UI route into this
        // method and saves or asks as the case requires. The open path itself is
        // strictly read-only.
        loadTask?.cancel()
        errorMessage = nil
        isLoading = true
        progress = 0
        loadPhase = .opening
        let started = Date()
        loadToken += 1
        let token = loadToken
        let reporter = ProgressReporter { [weak self] value in
            Task { @MainActor in self?.reportProgress(value, token: token) }
        }

        // Detached, not a plain `Task`: a detached task never inherits the main
        // actor, so the decode and the pyramid build are guaranteed to run off
        // it no matter how nonisolated-async inheritance is configured. The
        // decoder polls `Task.isCancelled`, so cancelling this stops it early.
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let loaded = try await TrackLoader.load(
                    url: url, reporter: reporter,
                    onPhaseChange: { phase in
                        Task { @MainActor in self?.setPhase(phase, token: token) }
                    })
                try Task.checkCancellation()
                await self?.adopt(loaded, url: url, startedAt: started, token: token)
            } catch is CancellationError {
                await self?.cancelLoading(token: token)
            } catch DecodeError.cancelled {
                await self?.cancelLoading(token: token)
            } catch {
                await self?.fail(with: TrackLoader.message(for: error), token: token)
            }
        }
    }

    public func dismissError() {
        errorMessage = nil
    }

    func reportProgress(_ value: Double, token: Int) {
        guard token == loadToken else { return }
        progress = value
        // The decoder only calls back once it is actually reading chunks, so
        // this is the genuine boundary between "opening" and "decoding".
        loadPhase = .decoding
    }

    func setPhase(_ phase: LoadPhase, token: Int) {
        guard token == loadToken else { return }
        loadPhase = phase
    }

    func adopt(_ loaded: LoadedTrack, url: URL, startedAt: Date, token: Int) {
        guard token == loadToken else { return }
        teardownSession()
        audio = loaded.audio
        pyramid = loaded.pyramid
        fileName = url.lastPathComponent
        generation += 1
        selection.clear()
        // Speed and engine deliberately survive a load — they are a working
        // preference, not a property of the file — but the loop cannot: its
        // frames mean nothing in a different recording.
        loop = LoopRegion()
        playhead = 0
        reachedEnd = false
        isLoading = false
        progress = 1
        loadPhase = nil
        viewport = Viewport(totalFrames: loaded.audio.frameCount, widthPixels: lanePointWidth)
        // Only on success: a file that could not be decoded is not somewhere you
        // want to be offered a shortcut back to.
        recents?.note(url)
        // Spec §7, and it has to happen *here* — after the audio is in place, so
        // everything read from the sidecar is clamped against the recording's
        // real length, and before the graph is built, because `openSession`
        // constructs the stretcher for `speed.engine` and pushes `speed`'s time
        // ratio. Anything a sidecar sets after that point would be a rebuild.
        adoptSession(for: url)
        refresh()
        openSession(for: loaded.audio)
        // The two the graph cannot pick up from `speed` alone.
        applyRestoredSession()
        // Measured through to the rasterised bitmap, not just the decode, so the
        // readout answers "how long until I saw the waveform" (spec §1.2).
        lastLoadSeconds = Date().timeIntervalSince(startedAt)
    }

    func cancelLoading(token: Int) {
        guard token == loadToken else { return }
        isLoading = false
        loadPhase = nil
    }

    /// The decode failed. The previously loaded track is deliberately left
    /// untouched — a failed open must not throw away what you were working on.
    func fail(with message: String, token: Int) {
        guard token == loadToken else { return }
        isLoading = false
        loadPhase = nil
        errorMessage = message
    }
}
