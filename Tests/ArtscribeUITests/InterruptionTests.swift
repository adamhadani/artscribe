import ArtscribeKit
import AudioDecode
import Foundation
import Playback
import Testing
import Waveform

@testable import ArtscribeUI

/// The model's half of an audio interruption: what the transport does when the
/// platform stops us, and what it does when the platform says we may carry on.
///
/// **No audio device and no `#if` here, both deliberately.** The events these
/// describe only happen on a phone, and the app is developed on a Mac; a suite
/// that needed either would run nowhere, which is how the wiring came to be
/// missing in the first place. `makeTransportLink()` is the object the app
/// builds and hands to the audio graph, so driving its closures drives exactly
/// what an interruption drives — one call short of `AVAudioSession` itself, and
/// that call is covered in `PlaybackTests`.
@MainActor
@Suite("Audio interruptions reach the transport")
struct InterruptionTests {

    private static let sampleRate: Double = 44100
    private static let totalFrames: FrameIndex = 441_000  // 10 s

    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: Self.sampleRate, frameCount: Self.totalFrames,
            storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    // MARK: - The reported bug

    /// Play, get interrupted, come back to the app. The button must offer to
    /// play, not to pause.
    ///
    /// Reported from an iPhone: background the app while playing, start
    /// something in Spotify, stop it, return. The audio had stopped correctly and
    /// stayed stopped correctly — and the transport still showed the pause glyph,
    /// because nothing had ever told it.
    @Test("an interruption clears the transport, so the button reads play again")
    func interruptionClearsTheTransport() {
        let model = makeModel()
        model.transport.request(true, now: 0)
        #expect(model.isPlaying)

        model.audioWasInterrupted()

        #expect(!model.isPlaying)
    }

    /// The same assertion one layer out, through the value the graph is actually
    /// given. This is the join that was missing: all three behaviours below were
    /// implemented and tested, and nothing connected them to the audio graph.
    @Test("the link the app hands to the graph carries the interruption home")
    func theLinkIsWiredToTheModel() {
        let model = makeModel()
        let link = model.makeTransportLink()

        model.transport.request(true, now: 0)
        #expect(link.isPlaying())

        link.onInterrupted()

        #expect(!model.isPlaying)
        #expect(!link.isPlaying())
    }

    // MARK: - The second defect

    /// A track is open and the graph is running, but nobody has pressed play.
    ///
    /// This is the resting state of every open document, and the audio layer used
    /// to answer "playing" for it — it asked `AudioOutput.isRunning`, which is
    /// true from the moment a file is opened. An alarm ending with `shouldResume`
    /// would then have started playing a track the user had never started.
    @Test("a loaded but never-played track does not report itself playing")
    func aLoadedTrackIsNotPlaying() {
        let model = makeModel()
        #expect(!model.makeTransportLink().isPlaying())
    }

    /// Paused by hand, then interrupted, then the interruption ends with the
    /// system's blessing. The transport must not come back on.
    ///
    /// The policy in `Playback` is what enforces this and it is tested there;
    /// what this pins is that the model reports the paused state the policy
    /// depends on, rather than something derived from the graph.
    @Test("a hand-paused track reports paused for the policy to read")
    func aPausedTrackReportsPaused() {
        let model = makeModel()
        model.transport.request(true, now: 0)
        model.pause()
        #expect(!model.makeTransportLink().isPlaying())
    }

    // MARK: - Resuming

    /// A resume asks to play. It must never be written as a *toggle*, however
    /// short that line is: a toggle resumes only because the transport happens to
    /// read paused, so any path that left the latch set would turn the resume
    /// into a pause and stop the music the interruption was over.
    @Test("resuming a transport that still reads playing does not pause it")
    func resumeIsNotAToggle() {
        let model = makeModel()
        model.transport.request(true, now: 0)

        model.audioMayResume()

        #expect(model.isPlaying, "a resume that pauses is a toggle wearing a resume's name")
    }

    /// With no audio graph there is nothing to resume, and `play()` says so
    /// rather than lighting the button up over a device that was never opened.
    @Test("resuming with no audio graph raises a notice and claims nothing")
    func resumeWithoutAGraphIsHonest() {
        let model = makeModel()
        model.audioMayResume()

        #expect(!model.isPlaying)
        #expect(model.playbackNotice != nil)
    }

    /// Every closure in the link holds the model weakly: the model owns the
    /// session, the session owns the output, and the output holds the link. A
    /// strong capture is a cycle that keeps a closed document — and its decoded
    /// audio — alive for the life of the process.
    @Test("the link does not keep the model alive")
    func theLinkHoldsTheModelWeakly() {
        var model: ViewerModel? = makeModel()
        let link = model?.makeTransportLink()
        model?.transport.request(true, now: 0)
        #expect(link?.isPlaying() == true)

        model = nil

        #expect(link?.isPlaying() == false, "the link is holding the model strongly")
    }
}
