import ArtscribeKit
import AudioDecode
import Testing
import Waveform

@testable import ArtscribeUI

/// Pitch on the model: the range, the label, and independence from speed.
@MainActor
@Suite("Pitch through the model")
struct ViewerModelPitchTests {

    private func makeModel() -> ViewerModel {
        let frames: FrameIndex = 441_000
        let storage = AudioStorage(channels: 1, capacityFrames: Int(frames))
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: frames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 1000)
        return model
    }

    @Test("a semitone up and down returns exactly to zero")
    func semitoneRoundTrip() {
        let model = makeModel()
        model.adjustPitch(byCents: ViewerModel.semitoneStep)
        #expect(model.pitch.cents == 100)
        #expect(model.pitch.semitones == 1)
        model.adjustPitch(byCents: -ViewerModel.semitoneStep)
        #expect(model.pitch.cents == 0)
        #expect(!model.pitch.isAltered)
    }

    /// The feature, stated as a test: the two controls do not touch each other.
    @Test("changing the pitch leaves the speed alone, and vice versa")
    func pitchAndSpeedAreIndependent() {
        let model = makeModel()
        model.setSpeedPreset(0.5)
        model.adjustPitch(byCents: 700)
        #expect(model.speed.ratio == 0.5, "pitch moved the speed")
        #expect(model.pitch.cents == 700)
        model.setSpeedPreset(1.0)
        #expect(model.pitch.cents == 700, "speed moved the pitch")
    }

    @Test("nothing happens without a track")
    func requiresATrack() {
        let model = ViewerModel()
        model.adjustPitch(byCents: 100)
        #expect(model.pitch.cents == 0)
    }

    @Test("reset returns to the original key from either direction")
    func reset() {
        let model = makeModel()
        model.adjustPitch(byCents: -450)
        #expect(model.pitch.cents == -450)
        model.resetPitch()
        #expect(model.pitch.cents == 0)
    }

    /// The readout is how a musician reads it, so it is worth pinning: whole
    /// semitones alone, cents alone, and the mixed case.
    @Test("the label reads the way a musician says it")
    func label() {
        let model = makeModel()
        #expect(model.pitchLabel.isEmpty, "an untransposed track says nothing")
        model.setPitch(cents: 300)
        #expect(model.pitchLabel == "+3")
        model.setPitch(cents: -300)
        #expect(model.pitchLabel == "−3")
        model.setPitch(cents: 50)
        #expect(model.pitchLabel == "+50¢")
        model.setPitch(cents: -350)
        #expect(model.pitchLabel == "−3 −50¢")
    }

    @Test("the slider's range is clamped at an octave either way")
    func sliderRange() {
        let model = makeModel()
        model.setPitch(cents: 99999)
        #expect(model.pitch.cents == PitchState.maxCents)
        model.setPitch(cents: -99999)
        #expect(model.pitch.cents == PitchState.minCents)
    }

    /// A transposition is a decision about the material, not a transient view
    /// state, so it belongs in the sidecar beside the speed and the loop.
    ///
    /// Asserted on `sessionState` rather than on `isDirty`: dirtiness needs a
    /// track URL to save *to*, which a `loadForTesting` model has not got — the
    /// speed behaves exactly the same way. What matters here is that the
    /// durable snapshot carries the pitch at all.
    @Test("the pitch is part of the durable session state")
    func isCapturedInTheSession() throws {
        let model = makeModel()
        model.adjustPitch(byCents: -250)
        let state = try #require(model.sessionState)
        #expect(state.pitch.cents == -250)
        // And it survives the sidecar round trip, encoder and decoder included.
        let restored = SessionState.restoring(
            state.fileRepresentation, frameCount: 441_000, sampleRate: 44100)
        #expect(restored.state.pitch.cents == -250)
    }
}
