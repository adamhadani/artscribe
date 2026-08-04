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

    /// Opens a track.
    ///
    /// `securityScoped` says the caller has already called
    /// `startAccessingSecurityScopedResource()` on `url` and is **handing that
    /// access over**. The model holds it for as long as the file is the open
    /// document and releases it on the next open — which is the correct lifetime
    /// and was not what happened before.
    ///
    /// The iPad importer used to do this:
    ///
    ///     let scoped = url.startAccessingSecurityScopedResource()
    ///     defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    ///     ViewerActions.open(model, url: url)
    ///
    /// with a comment reasoning that "the decoder reads the whole file up
    /// front, so access is released as soon as `open` returns". The premise is
    /// false: `open` starts `loadTask` and returns immediately, so the `defer`
    /// fired *before* the decode read anything. It survived testing because a
    /// small local file is read faster than the release takes effect; a large
    /// track coming from a File Provider — iCloud Drive, Dropbox — is exactly
    /// where it would not.
    public func open(url: URL, securityScoped: Bool = false) {
        // Release the previous document's claim before taking a new one. Doing
        // it here rather than in a `deinit` matters: these are per-file grants
        // and the process is allowed a limited number of them.
        releaseSecurityScope()
        if securityScoped { scopedURL = url }
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

    /// Puts the track away and returns to the resting screen.
    ///
    /// **There was no way to do this at all.** `performClose` is about the
    /// *session* — writing the sidecar — and on macOS `⌘W` closes the window.
    /// On a phone there is one window and no exit, so opening a second recent
    /// file meant quitting the app. Reported.
    ///
    /// Deliberately the mirror of `adopt`, and written next to it so the two
    /// stay in step: anything that becomes a property of the open track has to
    /// be cleared here, and the compiler cannot say so.
    ///
    /// The scoped-resource grant goes too. It is per-file and the process is
    /// allowed a limited number of them, so holding one for a track that is no
    /// longer open is a leak with a hard ceiling.
    ///
    /// Speed, pitch and engine survive, exactly as they survive a *load*: they
    /// are a working preference rather than a property of the file. The loop and
    /// the selection do not — their frames mean nothing without a recording.
    public func closeTrack() {
        teardownSession()
        // Putting the track away must not leave it on the lock screen: the
        // window stays open (there is no exit on a phone — see the comment
        // above), so nothing else marks this moment. See `NowPlayingController`.
        #if !os(macOS)
        NowPlayingController.shared.clear()
        #endif
        releaseSecurityScope()
        loadTask?.cancel()
        loadToken += 1
        audio = nil
        pyramid = nil
        fileName = nil
        trackURL = nil
        generation += 1
        selection.clear()
        loop = LoopRegion()
        playhead = 0
        reachedEnd = false
        isLoading = false
        progress = 0
        loadPhase = nil
        errorMessage = nil
        viewport = Viewport(totalFrames: 0, widthPixels: lanePointWidth)
        markers.adopt(.none)
        cache.invalidate()
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
        // Before `adoptSession`, which may carry the user's own choice about
        // whether to show them: the sheet has to be read first so there is
        // something for that choice to apply to. Reading it is a few kilobytes
        // of text off the same directory the audio just came from, so it stays
        // on the main actor rather than earning a task of its own.
        markers.adopt(CueSheetLoader.load(besides: url, sampleRate: loaded.audio.sampleRate))
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
