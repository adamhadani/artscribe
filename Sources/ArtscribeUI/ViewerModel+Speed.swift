import ArtscribeKit
import AudioDecode
import Playback

/// Speed, and the engine that renders it.
///
/// Split out of `ViewerModel+Playback.swift` when that file passed the 400-line
/// limit, along the seam that was already marked there. It is a real seam rather
/// than an arbitrary cut: everything here goes through `applySpeed`, which owns
/// the one decision that makes this section different from the rest of playback
/// — whether a change can be pushed to the running engine or needs the graph
/// torn down and rebuilt.
extension ViewerModel {

    public func slower(fine isFine: Bool) {
        applySpeed(
            SpeedStepping.stepped(speed, by: -(isFine ? SpeedStepping.fine : SpeedStepping.coarse)))
    }

    public func faster(fine isFine: Bool) {
        applySpeed(
            SpeedStepping.stepped(speed, by: isFine ? SpeedStepping.fine : SpeedStepping.coarse))
    }

    /// **Set the speed to a given ratio**, quantised and clamped. Named after
    /// the `1`–`4` keys, its first caller; it is the general path, and Task 21's
    /// practice ramp is its second caller for exactly that reason — a ramp with
    /// its own `setTimeRatio` would be a second way to reach the render thread.
    public func setSpeedPreset(_ ratio: Double) {
        var next = speed
        next.setRatio(SpeedStepping.quantise(ratio))
        applySpeed(next)
    }

    /// Switches backend. **Developer-only** — reached from Playback ▸ Developer
    /// ▸ Stretch Engine, which only exists when `DeveloperMenu.isEnabled`.
    ///
    /// A stretcher's engine is fixed at construction and `PlaybackCommand`
    /// deliberately carries only POD payloads, so a running one cannot be
    /// swapped through the ring. The graph is rebuilt instead, off the render
    /// thread, and the position, speed, loop and transport state are restored —
    /// which is audible as a short gap, and is the honest cost of the switch.
    ///
    /// That gap is worth knowing about when A/B-ing by ear: you are comparing
    /// two renders separated by a reload, not crossfading between them.
    public func setStretchEngine(_ engine: StretchEngine) {
        var next = speed
        next.engine = engine
        applySpeed(next)
    }

    private func applySpeed(_ next: SpeedState) {
        guard next != speed else { return }
        let enginesDiffer = next.engine != speed.engine
        speed = next
        // Before the engine-rebuild branch, not after it: `⌥E` changes the
        // active engine, which spec §7 persists, and marking only the ratio
        // path would leave an engine switch out of the sidecar and out of the
        // close prompt.
        markSessionEdited()
        guard !enginesDiffer else {
            rebuildSession()
            return
        }
        // Applied on the next render quantum, with no reset and therefore no
        // click: `PlaybackEngine` only re-scales its pending-output accounting.
        session?.push(.setTimeRatio(speed.timeRatio))
    }

    private func rebuildSession() {
        guard let audio else { return }
        let wasPlaying = transport.isPlaying
        let position = playhead
        teardownSession()
        openSession(for: audio)
        guard session != nil else { return }
        session?.push(.setLoop(loop.range, loop.isEnabled))
        seek(to: position)
        if wasPlaying { play() }
    }
}
