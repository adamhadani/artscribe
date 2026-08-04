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
    /// Counts deliberate jumps of the playhead, so a *seek* is distinguishable
    /// from playback having advanced to the same frame.
    ///
    /// Without it the two are the same snapshot, and `shouldPublish` — which
    /// must stay silent for ordinary forward motion — cannot tell them apart:
    /// a ten-second skip forward would be folded into the extrapolation the
    /// system is already doing and the lock screen's clock would sit exactly
    /// that far behind the audio, permanently. `ViewerModel.seek(to:)` is the
    /// single path a user seek takes, so one counter there covers the lock
    /// screen's own ⟳, `⌥X`, a nudge and a click on the waveform alike.
    public var seekGeneration: Int
    public var totalFrames: FrameIndex
    public var sampleRate: Double
    public var speedRatio: Double
    public var isPlaying: Bool
    public var loop: LoopRegion
    public var practice: NowPlayingPractice

    public init(
        trackURL: URL? = nil, playhead: FrameIndex = 0, seekGeneration: Int = 0,
        totalFrames: FrameIndex = 0, sampleRate: Double = 0, speedRatio: Double = 1,
        isPlaying: Bool = false, loop: LoopRegion = LoopRegion(),
        practice: NowPlayingPractice = NowPlayingPractice()
    ) {
        self.trackURL = trackURL
        self.playhead = playhead
        self.seekGeneration = seekGeneration
        self.totalFrames = totalFrames
        self.sampleRate = sampleRate
        self.speedRatio = speedRatio
        self.isPlaying = isPlaying
        self.loop = loop
        self.practice = practice
    }
}

/// Reading the app.
///
/// Deliberately **not** inside `NowPlayingController`, which is the one file in
/// this feature that does not compile on the platform the unit suite runs on.
/// Every field here is a wire between the model and a decision, and a wire that
/// only exists on iOS is a wire no `make check` can see break — `seekGeneration`
/// in particular, whose whole purpose is to make `shouldPublish` fire, and which
/// would otherwise be provable only by hand on a device.
extension NowPlayingSnapshot {

    @MainActor
    init(of model: ViewerModel) {
        self.init(
            trackURL: model.hasTrack ? model.trackURL : nil,
            playhead: model.playhead,
            seekGeneration: model.seekGeneration,
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
        guard snapshot.loop.isActive else { return speed }
        let start = TimeCode.coarse(
            frames: snapshot.loop.range.start, sampleRate: snapshot.sampleRate)
        let end = TimeCode.coarse(
            frames: snapshot.loop.range.start + snapshot.loop.range.count,
            sampleRate: snapshot.sampleRate)
        return "\(speed) · looping \(start)–\(end)"
    }
}
