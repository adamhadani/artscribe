import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// What a locked screen says about the app.
///
/// Every branch is a pure function of a snapshot, which is the only reason any
/// of this can be checked on a Mac — the surface it drives exists only on iOS.
@Suite("Now Playing info")
struct NowPlayingInfoTests {

    /// 44.1 kHz, a two-minute track, playhead at one minute.
    private func snapshot(
        speedRatio: Double = 1.0,
        isPlaying: Bool = true,
        loop: LoopRegion = LoopRegion(),
        practice: NowPlayingPractice = NowPlayingPractice(),
        playhead: FrameIndex = 2_646_000,
        totalFrames: FrameIndex = 5_292_000,
        url: URL? = URL(fileURLWithPath: "/tmp/Black Codes.flac")
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            trackURL: url, playhead: playhead, totalFrames: totalFrames,
            sampleRate: 44100, speedRatio: speedRatio, isPlaying: isPlaying,
            loop: loop, practice: practice)
    }

    // MARK: - Title

    @Test("the title is the file name without its extension")
    func titleDropsTheExtension() throws {
        let info = try #require(NowPlayingInfo(snapshot()))
        #expect(info.title == "Black Codes")
    }

    /// Only the *last* dot is an extension. `deletingPathExtension` gets this
    /// right and hand-rolled string splitting does not.
    @Test("a name containing dots keeps all but the extension")
    func titleKeepsInteriorDots() throws {
        let url = URL(fileURLWithPath: "/tmp/My.Song.v2.flac")
        let info = try #require(NowPlayingInfo(snapshot(url: url)))
        #expect(info.title == "My.Song.v2")
    }

    @Test("no track means nothing to publish")
    func noTrackIsNil() {
        #expect(NowPlayingInfo(snapshot(url: nil)) == nil)
    }

    // MARK: - Subtitle

    @Test("plain playback reports only the speed")
    func subtitleAtFullSpeed() throws {
        let info = try #require(NowPlayingInfo(snapshot()))
        #expect(info.subtitle == "100%")
    }

    @Test("a slowed track reports its speed")
    func subtitleSlowed() throws {
        let info = try #require(NowPlayingInfo(snapshot(speedRatio: 0.5)))
        #expect(info.subtitle == "50%")
    }

    /// The two facts a locked screen cannot otherwise convey.
    @Test("an enabled loop reports its bounds")
    func subtitleLooping() throws {
        let loop = LoopRegion(
            range: FrameRange(start: 3_660_300, count: 176_400), isEnabled: true)
        let info = try #require(NowPlayingInfo(snapshot(speedRatio: 0.5, loop: loop)))
        #expect(info.subtitle == "50% · looping 01:23–01:27")
    }

    /// **A loop region exists with `isEnabled == false`.** Reading the range
    /// without checking the flag is the plausible bug, and it would announce a
    /// loop the user had switched off.
    @Test("a disabled loop is not announced")
    func subtitleIgnoresADisabledLoop() throws {
        let loop = LoopRegion(
            range: FrameRange(start: 3_660_300, count: 176_400), isEnabled: false)
        let info = try #require(NowPlayingInfo(snapshot(loop: loop)))
        #expect(info.subtitle == "100%")
    }

    /// A ramp always runs on a loop, so printing both would say the same thing
    /// twice in a field with room for one line.
    @Test("a running practice ramp supersedes the loop")
    func subtitlePractising() throws {
        let loop = LoopRegion(
            range: FrameRange(start: 3_660_300, count: 176_400), isEnabled: true)
        let practice = NowPlayingPractice(isRunning: true, repetition: 4, total: 12)
        let info = try #require(
            NowPlayingInfo(snapshot(speedRatio: 0.65, loop: loop, practice: practice)))
        #expect(info.subtitle == "65% · practice, rep 4 of 12")
    }

    @Test("a stopped ramp falls back to the loop")
    func subtitleIgnoresAStoppedRamp() throws {
        let loop = LoopRegion(
            range: FrameRange(start: 3_660_300, count: 176_400), isEnabled: true)
        let practice = NowPlayingPractice(isRunning: false, repetition: 4, total: 12)
        let info = try #require(NowPlayingInfo(snapshot(loop: loop, practice: practice)))
        #expect(info.subtitle == "100% · looping 01:23–01:27")
    }

    // MARK: - The rate, which is the one that fails visibly

    /// **The trap.** The system extrapolates position from
    /// `(elapsed, rate, timestamp)`. Publishing 1.0 while playing at half speed
    /// makes the lock-screen timer run at twice the true rate and visibly
    /// outrun the audio — the speed-ratio-versus-time-ratio mistake in a new
    /// place. It must be the *speed* ratio, never its reciprocal.
    @Test("the published rate is the real playback rate")
    func rateIsTheSpeedRatio() throws {
        let half = try #require(NowPlayingInfo(snapshot(speedRatio: 0.5)))
        #expect(half.rate == 0.5, "publishing 1.0 here makes the timer outrun the audio")

        let full = try #require(NowPlayingInfo(snapshot(speedRatio: 1.0)))
        #expect(full.rate == 1.0)

        let double = try #require(NowPlayingInfo(snapshot(speedRatio: 2.0)))
        #expect(double.rate == 2.0, "2.0 would be the time ratio, which is 0.5")
    }

    @Test("a paused track publishes a rate of zero")
    func rateIsZeroWhenPaused() throws {
        let info = try #require(NowPlayingInfo(snapshot(speedRatio: 0.5, isPlaying: false)))
        #expect(info.rate == 0)
    }

    // MARK: - Position

    @Test("elapsed and duration are seconds")
    func positionInSeconds() throws {
        let info = try #require(NowPlayingInfo(snapshot()))
        #expect(abs(info.elapsed - 60) < 0.001)
        #expect(abs(info.duration - 120) < 0.001)
    }

    /// A playhead past the end publishes a nonsense scrubber otherwise.
    @Test("elapsed clamps to the track")
    func elapsedClamps() throws {
        let past = try #require(NowPlayingInfo(snapshot(playhead: 9_999_999)))
        #expect(abs(past.elapsed - 120) < 0.001)

        let before = try #require(NowPlayingInfo(snapshot(playhead: -100)))
        #expect(before.elapsed == 0)
    }

    /// A sample rate of zero is what a half-loaded track reports. Dividing by it
    /// yields infinity or NaN, and a non-finite number in the info dictionary is
    /// undefined behaviour on the far side.
    @Test("an unusable sample rate publishes zeroes rather than infinities")
    func zeroSampleRateIsSafe() throws {
        let snapshot = NowPlayingSnapshot(
            trackURL: URL(fileURLWithPath: "/tmp/a.flac"), playhead: 100,
            totalFrames: 200, sampleRate: 0, speedRatio: 1, isPlaying: true,
            loop: LoopRegion(), practice: NowPlayingPractice())
        let info = try #require(NowPlayingInfo(snapshot))
        #expect(info.elapsed == 0)
        #expect(info.duration == 0)
    }
}

