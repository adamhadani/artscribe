import AVFAudio
import ArtscribeKit
import AudioDecode
import Foundation
import Testing
import TimeStretch

@testable import Playback

/// A session that reports whatever a test tells it to.
///
/// This is what makes iOS interruption handling testable on a Mac: `AudioOutput`
/// takes its session as a parameter, so the events it can never receive here can
/// be delivered by hand, through the same code path a real `AVAudioSession`
/// would use.
@MainActor
private final class FakeAudioSession: AudioSessionCoordinator {
    var onEvent: (@MainActor (AudioSessionEvent) -> Void)?

    private(set) var configureCount = 0
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0

    func configure() throws { configureCount += 1 }
    func activate() throws { activateCount += 1 }
    func deactivate() { deactivateCount += 1 }

    func send(_ event: AudioSessionEvent) { onEvent?(event) }
}

/// Building an `AVAudioEngine` graph needs an output device to *exist*, even
/// though nothing here starts hardware or makes a sound. See
/// `OutputDeviceAvailability` for why the question is platform-dependent.
private let hasOutputDevice = OutputDeviceAvailability.hasOutputDevice

@Suite("Audio session interruptions through AudioOutput", .enabled(if: hasOutputDevice))
@MainActor
struct AudioOutputInterruptionTests {

    private static let rate = 44_100.0
    private static let channels = 2

    /// A transport the test drives by hand, standing in for `ViewerModel`.
    ///
    /// `isPlaying` is a variable and not `output.isRunning` on purpose — that
    /// substitution is the bug these tests missed for four builds. The graph runs
    /// from the moment a track is opened; the transport does not.
    @MainActor
    private final class FakeTransport {
        var isPlaying = false
        private(set) var interruptions = 0
        private(set) var resumes = 0

        /// Captured strongly, so a test that never sends an event can build one
        /// inline. The link is owned by the output and the transport owns
        /// nothing, so there is no cycle to make here.
        var link: TransportLink {
            TransportLink(
                isPlaying: { self.isPlaying },
                onInterrupted: {
                    self.interruptions += 1
                    // What the real model does: an interruption brings the
                    // transport into line. Without it these tests would describe
                    // a transport that never notices, which is what shipped.
                    self.isPlaying = false
                },
                onResumeRequested: {
                    self.resumes += 1
                    self.isPlaying = true
                })
        }
    }

    private func makeOutput(transport: FakeTransport) throws -> (AudioOutput, FakeAudioSession) {
        let storage = AudioStorage(channels: Self.channels, capacityFrames: 8192)
        let audio = DecodedAudio(
            channels: Self.channels, sampleRate: Self.rate, frameCount: 8192, storage: storage)
        let ring = CommandRing(capacity: 16)
        let engine = PlaybackEngine(
            audio: audio, stretcher: IdentityStretcher(), ring: ring, maxBlock: 1024)
        let session = FakeAudioSession()
        let output = try AudioOutput(
            engine: engine, sampleRate: Self.rate, session: session, transport: transport.link)
        return (output, session)
    }

