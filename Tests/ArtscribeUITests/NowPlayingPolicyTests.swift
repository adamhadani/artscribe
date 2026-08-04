import ArtscribeKit
import Foundation
import Testing

@testable import ArtscribeUI

/// The two decisions behind the lock screen: when to tell the system anything,
/// and what its buttons mean.
@Suite("Now Playing policy")
struct NowPlayingPolicyTests {

    private let track = URL(fileURLWithPath: "/tmp/a.flac")

    private func snapshot(
        playhead: FrameIndex = 44100,
        loop: LoopRegion = LoopRegion(),
        isPlaying: Bool = true,
        speedRatio: Double = 1
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            trackURL: track, playhead: playhead, totalFrames: 4_410_000,
            sampleRate: 44100, speedRatio: speedRatio, isPlaying: isPlaying, loop: loop,
            practice: NowPlayingPractice())
    }

    /// Bars 12–16: one second in, two seconds long.
    private var enabledLoop: LoopRegion {
        LoopRegion(range: FrameRange(start: 44100, count: 88200), isEnabled: true)
    }

    // MARK: - When to publish

    @Test("the first snapshot is always published")
    func firstPublish() {
        #expect(NowPlayingPolicy.shouldPublish(previous: nil, current: snapshot()))
    }

    /// **The reason this function exists.** The display link polls the playhead
    /// sixty times a second; republishing at that rate would burn CPU telling
    /// the system something it extrapolates correctly by itself.
    @Test("the playhead advancing on its own is not worth republishing")
    func forwardMotionIsSilent() {
        let before = snapshot(playhead: 44100)
        let after = snapshot(playhead: 44200)
        #expect(!NowPlayingPolicy.shouldPublish(previous: before, current: after))
    }

    /// A loop wrap, or a seek backwards. Both are real jumps the system cannot
    /// predict, and without this the scrubber drifts further from the truth on
    /// every lap.
    @Test("the playhead jumping backwards is republished")
    func backwardJumpPublishes() {
        let before = snapshot(playhead: 132_300)
        let after = snapshot(playhead: 44100)
        #expect(NowPlayingPolicy.shouldPublish(previous: before, current: after))
    }

    @Test("pausing is republished")
    func pausePublishes() {
        #expect(
            NowPlayingPolicy.shouldPublish(
                previous: snapshot(isPlaying: true), current: snapshot(isPlaying: false)))
    }

    @Test("a speed change is republished")
    func speedPublishes() {
        #expect(
            NowPlayingPolicy.shouldPublish(
                previous: snapshot(speedRatio: 1), current: snapshot(speedRatio: 0.5)))
    }

    @Test("a loop change is republished")
    func loopPublishes() {
        #expect(
            NowPlayingPolicy.shouldPublish(
                previous: snapshot(), current: snapshot(loop: enabledLoop)))
    }

    @Test("an identical snapshot is not republished")
    func identicalIsSilent() {
        #expect(!NowPlayingPolicy.shouldPublish(previous: snapshot(), current: snapshot()))
    }

    // MARK: - What the buttons do

    @Test("play, pause and toggle map straight through")
    func transportCommands() {
        let now = snapshot()
        #expect(NowPlayingPolicy.action(for: .play, snapshot: now, skipSeconds: 10) == .play)
        #expect(NowPlayingPolicy.action(for: .pause, snapshot: now, skipSeconds: 10) == .pause)
        #expect(NowPlayingPolicy.action(for: .toggle, snapshot: now, skipSeconds: 10) == .toggle)
    }

    /// Inside a four-second loop a ten-second skip-back lands outside the
    /// passage the user deliberately fenced off. What they want without looking
    /// is "again, from the top".
    @Test("skip-back restarts an enabled loop")
    func skipBackRestartsTheLoop() {
        let now = snapshot(playhead: 100_000, loop: enabledLoop)
        #expect(
            NowPlayingPolicy.action(for: .skipBackward, snapshot: now, skipSeconds: 10)
                == .restartLoop)
    }

    /// **A loop region exists with `isEnabled == false`.** Treating that as a
    /// loop would hijack the button for a loop the user had switched off.
    @Test("skip-back seeks when the loop is disabled")
    func skipBackSeeksWithADisabledLoop() {
        let disabled = LoopRegion(range: FrameRange(start: 44100, count: 88200), isEnabled: false)
        let now = snapshot(playhead: 441_000, loop: disabled)
        #expect(
            NowPlayingPolicy.action(for: .skipBackward, snapshot: now, skipSeconds: 10)
                == .seek(0))
    }

    @Test("skip-back seeks by the skip amount when there is no loop")
    func skipBackSeeks() {
        // 20 s in, back 10 s at 44.1 kHz -> 10 s.
        let now = snapshot(playhead: 882_000)
        #expect(
            NowPlayingPolicy.action(for: .skipBackward, snapshot: now, skipSeconds: 10)
                == .seek(441_000))
    }

    /// Forward always leaves the loop — the asymmetry is deliberate.
    @Test("skip-forward seeks even inside a loop")
    func skipForwardAlwaysSeeks() {
        let now = snapshot(playhead: 44100, loop: enabledLoop)
        #expect(
            NowPlayingPolicy.action(for: .skipForward, snapshot: now, skipSeconds: 10)
                == .seek(485_100))
    }

    /// Clamping rather than refusing, exactly as the keyboard's rewind does.
    @Test("a seek clamps to the track at both ends")
    func seeksClamp() {
        let nearStart = snapshot(playhead: 1000)
        #expect(
            NowPlayingPolicy.action(for: .skipBackward, snapshot: nearStart, skipSeconds: 10)
                == .seek(0))

        let nearEnd = snapshot(playhead: 4_400_000)
        #expect(
            NowPlayingPolicy.action(for: .skipForward, snapshot: nearEnd, skipSeconds: 10)
                == .seek(4_410_000))
    }

    @Test("with no track every command does nothing")
    func noTrackIsInert() {
        let empty = NowPlayingSnapshot()
        for command in NowPlayingRemoteCommand.allCases {
            #expect(
                NowPlayingPolicy.action(for: command, snapshot: empty, skipSeconds: 10) == .none,
                "\(command) acted on a closed track")
        }
    }
}
