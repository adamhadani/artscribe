import ArtscribeKit

/// What `A`, `S` and `G` do to the loop region.
///
/// The whole of the interesting behaviour is what happens when the two edges
/// cross, which a transcriber hits constantly: set the out point, then decide the
/// passage should start earlier and press `A` past it. Collapsing the region
/// there would present as "the key did nothing", so instead the *other* edge is
/// pushed to the nearest file boundary and the loop stays real.
public enum LoopEditing {

    /// `A` — set the in point, keeping the out point where it is when it still
    /// makes a region, and running to the end of the file when it does not.
    public static func settingIn(
        at frame: FrameIndex, in loop: LoopRegion, totalFrames: FrameIndex
    ) -> LoopRegion {
        let start = clamp(frame, totalFrames)
        let end = loop.range.end > start ? loop.range.end : totalFrames
        return LoopRegion(
            range: FrameRange(start: start, count: Swift.max(0, end - start)),
            isEnabled: loop.isEnabled)
    }

    /// `S` — set the out point, pulling the in point back to the start of the
    /// file when the existing one is no longer before it.
    public static func settingOut(
        at frame: FrameIndex, in loop: LoopRegion, totalFrames: FrameIndex
    ) -> LoopRegion {
        let end = clamp(frame, totalFrames)
        let start = loop.range.start < end ? loop.range.start : 0
        return LoopRegion(
            range: FrameRange(start: start, count: Swift.max(0, end - start)),
            isEnabled: loop.isEnabled)
    }

    /// `G` — the selection becomes the loop region. It deliberately does not
    /// enable looping: `D` is what does that, so `G` alone is safe to press while
    /// something else is looping.
    public static func fromSelection(
        _ range: FrameRange, in loop: LoopRegion, totalFrames: FrameIndex
    ) -> LoopRegion {
        let clamped = range.clamped(to: totalFrames)
        guard !clamped.isEmpty else { return loop }
        return LoopRegion(range: clamped, isEnabled: loop.isEnabled)
    }

    private static func clamp(_ frame: FrameIndex, _ totalFrames: FrameIndex) -> FrameIndex {
        Swift.max(0, Swift.min(frame, totalFrames))
    }
}
