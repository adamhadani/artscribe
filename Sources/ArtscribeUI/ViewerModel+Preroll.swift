import ArtscribeKit

/// `Space`, and the preroll that makes a resume land slightly before where the
/// playhead stopped — spec §6.2's `transport.playPause` and `transport.preroll`.
///
/// Its own extension file rather than more of `ViewerModel+Playback`, which is
/// at the project's 400-line limit. `togglePlayPause` moved here with the
/// preroll because the two are one behaviour: the whole of what `Space` does now
/// lives in one place, and everything still goes out through `seek(to:)` and
/// `play()`, so there is no second path to the render thread.
extension ViewerModel {

    // MARK: - The key

    /// `Space`. Pauses if playing; otherwise resumes, one preroll earlier.
    ///
    /// Task 28 briefly made `Space` a play-from-start and `⇧Space` the toggle;
    /// the user drove that build and asked for this back, so a `Space` pressed
    /// while playing pauses again rather than restarting.
    public func togglePlayPause() {
        guard hasTrack else { return }
        if transport.isPlaying {
            pause()
            return
        }
        // Not before a play that cannot happen. With no audio session `play()`
        // raises a notice and returns, and moving the playhead for a resume that
        // never occurred would be a visible lie — pressed twice on a machine
        // with no output device it would walk backwards through a silent track.
        if session != nil {
            let target = prerollTarget
            if target != playhead { seek(to: target) }
        }
        play()
    }

    // MARK: - Where a resume starts

    /// The frame `Space` resumes from: the playhead, rolled back by
    /// `prerollSeconds` and clamped by `Preroll`.
    ///
    /// **Except at the end of the file**, where it stands aside. Parked on the
    /// end, `play()` rewinds to the selection start or to zero
    /// (`TransportLatch.rewindTarget`) because that press means "play it again";
    /// a preroll that first stepped back two seconds would cancel that rewind
    /// and play the last two seconds instead, which is a different action from
    /// the one this key has always had. That is the one part of the decision
    /// which is not arithmetic — it is a question about what `play()` will do
    /// next — which is why it lives here and not in `Preroll`.
    ///
    /// Internal rather than folded into `togglePlayPause` so it can be tested
    /// without an audio device; the keystroke itself is driven in the acceptance
    /// run's `playback` group, where there is a real graph.
    var prerollTarget: FrameIndex {
        let rewind = TransportLatch.rewindTarget(
            playhead: playhead, totalFrames: totalFrames, reachedEnd: reachedEnd,
            loopActive: loop.isActive,
            selectionStart: selection.isEmpty ? nil : selection.range.start)
        guard rewind == nil else { return playhead }
        return Preroll.target(
            from: playhead, seconds: prerollSeconds, sampleRate: sampleRate,
            totalFrames: totalFrames, loop: loop)
    }

    // MARK: - The preference

    /// Attaches the persistent store and adopts what it holds.
    ///
    /// Called once, from the app shell, and read *here* rather than in `init`
    /// for the reason `attach(nudge:)` records: a `ViewerModel` built by a unit
    /// test stays on the shipped default and never reads the user's real
    /// preferences.
    public func attach(preroll settings: PrerollSettings) {
        prerollStore = settings
        let loaded = settings.load()
        if loaded != prerollSeconds { prerollSeconds = loaded }
    }

    /// From the Settings window. Validated by `Preroll`, so a negative or an
    /// absurd value cannot get in — but a **zero can**, and means off (spec §8
    /// forbids degrading silently, not choosing to).
    public func setPrerollSeconds(_ seconds: Double) {
        applyPreroll(Preroll.validated(seconds))
    }

    /// Settings ▸ Restore Defaults: 2 s.
    public func restoreDefaultPreroll() {
        applyPreroll(Preroll.defaultSeconds)
    }

    private func applyPreroll(_ next: Double) {
        guard next != prerollSeconds else { return }
        prerollSeconds = next
        prerollStore?.save(next)
    }
}
