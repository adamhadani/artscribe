import ArtscribeKit
import Foundation
import Testing

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
