import ArtscribeKit
import Foundation

/// The remote commands this app answers. Deliberately not every command
/// `MPRemoteCommandCenter` offers — an enabled command with no handler is a
/// button that does nothing.
public enum NowPlayingRemoteCommand: CaseIterable, Sendable {
    case play
    case pause
    case toggle
    case skipBackward
    case skipForward
}

/// What pressing one should do to the model.
///
/// **Every case is resolved**: there is no `.toggle` here, though there is one in
/// `NowPlayingRemoteCommand`, because iOS really does send that command. Which of
/// play and pause it means is a decision, and a decision resolved in the adapter
/// is a decision nothing can test — `NowPlayingController` is the one file that
/// does not compile on the platform the unit suite runs on.
public enum NowPlayingAction: Equatable, Sendable {
    case play
    case pause
    /// Back to the top of the passage — the app's `restartLoop`, which `F` also
    /// invokes.
    case restartLoop
    case seek(FrameIndex)
    /// No track, so nothing to do.
    case none
}

/// Both lock-screen decisions, as pure functions.
public enum NowPlayingPolicy {

    /// Whether `current` is worth telling the system about.
    ///
    /// The system extrapolates position between updates from
    /// `(elapsed, rate, timestamp)`, so ordinary forward motion needs no
    /// message at all — and the display link that drives this polls sixty times
    /// a second. What does need one is any change it cannot predict: a
    /// different track, speed, loop, ramp or transport state, the playhead
    /// moving *backwards*, or a **seek**.
    ///
    /// A seek is the one that cannot be read off the playhead. Forwards, a
    /// ten-second skip and 16 ms of playback are the same pair of numbers, so
    /// inferring the discontinuity from the direction of travel silently
    /// swallows every forward seek — and the system then keeps extrapolating
    /// from the pre-skip anchor, leaving the displayed elapsed exactly the skip
    /// amount behind the audio, for good, and twice that after a second press.
    /// `NowPlayingSnapshot.seekGeneration` makes the jump explicit, which is why
    /// there is no branch for it here: forward motion holds every other field
    /// equal, and a seek does not.
    public static func shouldPublish(
        previous: NowPlayingSnapshot?, current: NowPlayingSnapshot
    ) -> Bool {
        guard let previous else { return true }
        if previous.playhead > current.playhead { return true }
        var predicted = previous
        predicted.playhead = current.playhead
        return predicted != current
    }

    /// What a button means, given what the app is doing.
    ///
    /// `skipSeconds` is the app's coarse "Rewind / skip" amount, passed in
    /// rather than read here so that changing it in Settings changes the lock
    /// screen and there is no second number to keep in sync.
    public static func action(
        for command: NowPlayingRemoteCommand, snapshot: NowPlayingSnapshot,
        skipSeconds: Double
    ) -> NowPlayingAction {
        guard snapshot.trackURL != nil else { return .none }
        switch command {
        case .play: return .play
        case .pause: return .pause
        // Resolved here rather than in the adapter, on the app's own idea of
        // what the transport is doing — `ViewerModel.isPlaying` is the latch the
        // user set, not `PlaybackEngine.isPlaying`.
        case .toggle: return snapshot.isPlaying ? .pause : .play
        case .skipBackward:
            // Inside a fenced-off passage, "back ten seconds" lands outside it.
            // The useful blind action is "again, from the top".
            if snapshot.loop.isActive { return .restartLoop }
            return .seek(target(in: snapshot, bySeconds: -skipSeconds))
        case .skipForward:
            return .seek(target(in: snapshot, bySeconds: skipSeconds))
        }
    }

    /// Reuses the keyboard's own stepping, so a lock-screen skip and a `⌥Z`
    /// land in the same place and the saturation and clamping have one
    /// implementation.
    private static func target(
        in snapshot: NowPlayingSnapshot, bySeconds seconds: Double
    ) -> FrameIndex {
        NudgeStepping.target(
            from: snapshot.playhead, bySeconds: seconds, sampleRate: snapshot.sampleRate,
            totalFrames: snapshot.totalFrames)
    }
}
