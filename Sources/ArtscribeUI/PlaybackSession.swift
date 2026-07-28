import ArtscribeKit
import AudioDecode
import Playback
import TimeStretch

/// One decoded track wired to the audio graph: command ring, engine, output.
///
/// It is a plain class, not `@Observable`: nothing here changes on its own that
/// a view should watch. Everything the UI displays is polled from it on the
/// display link and published by `ViewerModel`, which keeps the
/// "render thread → main actor is polled, never pushed" rule (spec §5) visible in
/// the type structure rather than only in a comment.
@MainActor
final class PlaybackSession {
    let ring: CommandRing
    let engine: PlaybackEngine
    let output: AudioOutput

    /// Commands the ring refused because it was full. Should never be non-zero —
    /// the ring holds 256 and the UI pushes a handful per keystroke — but a
    /// dropped command means the engine is silently running at the wrong speed or
    /// loop, so it is counted and surfaced rather than assumed impossible.
    private(set) var droppedCommands: UInt64 = 0

    init(audio: DecodedAudio, stretchEngine: StretchEngine) throws {
        ring = CommandRing(capacity: 256)
        engine = PlaybackEngine(
            audio: audio, stretcher: RubberBandStretcher(engine: stretchEngine), ring: ring,
            maxBlock: 1024)
        output = try AudioOutput(
            engine: engine, sampleRate: audio.sampleRate)
    }

    func push(_ command: PlaybackCommand) {
        if !ring.push(command) { droppedCommands += 1 }
    }

    func start() throws {
        try output.start()
    }

    func stop() {
        output.stop()
    }
}

/// The render-thread degradation counters, snapshotted together.
///
/// Task 8 publishes `renderStallCount` and `rejectedCommandCount` and Task 9's
/// output layer publishes `renderLayoutMismatchCount`; before this task nothing
/// in the app read any of them. A counter nobody reads is only half a fix for
/// silent degradation — and a *permanent* stall presents to the user as
/// "playing, playhead frozen, silence, forever", because the engine deliberately
/// stays in the playing state across a stall so a transient one can recover.
public struct DegradationCounts: Equatable, Sendable {
    public var stalls: UInt64 = 0
    public var rejectedCommands: UInt64 = 0
    public var bufferLayoutMismatches: UInt64 = 0
    public var droppedCommands: UInt64 = 0

    public init(
        stalls: UInt64 = 0, rejectedCommands: UInt64 = 0, bufferLayoutMismatches: UInt64 = 0,
        droppedCommands: UInt64 = 0
    ) {
        self.stalls = stalls
        self.rejectedCommands = rejectedCommands
        self.bufferLayoutMismatches = bufferLayoutMismatches
        self.droppedCommands = droppedCommands
    }

    /// What the status bar shows. `nil` while everything is healthy.
    public var summary: String? {
        var parts: [String] = []
        if stalls > 0 { parts.append("\(stalls) render stall\(stalls == 1 ? "" : "s")") }
        if rejectedCommands > 0 { parts.append("\(rejectedCommands) rejected") }
        if bufferLayoutMismatches > 0 {
            parts.append("\(bufferLayoutMismatches) bad buffer layout")
        }
        if droppedCommands > 0 { parts.append("\(droppedCommands) dropped") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The banner text when a counter has just moved. Deliberately says what the
    /// user will *observe*, because the observable symptom (silence, or a frozen
    /// playhead) is otherwise impossible to attribute.
    public var banner: String? {
        guard let summary else { return nil }
        if stalls > 0 {
            return "Audio rendering stalled (\(summary)). Sound may have dropped out and the "
                + "playhead can stop advancing while the transport still reads as playing."
        }
        return "Playback degraded: \(summary)."
    }
}
