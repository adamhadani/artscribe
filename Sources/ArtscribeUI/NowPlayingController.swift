#if !os(macOS)
import ArtscribeKit
import Foundation
import MediaPlayer

/// Publishes what is playing to the lock screen and Control Centre, and answers
/// their buttons.
///
/// **iOS only, and that is a decision rather than a limitation.**
/// `MPRemoteCommandCenter` is claimed process-globally by whichever app
/// registered most recently, so a Mac build doing this would silently capture
/// the hardware media keys from whatever the user actually had playing. On the
/// Mac the window is already on screen and the app is keyboard-first; there is
/// nothing to solve.
///
/// **This type holds no policy.** What to say lives in `NowPlayingInfo`, when to
/// say it and what the buttons mean live in `NowPlayingPolicy`, and both are
/// pure and unit-tested on macOS — which is the only reason any of this is
/// checkable without a device. Resist adding a rule here; it belongs next to its
/// tests.
///
/// ## It is alive only because `PlayheadClock` survives a sleeping display
///
/// Everything below is driven by `tickPlayback`, which is driven by
/// `PlayheadClock` — and a `CADisplayLink` stops firing when the screen sleeps,
/// which is *precisely* when a lock screen exists. The clock watches its own
/// pulse and hands over to a 60 Hz timer after 250 ms of silence (see
/// `PlayheadClockPolicy`), and that standby path is what keeps the elapsed time
/// and the practice-rep subtitle moving on a locked iPad. Simplify it away and
/// this feature freezes on the frame the screen went dark, with the audio still
/// playing and nothing failing anywhere.
@MainActor
final class NowPlayingController {

    /// What was last handed to the info centre, so an unchanged snapshot costs
    /// nothing. See `NowPlayingPolicy.shouldPublish`.
    private var published: NowPlayingSnapshot?

    /// Set once. `MPRemoteCommandCenter` handlers accumulate — registering on
    /// every update would leave one press invoking the action many times.
    private var registered = false

    /// The skip interval iOS has been told to draw, so the comparison below
    /// costs nothing sixty times a second. `nil` until the first update.
    private var appliedSkipInterval: Double?

    /// The model the buttons act on, refreshed on every update rather than
    /// captured when the commands were registered.
    ///
    /// The handlers used to close over the model passed to `register`, which
    /// bound them to the first one they ever saw. That is correct today only
    /// because `IPadAppMain` keeps a single `ViewerModel` for the life of the
    /// process — an invariant asserted in a different file, by a type that has
    /// no idea this one depends on it. Weak, because a controller that outlives
    /// every window must not be what keeps a model alive.
    private weak var model: ViewerModel?

    /// The one instance. `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` are
    /// process-global, so their owner is too: a second controller would pass its
    /// own `registered` guard and add a second handler to the same command,
    /// making one button press fire twice. iPadOS creates a `DocumentView` per
    /// scene, so "one per view" is not the same as "one per process".
    static let shared = NowPlayingController()

    private init() {}

    /// Called from the same poll that already drives the playhead readout.
    /// Cheap on the overwhelming majority of calls: it builds a snapshot,
    /// compares, and returns.
    func update(from model: ViewerModel) {
        // Compared before assigning, like every other 60 Hz write in this
        // project: storing into a `weak` costs a side-table write, and this
        // runs on every display refresh for the life of the app.
        if self.model !== model { self.model = model }
        register()
        applySkipInterval(model.prefs.nudgeAmounts[.coarse])
        let snapshot = NowPlayingSnapshot(of: model)
        guard NowPlayingPolicy.shouldPublish(previous: published, current: snapshot) else {
            return
        }
        published = snapshot
        publish(NowPlayingInfo(snapshot))
    }

    /// A closed track must not leave the previous one on the lock screen.
    func clear() {
        published = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Publishing

    private func publish(_ info: NowPlayingInfo?) {
        guard let info else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.subtitle,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate
        ]
    }

    // MARK: - The buttons

    private func register() {
        guard !registered else { return }
        registered = true
        let centre = MPRemoteCommandCenter.shared()

        // Everything not handled is switched off explicitly. An enabled command
        // with no handler draws a button that does nothing.
        centre.changePlaybackPositionCommand.isEnabled = false
        centre.nextTrackCommand.isEnabled = false
        centre.previousTrackCommand.isEnabled = false
        centre.seekForwardCommand.isEnabled = false
        centre.seekBackwardCommand.isEnabled = false

        handle(centre.playCommand, .play)
        handle(centre.pauseCommand, .pause)
        handle(centre.togglePlayPauseCommand, .toggle)
        handle(centre.skipBackwardCommand, .skipBackward)
        handle(centre.skipForwardCommand, .skipForward)
    }

    /// The interval iOS draws *inside* the skip glyph — the `10` in `⟲10`.
    ///
    /// Rewritten whenever the app's coarse "Rewind / skip" amount changes, not
    /// once at registration: `perform` reads the amount live, so a lock screen
    /// set up on the first tick would go on drawing `⟲10` while skipping 5 for
    /// the rest of the process. Compared first, so at 60 Hz this is a `Double`
    /// comparison and nothing else.
    private func applySkipInterval(_ seconds: Double) {
        guard seconds != appliedSkipInterval else { return }
        appliedSkipInterval = seconds
        let intervals = [NSNumber(value: seconds)]
        let centre = MPRemoteCommandCenter.shared()
        centre.skipBackwardCommand.preferredIntervals = intervals
        centre.skipForwardCommand.preferredIntervals = intervals
    }

    private func handle(_ command: MPRemoteCommand, _ which: NowPlayingRemoteCommand) {
        command.isEnabled = true
        command.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            return self.perform(which)
        }
    }

    private func perform(_ command: NowPlayingRemoteCommand) -> MPRemoteCommandHandlerStatus {
        guard let model else { return .noSuchContent }
        let snapshot = NowPlayingSnapshot(of: model)
        let action = NowPlayingPolicy.action(
            for: command, snapshot: snapshot,
            skipSeconds: model.prefs.nudgeAmounts[.coarse])
        switch action {
        case .play:
            // Through `Space`'s own path, so a resume from the lock screen gets
            // the preroll every other resume gets — putting the iPad down and
            // picking it up again is the case that setting exists for. Guarded
            // because `togglePlayPause` is a *toggle*: iOS may send `play` to
            // something already playing, and that must not pause it.
            if !model.isPlaying { model.togglePlayPause() }
        case .pause: model.pause()
        case .restartLoop: model.restartLoop()
        case .seek(let frame):
            // At either end of the track the skip target clamps to the frame the
            // playhead is already on. `.seek` is one of the two paths that reset
            // the stretcher (CLAUDE.md on looping), and a lock-screen button can
            // be leant on blind, so the redundant one is guarded here exactly as
            // the nudge keys guard theirs.
            if frame != model.playhead { model.seek(to: frame) }
        case .none: return .noSuchContent
        }
        update(from: model)
        return .success
    }
}
#endif
