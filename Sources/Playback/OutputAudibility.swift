import Foundation
import Synchronization

/// Whether anything this process renders is allowed to reach the speakers.
///
/// Automated runs must be silent. An agent launching the app to check a change
/// has no way to turn the volume down first — the machine's own volume control
/// is not enough, and the noise arrives in whatever room the laptop is in. So
/// the guarantee is made in the graph rather than asked for by convention: when
/// this gate is closed, `AudioOutput`'s render block zeroes its output *after*
/// `PlaybackEngine.render` has run.
///
/// After, not instead of, and this is the whole design:
///
/// - The engine still renders, so the position it publishes still advances in
///   real time. Every acceptance check that measures the playhead — loop wraps,
///   page-flip auto-scroll, "the playhead tracks real time at 1.0x" — keeps
///   working, and keeps being driven by the real CoreAudio render thread.
/// - The source node is the graph's **only** signal source, so a block of zeros
///   leaving it is total silence at the DAC. Nothing downstream can put a sample
///   back.
/// - `mainMixerNode.outputVolume` is untouched, so `AudioOutput.volume` still
///   reports what the user's volume control asked for and the volume checks
///   still measure the thing they were written to measure.
///
/// The alternative — `enableManualRenderingMode(.offline)` — is a stronger
/// statement about the hardware but a much weaker test: it renders as fast as it
/// is pumped rather than in real time, reports no output latency and no device
/// sample rate, and would take the real render thread out of the only place it is
/// exercised end to end. Silence is not worth buying with the coverage.
///
/// Read on the render thread through an atomic: lock-free, allocation-free, and
/// it takes effect on the very next block, so closing the gate silences a graph
/// that is already running.
public final class OutputAudibility: Sendable {

    /// Process-wide, because it is a fact about the process — an agent's
    /// automated run — and not about any one graph.
    public static let shared = OutputAudibility()

    /// Set `ARTSCRIBE_SILENT=1` to silence any Artscribe binary, including the
    /// product app. The acceptance harness closes the gate itself and needs no
    /// environment at all.
    public static let silentEnvironmentKey = "ARTSCRIBE_SILENT"

    private let silenced: Atomic<Bool>

    private init() {
        silenced = Atomic(
            ProcessInfo.processInfo.environment[Self.silentEnvironmentKey] == "1")
    }

    /// True when no sample can reach the output hardware.
    public var isSilenced: Bool { silenced.load(ordering: .relaxed) }

    /// Closes the gate. Idempotent, and safe at any time — including with a graph
    /// already running.
    public func silence() {
        silenced.store(true, ordering: .relaxed)
    }

    /// Opens it again. The explicit choice, for a human who wants to listen.
    public func allowAudibleOutput() {
        silenced.store(false, ordering: .relaxed)
    }
}