    /// Runs the graph without hardware, so `isRunning` is genuinely true and the
    /// pause path has something to stop.
    private func started(_ output: AudioOutput) throws {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: Self.rate,
                channels: AVAudioChannelCount(Self.channels))
        else { throw AudioOutputError.noOutputUnit }
        try output.avEngine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: 4096)
        try output.start()
    }

    // MARK: - Lifecycle

    @Test("the session is configured once, when the output is built")
    func configuredAtInit() throws {
        let (output, session) = try makeOutput(transport: FakeTransport())
        #expect(session.configureCount == 1)
        #expect(session.activateCount == 0)
        _ = output
    }

    /// The session has to be claimed before the engine negotiates a format
    /// against it, and handed back only once nothing is still rendering into it.
    @Test("start claims the session and stop hands it back")
    func startAndStopBracketTheSession() throws {
        let (output, session) = try makeOutput(transport: FakeTransport())
        try started(output)
        #expect(session.activateCount == 1)
        #expect(session.deactivateCount == 0)

        output.stop()
        #expect(session.deactivateCount == 1)
        #expect(!output.isRunning)
    }

    @Test("a second start does not claim the session twice")
    func startIsIdempotent() throws {
        let (output, session) = try makeOutput(transport: FakeTransport())
        try started(output)
        try output.start()
        #expect(session.activateCount == 1)
    }

    // MARK: - Interruptions

    @Test("an interruption stops the graph, says why, and tells the transport")
    func interruptionPausesAndReports() throws {
        let transport = FakeTransport()
        let (output, session) = try makeOutput(transport: transport)
        try started(output)
        transport.isPlaying = true

        session.send(.interruptionBegan)

        #expect(!output.isRunning)
        #expect(transport.interruptions == 1)
        #expect(output.notice != nil)
        // The reported bug, as an assertion: the graph stopping is only half of
        // it. Before this, the transport was never told, so every surface that
        // reads it — the play/pause button, the Playback menu, the lock screen —
        // went on claiming to play over silence until the app was relaunched.
        #expect(!transport.isPlaying)
    }

    /// The load-bearing one. By the time an interruption *ends*, the transport
    /// has read paused since it began — because the interruption itself is what
    /// paused it. So a handler that asked "are we playing?" at the end would
    /// never resume anything. What was true at the start is what has to be
    /// consulted at the end.
    @Test("an interruption that began while playing resumes when the system allows")
    func resumeUsesTheRememberedState() throws {
        let transport = FakeTransport()
        let (output, session) = try makeOutput(transport: transport)
        try started(output)
        transport.isPlaying = true

        session.send(.interruptionBegan)
        #expect(!output.isRunning)
        #expect(!transport.isPlaying)
        session.send(.interruptionEnded(systemSuggestsResuming: true))

        #expect(transport.resumes == 1)
    }

    /// A phone call. The system withholds `shouldResume`, and talking over the
    /// end of a conversation is exactly what that flag exists to prevent.
    @Test("an interruption the system says not to resume does not resume")
    func systemVetoIsHonoured() throws {
        let transport = FakeTransport()
        let (output, session) = try makeOutput(transport: transport)
        try started(output)
        transport.isPlaying = true

        session.send(.interruptionBegan)
        session.send(.interruptionEnded(systemSuggestsResuming: false))

        #expect(transport.resumes == 0)
    }

    /// **The second defect, and the one nobody reported.**
    ///
    /// The graph is running — it always is, from the moment a track is opened —
    /// but the user has not pressed play. An alarm goes off and ends with
    /// `shouldResume` set, which the system does for a timer.
    ///
    /// Nothing may start. This test read green while the bug was live, because
    /// the old version asserted it by leaving the *graph* stopped, which is a
    /// state the app is never in with a track loaded. Judging "was playing" by
    /// `output.isRunning` meant a paused, loaded track answered yes, and an alarm
    /// started music the user had never asked for.
    @Test("a running graph with a paused transport is never resumed")
    func aPausedTransportIsNotResumed() throws {
        let transport = FakeTransport()
        let (output, session) = try makeOutput(transport: transport)
        try started(output)
        // The graph runs. The transport does not. This is the resting state of
        // every open document in the app.
        #expect(output.isRunning)
        transport.isPlaying = false

        session.send(.interruptionBegan)
        session.send(.interruptionEnded(systemSuggestsResuming: true))

        #expect(transport.interruptions == 0)
        #expect(transport.resumes == 0)
        #expect(!transport.isPlaying)
        // And the graph is left alone: there was nothing to stop, so stopping it
        // would only have cost the next press of Space its instant start.
        #expect(output.isRunning)
    }

    /// The remembered flag is consumed, not left set. Otherwise a stray second
    /// `interruptionEnded` — the system does repeat notifications — would resume
    /// a track the user had since paused.
    @Test("a repeated end-of-interruption does not resume twice")
    func rememberedStateIsConsumed() throws {
        let transport = FakeTransport()
        let (output, session) = try makeOutput(transport: transport)
        try started(output)
        transport.isPlaying = true

        session.send(.interruptionBegan)
        session.send(.interruptionEnded(systemSuggestsResuming: true))
        session.send(.interruptionEnded(systemSuggestsResuming: true))

        #expect(transport.resumes == 1)
    }

    // MARK: - Route changes

    /// Headphones out. The notice has to name the actual cause — "audio was
    /// interrupted" would be a puzzle rather than an explanation.
    @Test("losing the output device pauses and says which thing happened")
    func lostDeviceHasItsOwnNotice() throws {
        let transport = FakeTransport()
        let (output, session) = try makeOutput(transport: transport)
        try started(output)
        transport.isPlaying = true

        session.send(.outputDeviceDisappeared)

        #expect(!output.isRunning)
        #expect(transport.interruptions == 1)
        #expect(!transport.isPlaying)
        #expect(output.notice?.contains("disconnected") == true)
    }

    /// Headphones out while nothing is playing. There is nothing to protect
    /// anyone's ears from, so the banner would be an announcement about an event
    /// with no consequence — and it appeared on every unplug, because the graph
    /// was running.
    @Test("losing the output device while paused says nothing")
    func lostDeviceWhilePausedIsQuiet() throws {
        let transport = FakeTransport()
        let (output, session) = try makeOutput(transport: transport)
        try started(output)
        transport.isPlaying = false

        session.send(.outputDeviceDisappeared)

        #expect(transport.interruptions == 0)
        #expect(output.notice == nil)
    }

    @Test("an ordinary route change disturbs nothing")
    func ordinaryRouteChangeIsInert() throws {
        let transport = FakeTransport()
        let (output, session) = try makeOutput(transport: transport)
        try started(output)
        transport.isPlaying = true

        session.send(.outputRouteChanged)

        #expect(output.isRunning)
        #expect(transport.interruptions == 0)
        #expect(output.notice == nil)
    }
}
