import ArtscribeKit
import AudioDecode
import Foundation
import Observation
import Testing
import Waveform

@testable import ArtscribeUI

/// The transport, speed and loop actions as the keyboard and the menu invoke
/// them, driven straight against the model.
///
/// No audio device is opened here — `loadForTesting` deliberately leaves the
/// playback session nil — so these cover the half of the wiring that is pure
/// decision-making. The audible half is covered by `PlaybackTests` (offline
/// rendering) and by the acceptance run against real hardware.
@MainActor
@Suite("ViewerModel playback actions")
struct ViewerModelPlaybackTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    private func makeModel(frames: FrameIndex = Self.totalFrames) -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(frames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: frames,
            storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    // MARK: - Speed

    @Test("W and Q step the speed by five points, shifted by one")
    func speedKeys() {
        let model = makeModel()
        model.slower(fine: false)
        #expect(model.speed.ratio == 0.95)
        model.faster(fine: false)
        #expect(model.speed.ratio == 1.0)
        model.slower(fine: true)
        #expect(model.speed.ratio == 0.99)
        model.faster(fine: true)
        #expect(model.speed.ratio == 1.0)
    }

    @Test("the number keys select the presets")
    func speedPresets() {
        let model = makeModel()
        model.setSpeedPreset(0.5)
        #expect(model.speed.ratio == 0.5)
        // The one that matters for the listening check: half speed is a time
        // ratio of two, not a half.
        #expect(model.speed.timeRatio == 2.0)
        model.setSpeedPreset(0.33)
        #expect(model.speed.ratio == 0.33)
    }

    @Test("the engine toggle flips between studio and fast and back")
    func engineToggle() {
        let model = makeModel()
        #expect(model.speed.engine == .studio)
        model.toggleStretchEngine()
        #expect(model.speed.engine == .fast)
        model.toggleStretchEngine()
        #expect(model.speed.engine == .studio)
    }

    @Test("speed changes survive loading a different track")
    func speedSurvivesLoad() {
        let model = makeModel()
        model.setSpeedPreset(0.5)
        let storage = AudioStorage(channels: 1, capacityFrames: 1000)
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: 1000, storage: storage)
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio))
        #expect(model.speed.ratio == 0.5)
    }

    // MARK: - Volume

    @Test("the volume starts at half scale, not full")
    func volumeDefault() {
        #expect(makeModel().volume.level == 0.5)
    }

    @Test("the arrow keys step the volume, shifted a fifth of the distance")
    func volumeKeys() {
        let model = makeModel()
        model.volumeUp(fine: false)
        #expect(model.volume.level == 0.55)
        model.volumeDown(fine: false)
        #expect(model.volume.level == 0.5)
        model.volumeUp(fine: true)
        #expect(model.volume.level == 0.51)
        model.volumeDown(fine: true)
        #expect(model.volume.level == 0.5)
    }

    @Test("M mutes and restores the level it was at")
    func mute() {
        let model = makeModel()
        model.setVolumeLevel(0.72)
        model.toggleMute()
        #expect(model.volume.isMuted)
        #expect(model.volume.amplitude == 0)
        model.toggleMute()
        #expect(model.volume.amplitude == 0.72)
    }

    @Test("volume works with no track loaded, and survives loading one")
    func volumeIsIndependentOfTheTrack() {
        let model = ViewerModel()
        model.setVolumeLevel(0.2)
        #expect(model.volume.level == 0.2)

        let storage = AudioStorage(channels: 1, capacityFrames: 1000)
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: 1000, storage: storage)
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio))
        #expect(model.volume.level == 0.2)
    }

    /// The knob has width, so the usable travel is the track minus the knob.
    /// Mapping against the full width would leave both ends unreachable.
    @Test("the slider reaches both ends of its travel")
    func sliderMapping() {
        #expect(VolumeSliderView.level(atX: -20) == 0)
        #expect(VolumeSliderView.level(atX: 1000) == 1)
        #expect(abs(VolumeSliderView.level(atX: 92 / 2) - 0.5) < 0.02)
    }

    // MARK: - Loop

    @Test("A and S set the loop edges at the playhead")
    func loopEdges() {
        let model = makeModel()
        model.seek(to: 100_000)
        model.setLoopIn()
        model.seek(to: 200_000)
        model.setLoopOut()
        #expect(model.loop.range == FrameRange(start: 100_000, count: 100_000))
        #expect(!model.loop.isEnabled)
    }

    @Test("D toggles looping and G turns the selection into the loop region")
    func loopFromSelection() {
        let model = makeModel()
        model.dragChanged(startPixel: 100, currentPixel: 100, extending: false)
        model.dragChanged(startPixel: 100, currentPixel: 400, extending: false)
        let selected = model.selection.range

        model.loopFromSelection()
        #expect(model.loop.range == selected)
        #expect(!model.loop.isActive)

        model.toggleLoop()
        #expect(model.loop.isActive)
        model.toggleLoop()
        #expect(!model.loop.isActive)
    }

    @Test("F restarts the loop from its in point")
    func restartLoop() {
        let model = makeModel()
        model.seek(to: 100_000)
        model.setLoopIn()
        model.seek(to: 300_000)
        model.setLoopOut()
        model.seek(to: 250_000)
        model.restartLoop()
        #expect(model.playhead == 100_000)
    }

    @Test("F does nothing without a loop region rather than jumping to zero")
    func restartWithoutLoopHoldsPosition() {
        let model = makeModel()
        model.seek(to: 250_000)
        model.restartLoop()
        #expect(model.playhead == 250_000)
    }

    @Test("clearing the loop region turns looping off as well")
    func clearLoop() {
        let model = makeModel()
        model.selectAll()
        model.loopFromSelection()
        model.toggleLoop()
        #expect(model.loop.isActive)
        model.clearLoop()
        #expect(model.loop == LoopRegion())
    }

    @Test("a new track clears the loop")
    func loadClearsLoop() {
        let model = makeModel()
        model.selectAll()
        model.loopFromSelection()
        let storage = AudioStorage(channels: 1, capacityFrames: 1000)
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: 1000, storage: storage)
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio))
        #expect(model.loop == LoopRegion())
    }

    // MARK: - Transport

    @Test("Return goes to the selection start, or to zero when there is none")
    func returnToStart() {
        let model = makeModel()
        model.seek(to: 300_000)
        model.returnToStart()
        #expect(model.playhead == 0)

        model.dragChanged(startPixel: 200, currentPixel: 200, extending: false)
        model.dragChanged(startPixel: 200, currentPixel: 500, extending: false)
        let start = model.selection.range.start
        model.seek(to: 300_000)
        model.returnToStart()
        #expect(model.playhead == start)
    }

    @Test("seeking clamps into the file")
    func seekClamps() {
        let model = makeModel()
        model.seek(to: -5)
        #expect(model.playhead == 0)
        model.seek(to: Self.totalFrames * 4)
        #expect(model.playhead == Self.totalFrames)
    }

    /// Spec §8: never degrade silently. With no audio output there is nothing to
    /// play, and the transport must say so rather than latching to "playing" over
    /// silence.
    @Test("pressing play with no audio output reports it instead of pretending")
    func playWithoutOutputIsReported() {
        let model = makeModel()
        model.togglePlayPause()
        #expect(!model.isPlaying)
        #expect(model.playbackNotice != nil)
    }

    @Test("every playback action is a no-op with no track loaded")
    func noTrackIsANoOp() {
        let model = ViewerModel()
        model.togglePlayPause()
        model.setLoopIn()
        model.setLoopOut()
        model.toggleLoop()
        model.restartLoop()
        model.loopFromSelection()
        model.returnToStart()
        #expect(!model.isPlaying)
        #expect(model.loop == LoopRegion())
        #expect(model.playhead == 0)
    }

    // MARK: - The display-link poll and what it is allowed to invalidate

    /// The Output Device submenu regression, at the level it was actually caused.
    ///
    /// `TransportLatch.poll` is `mutating`, so polling the stored `transport` in
    /// place went through the `@Observable` macro's `_modify`, which notifies
    /// unconditionally. With a track loaded and paused, that invalidated every
    /// reader of `isPlaying` sixty-odd times a second, SwiftUI reapplied the
    /// Playback menu's items just as often, and AppKit's submenu-open delay never
    /// got to elapse: hovering "Output Device" opened nothing.
    ///
    /// Verified to fail against the defect: restoring the in-place
    /// `transport.poll(…)` makes this expectation report 1 invalidation, not 0.
    @Test("a poll that decides nothing does not invalidate the menu's observers")
    func idlePollDoesNotInvalidateObservers() {
        let model = makeModel()
        let counter = InvalidationCounter()
        withObservationTracking {
            _ = model.isPlaying
        } onChange: {
            MainActor.assumeIsolated { counter.bump() }
        }

        // Idle: not playing, so the latch has nothing to reconcile.
        for tick in 0..<10 {
            #expect(model.pollTransport(enginePlaying: false, now: Double(tick) / 60) == .unchanged)
        }
        #expect(counter.count == 0)
    }

    /// The other half, so the test above cannot pass by never notifying at all.
    @Test("a poll that does change the latch still invalidates, and still reports")
    func meaningfulPollStillInvalidatesAndReports() {
        let model = makeModel()
        model.transport.request(true, now: 0)

        let confirmation = InvalidationCounter()
        withObservationTracking {
            _ = model.isPlaying
        } onChange: {
            MainActor.assumeIsolated { confirmation.bump() }
        }
        // The render thread confirms: `isConfirmed` moves, so this is a real
        // change and observers must hear about it.
        #expect(model.pollTransport(enginePlaying: true, now: 0.1) == .started)
        #expect(confirmation.count == 1)

        // Re-armed, because `withObservationTracking` is one-shot: without a
        // fresh registration the expectation below would hold no matter what the
        // polls did, which is the sort of test that cannot fail.
        let steady = InvalidationCounter()
        withObservationTracking {
            _ = model.isPlaying
        } onChange: {
            MainActor.assumeIsolated { steady.bump() }
        }
        // Confirmed and still playing: nothing moves, nothing is published.
        for tick in 0..<10 {
            #expect(model.pollTransport(enginePlaying: true, now: 0.2 + Double(tick)) == .unchanged)
        }
        #expect(steady.count == 0)

        // End of file: the engine cleared its own flag, which is a real change.
        #expect(model.pollTransport(enginePlaying: false, now: 12) == .finished)
        #expect(!model.isPlaying)
        #expect(steady.count == 1)
    }

    @Test("a start the engine never confirms is still reported exactly once")
    func neverStartedIsStillReported() {
        let model = makeModel()
        model.transport.request(true, now: 0)
        #expect(model.pollTransport(enginePlaying: false, now: 1.0) == .unchanged)
        #expect(
            model.pollTransport(enginePlaying: false, now: TransportLatch.startTimeout + 0.1)
                == .neverStarted)
        #expect(model.pollTransport(enginePlaying: false, now: 10) == .unchanged)
    }

    // MARK: - Playhead synchronisation

    @Test("the drawn playhead is pulled back by the output latency, scaled by speed")
    func latencyCompensation() {
        // 20 ms of device latency at half speed is 10 ms of source material.
        let frame = PlayheadSync.audibleFrame(
            engineFrame: 44_100, outputLatency: 0.02, sampleRate: 44_100, speedRatio: 0.5)
        #expect(frame == 44_100 - 441)
    }

    @Test("latency compensation never runs the playhead negative or trusts a bogus latency")
    func latencyCompensationIsDefensive() {
        #expect(
            PlayheadSync.audibleFrame(
                engineFrame: 10, outputLatency: 1.0, sampleRate: 44_100, speedRatio: 1.0) == 0)
        #expect(
            PlayheadSync.audibleFrame(
                engineFrame: 500, outputLatency: .nan, sampleRate: 44_100, speedRatio: 1.0) == 500)
        #expect(
            PlayheadSync.audibleFrame(
                engineFrame: 500, outputLatency: -1, sampleRate: 44_100, speedRatio: 1.0) == 500)
    }
}

/// Counts `withObservationTracking` callbacks. A box rather than a captured
/// `var` because the change handler is `@Sendable`; `@MainActor` is what makes
/// the box itself `Sendable`, and the handler runs on the main actor because the
/// mutation that triggers it does.
@MainActor
final class InvalidationCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
