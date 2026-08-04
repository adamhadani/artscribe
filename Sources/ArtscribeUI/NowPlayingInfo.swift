import ArtscribeKit
import Foundation

/// Whether a practice ramp is running, and where it has got to.
///
/// A plain value rather than `SpeedRamp` itself: this type has to be
/// constructible in a test in one line, and it keeps the pure layer from
/// depending on the ramp's internals.
public struct NowPlayingPractice: Equatable, Sendable {
    public var isRunning: Bool
    public var repetition: Int
    public var total: Int

    public init(isRunning: Bool = false, repetition: Int = 0, total: Int = 0) {
        self.isRunning = isRunning
        self.repetition = repetition
        self.total = total
    }
}

/// What the app looks like at one instant, as far as a locked screen cares.
///
/// `Equatable` is not decoration — the controller compares consecutive
/// snapshots to decide whether a republish is warranted. See
/// `NowPlayingPolicy.shouldPublish`.
public struct NowPlayingSnapshot: Equatable, Sendable {
    public var trackURL: URL?
    public var playhead: FrameIndex
    public var totalFrames: FrameIndex
    public var sampleRate: Double
    public var speedRatio: Double
    public var isPlaying: Bool
    public var loop: LoopRegion
    public var practice: NowPlayingPractice

    public init(
        trackURL: URL? = nil, playhead: FrameIndex = 0, totalFrames: FrameIndex = 0,
        sampleRate: Double = 0, speedRatio: Double = 1, isPlaying: Bool = false,
        loop: LoopRegion = LoopRegion(), practice: NowPlayingPractice = NowPlayingPractice()
    ) {
        self.trackURL = trackURL
        self.playhead = playhead
        self.totalFrames = totalFrames
        self.sampleRate = sampleRate
        self.speedRatio = speedRatio
        self.isPlaying = isPlaying
        self.loop = loop
        self.practice = practice
    }
}

/// What to hand `MPNowPlayingInfoCenter`, computed and testable without it.
public struct NowPlayingInfo: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    /// Seconds, clamped to the track.
    public let elapsed: Double
    /// Seconds.
    public let duration: Double
    /// **The real playback rate**: the user-facing speed ratio while playing,
    /// zero while paused.
    ///
    /// The system extrapolates position between updates from
    /// `(elapsed, rate, timestamp)`, so a rate that disagrees with the audio
    /// makes the lock-screen timer drift away from what is being heard —
    /// quickly and visibly at 0.5×. This is `speed.ratio`, never `timeRatio`,
    /// which is its reciprocal.
    public let rate: Double

    /// `nil` when there is no track, which is also how the controller knows to
    /// clear the info centre rather than publish something stale.
    public init?(_ snapshot: NowPlayingSnapshot) {
        guard let url = snapshot.trackURL else { return nil }
        title = url.deletingPathExtension().lastPathComponent
        subtitle = Self.subtitle(for: snapshot)
        let durationValue = TimeCode.seconds(
            frames: snapshot.totalFrames, sampleRate: snapshot.sampleRate)
        duration = durationValue.isFinite ? durationValue : 0
        let positionValue = TimeCode.seconds(
            frames: snapshot.playhead, sampleRate: snapshot.sampleRate)
        let position = positionValue.isFinite ? positionValue : 0
        elapsed = Swift.max(0, Swift.min(position, duration))
        rate = snapshot.isPlaying ? snapshot.speedRatio : 0
    }

    /// Speed always; then the practice ramp if one is running, else the loop if
    /// one is enabled. Never both — a ramp always runs on a loop, so saying so
    /// twice wastes the only line there is.
    private static func subtitle(for snapshot: NowPlayingSnapshot) -> String {
        let speed = Readout.percent(snapshot.speedRatio)
        if snapshot.practice.isRunning {
            let practice = snapshot.practice
            return "\(speed) · practice, rep \(practice.repetition) of \(practice.total)"
        }
        guard snapshot.loop.isEnabled, snapshot.loop.range.count > 0 else { return speed }
        let start = TimeCode.coarse(
            frames: snapshot.loop.range.start, sampleRate: snapshot.sampleRate)
        let end = TimeCode.coarse(
            frames: snapshot.loop.range.start + snapshot.loop.range.count,
            sampleRate: snapshot.sampleRate)
        return "\(speed) · looping \(start)–\(end)"
    }
}
