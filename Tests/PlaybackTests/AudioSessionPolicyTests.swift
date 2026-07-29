import Testing

@testable import Playback

/// Interruption behaviour, tested on a platform where no interruption can occur.
///
/// That is the whole reason `AudioSessionPolicy` is a pure function of an event
/// and a flag rather than a `switch` buried in the `AVAudioSession` observer: on
/// a Mac there is no way to place a phone call to the machine, and the decisions
/// below are exactly the ones that are expensive to get wrong on a device.
@Suite("Audio session policy")
struct AudioSessionPolicyTests {

    private func response(
        _ event: AudioSessionEvent, playing: Bool
    ) -> AudioSessionResponse {
        AudioSessionPolicy.response(to: event, wasPlaying: playing)
    }

    // MARK: - Interruptions

    @Test("an interruption while playing pauses the transport")
    func interruptionPauses() {
        #expect(response(.interruptionBegan, playing: true) == .pause)
    }

    /// The system has already stopped the audio; there is nothing to stop. A
    /// `.pause` here would be harmless but dishonest, and it is what makes the
    /// resume rule below testable in isolation.
    @Test("an interruption while stopped does nothing")
    func interruptionWhileStoppedDoesNothing() {
        #expect(response(.interruptionBegan, playing: false) == .none)
    }

    @Test("resuming needs both the system's blessing and having been playing")
    func resumeNeedsBothHalves() {
        #expect(
            response(.interruptionEnded(systemSuggestsResuming: true), playing: true) == .resume)
        // A phone call: the system withholds `shouldResume`, and a music app
        // that resumed anyway would talk over the end of the conversation.
        #expect(
            response(.interruptionEnded(systemSuggestsResuming: false), playing: true) == .none)
        // Paused before the interruption ever arrived. The flag is the system's
        // opinion about the *interruption*, not about what the user wanted.
        #expect(
            response(.interruptionEnded(systemSuggestsResuming: true), playing: false) == .none)
        #expect(
            response(.interruptionEnded(systemSuggestsResuming: false), playing: false) == .none)
    }

    // MARK: - Route changes

    /// The rule this whole file exists for. Headphones out must not become the
    /// speaker, in a tool that is often running loud in a room with other people
    /// in it.
    @Test("losing the output device pauses rather than rerouting")
    func lostDevicePauses() {
        #expect(response(.outputDeviceDisappeared, playing: true) == .pause)
        #expect(response(.outputDeviceDisappeared, playing: false) == .none)
    }

    /// Answered by `AVAudioEngineConfigurationChange`, which `AudioOutput`
    /// already observes. Responding here as well would stop and restart the
    /// graph twice for one event, which is audible.
    @Test("an ordinary route change is left to the engine's own notification")
    func ordinaryRouteChangeIsNotOurs() {
        #expect(response(.outputRouteChanged, playing: true) == .none)
        #expect(response(.outputRouteChanged, playing: false) == .none)
    }

    /// The one event that ignores `wasPlaying`: every audio object this process
    /// holds is stale either way, and a graph that is merely stopped is still a
    /// graph that will not start again.
    @Test("a media services reset rebuilds whether or not we were playing")
    func mediaServicesResetAlwaysReconfigures() {
        #expect(response(.mediaServicesReset, playing: true) == .reconfigure)
        #expect(response(.mediaServicesReset, playing: false) == .reconfigure)
    }

    // MARK: - Totality

    /// Nothing may fall through to "do nothing" by omission. A new case added to
    /// `AudioSessionEvent` without a rule would be silent degradation of exactly
    /// the kind spec §8 forbids — and the compiler cannot catch it, because
    /// `.none` is a legitimate answer for two of the cases above.
    @Test("every event has a considered answer in at least one playing state")
    func everyEventIsAnswered() {
        let events: [AudioSessionEvent] = [
            .interruptionBegan,
            .interruptionEnded(systemSuggestsResuming: true),
            .outputDeviceDisappeared,
            .outputRouteChanged,
            .mediaServicesReset
        ]
        let answered = events.filter { event in
            response(event, playing: true) != .none || response(event, playing: false) != .none
        }
        // `.outputRouteChanged` is the deliberate exception, and it is named
        // rather than counted so that a *different* case going quiet fails here.
        #expect(Set(events).subtracting(answered) == [.outputRouteChanged])
    }
}

/// The macOS session, asserted to be inert rather than assumed to be.
@Suite("Unmanaged audio session")
@MainActor
struct UnmanagedAudioSessionTests {

    /// Every method is a no-op and `onEvent` is never called. That is not a stub
    /// waiting to be filled in — it is the accurate model of a platform where
    /// nothing can take the output away — so it is worth one test saying so out
    /// loud, and it is what proves `AudioOutput` never sees a spurious pause on
    /// the Mac.
    @Test("configuring, activating and deactivating report nothing")
    func inert() throws {
        let session = UnmanagedAudioSession()
        var seen: [AudioSessionEvent] = []
        session.onEvent = { seen.append($0) }

        try session.configure()
        try session.activate()
        try session.activate()
        session.deactivate()
        session.deactivate()

        #expect(seen.isEmpty)
    }
}
