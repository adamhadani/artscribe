import ArtscribeKit

/// What a poll of the engine told us.
public enum TransportOutcome: Equatable, Sendable {
    /// Nothing to act on — including the window between asking to play and the
    /// render thread getting round to it.
    case unchanged
    /// The render thread confirmed it is playing.
    case started
    /// The engine stopped on its own: end of file with no loop.
    case finished
    /// The engine never confirmed the start. Something is wrong and the user has
    /// to be told; see `PlaybackEngine.renderStallCount`.
    case neverStarted
}

/// The UI's play/pause state, reconciled against the engine by polling.
///
/// It exists because `PlaybackEngine.isPlaying` is **not** observable until the
/// render thread has drained the command ring. Task 9's CLI read it immediately
/// after pushing `.setPlaying(true)`, saw `false`, and concluded playback had
/// ended before a single frame was rendered. The button therefore shows *intent*
/// until the engine has had a fair chance to answer, and only then follows it.
public struct TransportLatch: Equatable, Sendable {

    /// How long the engine gets to confirm a start before the UI calls it a
    /// failure. Generous next to a render quantum (a few milliseconds) and short
    /// enough that a dead audio graph does not masquerade as playback.
    public static let startTimeout: Double = 1.5

    /// What the user asked for. This, never `engine.isPlaying`, is what the
    /// button and the menu title reflect.
    public private(set) var isPlaying = false
    /// Whether the render thread has confirmed the current request.
    public private(set) var isConfirmed = false
    private var requestedAt: Double = 0

    public init() {}

    public mutating func request(_ playing: Bool, now: Double) {
        isPlaying = playing
        isConfirmed = false
        requestedAt = now
    }

    /// Called once per display-link tick with a fresh read of the engine.
    public mutating func poll(enginePlaying: Bool, now: Double) -> TransportOutcome {
        guard isPlaying else { return .unchanged }
        if enginePlaying {
            guard !isConfirmed else { return .unchanged }
            isConfirmed = true
            return .started
        }
        if isConfirmed {
            // Confirmed playing, now not: the engine ran out of source and
            // cleared its own flag. That is an end of file, not a stall.
            isPlaying = false
            isConfirmed = false
            return .finished
        }
        guard now - requestedAt > Self.startTimeout else { return .unchanged }
        // Reported exactly once: clearing `isPlaying` makes every later poll
        // return `.unchanged` through the guard at the top.
        isPlaying = false
        return .neverStarted
    }

    /// Where `play` has to seek before starting, or `nil` to resume in place.
    ///
    /// Pressing play at end of file with no loop makes `PlaybackEngine` restart
    /// the stream, immediately re-finalise it and clear the playing flag inside
    /// the *same* render call — so the button lights up and goes out again, and
    /// nothing is heard. Rewinding first turns that into the thing the user
    /// actually meant: play it again from the top of the selection.
    public static func rewindTarget(
        playhead: FrameIndex, totalFrames: FrameIndex, reachedEnd: Bool, loopActive: Bool,
        selectionStart: FrameIndex?
    ) -> FrameIndex? {
        // An active loop wraps by itself; the engine handles it and a rewind
        // would throw away the position inside the loop.
        guard !loopActive else { return nil }
        guard reachedEnd || playhead >= totalFrames else { return nil }
        return selectionStart ?? 0
    }
}

/// Turns the engine's reported position into the frame the listener is hearing
/// *right now*.
///
/// `PlaybackEngine.currentFrame` already compensates for the stretcher's own
/// backlog, but by construction it is the position at the end of the block the
/// render thread just produced — the remaining offset to the speaker belongs to
/// the output layer, which is the only part that knows the device buffering.
public enum PlayheadSync {

    public static func audibleFrame(
        engineFrame: FrameIndex, outputLatency: Double, sampleRate: Double, speedRatio: Double
    ) -> FrameIndex {
        guard outputLatency.isFinite, outputLatency > 0, sampleRate > 0, speedRatio > 0 else {
            return Swift.max(0, engineFrame)
        }
        // Source frames, not output frames: at half speed one second of device
        // latency is only half a second of the recording.
        let offset = outputLatency * sampleRate * speedRatio
        guard offset.isFinite, offset < Double(FrameIndex.max) else {
            return Swift.max(0, engineFrame)
        }
        return Swift.max(0, engineFrame - FrameIndex(offset.rounded()))
    }
}
