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
@MainActor
public final class NowPlayingController {

    /// What was last handed to the info centre, so an unchanged snapshot costs
    /// nothing. See `NowPlayingPolicy.shouldPublish`.
    private var published: NowPlayingSnapshot?

    /// Set once. `MPRemoteCommandCenter` handlers accumulate — registering on
    /// every update would leave one press invoking the action many times.
    private var registered = false

    /// The one instance. `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` are
    /// process-global, so their owner is too: a second controller would pass its
    /// own `registered` guard and add a second handler to the same command,
    /// making one button press fire twice. iPadOS creates a `DocumentView` per
    /// scene, so "one per view" is not the same as "one per process".
    public static let shared = NowPlayingController()

    private init() {}

    /// Called from the same poll that already drives the playhead readout.
    /// Cheap on the overwhelming majority of calls: it builds a snapshot,
    /// compares, and returns.
    public func update(from model: ViewerModel) {
        register(model)
        let snapshot = Self.snapshot(of: model)
        guard NowPlayingPolicy.shouldPublish(previous: published, current: snapshot) else {
            return
        }
        published = snapshot
        publish(NowPlayingInfo(snapshot))
    }

    /// A closed track must not leave the previous one on the lock screen.
    public func clear() {
        published = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Reading the model

    private static func snapshot(of model: ViewerModel) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            trackURL: model.hasTrack ? model.trackURL : nil,
            playhead: model.playhead,
            totalFrames: model.totalFrames,
            sampleRate: model.sampleRate,
            speedRatio: model.speed.ratio,
            isPlaying: model.isPlaying,
            loop: model.loop,
            practice: NowPlayingPractice(
                isRunning: model.ramp.isRunning,
                repetition: model.ramp.repetition,
                total: model.ramp.total))
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

    private func register(_ model: ViewerModel) {
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

        handle(centre.playCommand, .play, model)
        handle(centre.pauseCommand, .pause, model)
        handle(centre.togglePlayPauseCommand, .toggle, model)
        handle(centre.skipBackwardCommand, .skipBackward, model)
        handle(centre.skipForwardCommand, .skipForward, model)
    }

    private func handle(
        _ command: MPRemoteCommand, _ which: NowPlayingRemoteCommand, _ model: ViewerModel
    ) {
        command.isEnabled = true
        // The interval iOS draws inside the skip glyph. The app's own coarse
        // "Rewind / skip" amount, so changing it in Settings changes the lock
        // screen and there is no second number to keep in sync.
        if let skip = command as? MPSkipIntervalCommand {
            skip.preferredIntervals = [NSNumber(value: model.prefs.nudgeAmounts[.coarse])]
        }
        command.addTarget { [weak self, weak model] _ in
            guard let self, let model else { return .noSuchContent }
            return self.perform(which, on: model)
        }
    }

    private func perform(
        _ command: NowPlayingRemoteCommand, on model: ViewerModel
    ) -> MPRemoteCommandHandlerStatus {
        let snapshot = Self.snapshot(of: model)
        let action = NowPlayingPolicy.action(
            for: command, snapshot: snapshot,
            skipSeconds: model.prefs.nudgeAmounts[.coarse])
        switch action {
        case .play: model.play()
        case .pause: model.pause()
        case .toggle:
            if snapshot.isPlaying { model.pause() } else { model.play() }
        case .restartLoop: model.restartLoop()
        case .seek(let frame): model.seek(to: frame)
        case .none: return .noSuchContent
        }
        update(from: model)
        return .success
    }
}
#endif
