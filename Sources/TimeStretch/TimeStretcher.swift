/// Pull-based time stretching. Implementations must be allocation-free once
/// `configure` has returned, because `process`/`retrieve` run on the render thread.
public protocol TimeStretcher: AnyObject {
    /// Must be called before any processing. May allocate.
    func configure(sampleRate: Double, channels: Int, maxBlock: Int)

    /// Rubber Band's time ratio: 2.0 means output is twice as long (half speed).
    /// Safe to set from the render thread.
    var timeRatio: Double { get set }

    /// Rubber Band's pitch scale: 2.0 is an octave up. **Not** a reciprocal —
    /// unlike `timeRatio`, where the user-facing speed is the inverse of what
    /// the engine takes. Independent of `timeRatio`, which is the whole point:
    /// slowing a passage down must not transpose it. Safe to set from the
    /// render thread.
    var pitchScale: Double { get set }

    /// Output frames of priming to discard after `configure`/`reset`.
    var startDelay: Int { get }

    /// Input frames the stretcher would like next.
    func samplesRequired() -> Int

    /// Output frames ready to be retrieved.
    func available() -> Int

    func process(_ input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool)
    func retrieve(_ output: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int) -> Int
    func reset()
}
