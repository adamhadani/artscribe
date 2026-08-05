import Playback

/// What the app does when the platform takes the audio away, and what it does
/// when it gives it back — a phone call, an alarm, Siri, another app claiming
/// the session, headphones pulled out of the socket.
///
/// iOS and iPadOS only in practice: on macOS the coordinator is
/// `UnmanagedAudioSession` and none of these ever fire. Nothing here is
/// platform-guarded even so, because a guarded handler is a handler no `make
/// check` can run — and this is code whose absence is invisible until a user
/// switches to Spotify and back.
///
/// The decision itself is not made here. `AudioSessionPolicy` makes it, down in
/// `Playback`, where it is a pure function over an event and one `Bool`; these
/// two methods are what the app *does* once it has been made.
extension ViewerModel {

    /// The platform stopped us. Make our own idea of "playing" agree.
    ///
    /// The graph is already stopped by the time this runs, so this is not about
    /// stopping anything — it is about the transport, the Playback menu's title
    /// and the lock screen all still saying "playing" over silence. That was the
    /// whole of the reported bug: background the app, let Spotify take the
    /// session, come back, and the button still offered to pause.
    ///
    /// `pause()` and not merely a flag, for two reasons. It sets the latch, which
    /// is what every surface reads. And it pushes `.setPlaying(false)` into the
    /// command ring, which matters even though nothing is draining it: the
    /// engine's own flag is still `true` from before the interruption, and a
    /// route change that rebuilds and restarts the graph
    /// (`handleConfigurationChange`) would find it set and start playing again on
    /// its own, with nobody having asked.
    func audioWasInterrupted() {
        pause()
    }

    /// The interruption is over and both halves of the rule hold: the user was
    /// playing when it began, and the system says resuming is appropriate — it
    /// says so for a timer, and withholds it for a phone call.
    ///
    /// Deliberately *not* `togglePlayPause()`, which would be the shorter line
    /// and is a trap: it resumes only because the transport happens to read
    /// paused, so any path that left the latch set would silently turn this
    /// resume into a pause. A resume asks to play.
    ///
    /// It does go through the preroll, though, because this is the exact case
    /// preroll exists for — resuming from a position the user did not choose.
    /// They were listening when the phone rang; a couple of seconds of run-up is
    /// what lets them pick the passage back up.
    func audioMayResume() {
        guard hasTrack else { return }
        resumeWithPreroll()
    }

    /// The wiring an interruption travels down, as one value.
    ///
    /// Internal and named rather than written inline at its one call site, so a
    /// test can drive **the object the app actually builds** instead of a
    /// look-alike assembled in the test file. That distinction is the point: the
    /// bug this fixes was never in any of the three behaviours, all of which were
    /// tested. It was that nothing connected them.
    ///
    /// Every closure holds the model weakly. The model owns the session, the
    /// session owns the output, and the output holds this — so a strong capture
    /// here is a cycle that outlives the document.
    func makeTransportLink() -> TransportLink {
        TransportLink(
            isPlaying: { [weak self] in self?.transport.isPlaying ?? false },
            onInterrupted: { [weak self] in self?.audioWasInterrupted() },
            onResumeRequested: { [weak self] in self?.audioMayResume() })
    }
}
