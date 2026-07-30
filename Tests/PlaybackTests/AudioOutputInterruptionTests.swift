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

    private func makeOutput() throws -> (AudioOutput, FakeAudioSession) {
        let storage = AudioStorage(channels: Self.channels, capacityFrames: 8192)
        let audio = DecodedAudio(
            channels: Self.channels, sampleRate: Self.rate, frameCount: 8192, storage: storage)
        let ring = CommandRing(capacity: 16)
        let engine = PlaybackEngine(
            audio: audio, stretcher: IdentityStretcher(), ring: ring, maxBlock: 1024)
        let session = FakeAudioSession()
        let output = try AudioOutput(engine: engine, sampleRate: Self.rate, session: session)
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
        let (output, session) = try makeOutput()
        #expect(session.configureCount == 1)
        #expect(session.activateCount == 0)
        _ = output
    }

    /// The session has to be claimed before the engine negotiates a format
    /// against it, and handed back only once nothing is still rendering into it.
    @Test("start claims the session and stop hands it back")
    func startAndStopBracketTheSession() throws {
        let (output, session) = try makeOutput()
        try started(output)
        #expect(session.activateCount == 1)
        #expect(session.deactivateCount == 0)

        output.stop()
        #expect(session.deactivateCount == 1)
        #expect(!output.isRunning)
    }

    @Test("a second start does not claim the session twice")
    func startIsIdempotent() throws {
        let (output, session) = try makeOutput()
        try started(output)
        try output.start()
        #expect(session.activateCount == 1)
    }

    // MARK: - Interruptions

    @Test("an interruption stops the graph, says why, and tells the owner")
    func interruptionPausesAndReports() throws {
        let (output, session) = try makeOutput()
        try started(output)

        var interrupted = 0
        output.onInterrupted = { interrupted += 1 }

        session.send(.interruptionBegan)

        #expect(!output.isRunning)
        #expect(interrupted == 1)
        #expect(output.notice != nil)
    }

    /// The load-bearing one. By the time an interruption *ends*, `isRunning` has
    /// been false since it began — so a handler that judged "were we playing?"
    /// against the graph as it stands would never resume anything. What is
    /// remembered at the start is what has to be consulted at the end.
    @Test("an interruption that began while playing resumes when the system allows")
    func resumeUsesTheRememberedState() throws {
        let (output, session) = try makeOutput()
        try started(output)

        var resumes = 0
        output.onResumeRequested = { resumes += 1 }

        session.send(.interruptionBegan)
        #expect(!output.isRunning)
        session.send(.interruptionEnded(systemSuggestsResuming: true))

        #expect(resumes == 1)
    }

    /// A phone call. The system withholds `shouldResume`, and talking over the
    /// end of a conversation is exactly what that flag exists to prevent.
    @Test("an interruption the system says not to resume does not resume")
    func systemVetoIsHonoured() throws {
        let (output, session) = try makeOutput()
        try started(output)

        var resumes = 0
        output.onResumeRequested = { resumes += 1 }

        session.send(.interruptionBegan)
        session.send(.interruptionEnded(systemSuggestsResuming: false))

        #expect(resumes == 0)
    }

    /// Interrupted while already paused, then the interruption ends with the
    /// system's blessing. Nothing should start playing: the user had stopped it.
    @Test("an interruption that began while stopped never resumes")
    func stoppedStaysStopped() throws {
        let (output, session) = try makeOutput()
        // Deliberately not started.

        var resumes = 0
        var interrupted = 0
        output.onResumeRequested = { resumes += 1 }
        output.onInterrupted = { interrupted += 1 }

        session.send(.interruptionBegan)
        session.send(.interruptionEnded(systemSuggestsResuming: true))

        #expect(interrupted == 0)
        #expect(resumes == 0)
    }

    /// The remembered flag is consumed, not left set. Otherwise a stray second
    /// `interruptionEnded` — the system does repeat notifications — would resume
    /// a track the user had since paused.
    @Test("a repeated end-of-interruption does not resume twice")
    func rememberedStateIsConsumed() throws {
        let (output, session) = try makeOutput()
        try started(output)

        var resumes = 0
        output.onResumeRequested = { resumes += 1 }

        session.send(.interruptionBegan)
        session.send(.interruptionEnded(systemSuggestsResuming: true))
        session.send(.interruptionEnded(systemSuggestsResuming: true))

        #expect(resumes == 1)
    }

    // MARK: - Route changes

    /// Headphones out. The notice has to name the actual cause — "audio was
    /// interrupted" would be a puzzle rather than an explanation.
    @Test("losing the output device pauses and says which thing happened")
    func lostDeviceHasItsOwnNotice() throws {
        let (output, session) = try makeOutput()
        try started(output)

        var interrupted = 0
        output.onInterrupted = { interrupted += 1 }

        session.send(.outputDeviceDisappeared)

        #expect(!output.isRunning)
        #expect(interrupted == 1)
        #expect(output.notice?.contains("disconnected") == true)
    }

    @Test("an ordinary route change disturbs nothing")
    func ordinaryRouteChangeIsInert() throws {
        let (output, session) = try makeOutput()
        try started(output)

        var interrupted = 0
        output.onInterrupted = { interrupted += 1 }

        session.send(.outputRouteChanged)

        #expect(output.isRunning)
        #expect(interrupted == 0)
        #expect(output.notice == nil)
    }
}