/// The wire between the app and the two pure decisions.
///
/// `NowPlayingController` cannot be built on macOS, so if the model is only ever
/// read from inside it, nothing in `make check` can see that reading go wrong —
/// and the field this exists to protect, `seekGeneration`, is precisely one
/// whose absence is silent: the lock screen keeps working, and only its clock is
/// wrong, on a device, gradually.
@MainActor
@Suite("Now Playing snapshot")
struct NowPlayingSnapshotTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: Self.totalFrames,
            storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        // `loadForTesting` bypasses the loading pipeline, which is what sets
        // this — and the title comes from it, so without it every snapshot here
        // would report no track and the assertions below would all be vacuous.
        model.trackURL = URL(fileURLWithPath: "/tmp/Black Codes.flac")
        return model
    }

    /// **The end of the chain the critical bug ran down.** A skip forward from
    /// the lock screen's own ⟳ reaches `seek(to:)`, and if the snapshot cannot
    /// carry the discontinuity out again, `shouldPublish` sees nothing but a
    /// larger playhead and stays silent — leaving the system extrapolating from
    /// the pre-skip anchor for good.
    @Test("a forward seek on the model publishes; playing to the same frame does not")
    func aSeekReachesThePolicy() {
        let model = makeModel()
        model.seek(to: 44100)
        let before = NowPlayingSnapshot(of: model)

        model.seek(to: 220_500)
        let seeked = NowPlayingSnapshot(of: model)
        #expect(
            NowPlayingPolicy.shouldPublish(previous: before, current: seeked),
            "a forward seek must republish, or the lock-screen clock lags it for ever")

        // The control: the same distance, but as the poll would have written it.
        var played = before
        played.playhead = 220_500
        #expect(!NowPlayingPolicy.shouldPublish(previous: before, current: played))
    }

    @Test("the snapshot carries what the lock screen draws")
    func snapshotReadsTheModel() {
        let model = makeModel()
        model.seek(to: 88200)
        model.setLoopIn()
        model.seek(to: 176_400)
        model.setLoopOut()
        model.setSpeedPreset(0.5)

        let snapshot = NowPlayingSnapshot(of: model)
        #expect(snapshot.trackURL == model.trackURL)
        #expect(NowPlayingInfo(snapshot)?.title == "Black Codes")
        #expect(snapshot.playhead == model.playhead)
        #expect(snapshot.totalFrames == Self.totalFrames)
        #expect(snapshot.sampleRate == Self.sampleRate)
        #expect(snapshot.speedRatio == 0.5)
        #expect(snapshot.loop == model.loop)
        #expect(!snapshot.isPlaying)
    }

    /// A closed track must not leave the previous one on the lock screen, and
    /// `NowPlayingInfo` returning `nil` is how the controller is told to clear.
    @Test("a model with no track produces nothing to publish")
    func noTrackPublishesNothing() {
        let snapshot = NowPlayingSnapshot(of: ViewerModel())
        #expect(snapshot.trackURL == nil)
        #expect(NowPlayingInfo(snapshot) == nil)
    }
}
