import ArtscribeKit

/// What a loop-move action takes hold of — spec §6.2's `loop.move` actions.
///
/// Three targets rather than two. The selection can be slid whole with `C`/`V`,
/// and Task 23 gave the loop a draggable *body* while deliberately refusing the
/// selection one, so "move the whole loop" is the gesture the mouse has and the
/// keyboard did not — in an app whose stated bias is the keyboard, that is the
/// asymmetry worth closing. It is also the move a transcriber actually makes:
/// the phrase turned out to start a beat later than you marked it, and the loop
/// is the right *length*, just in the wrong place. Doing that with two edge
/// nudges is twice the keystrokes and drifts the length every time the two
/// amounts are not applied an equal number of times.
public enum LoopMoveTarget: String, CaseIterable, Identifiable, Sendable {
    case inPoint
    case outPoint
    case whole

    public var id: String { rawValue }

    // How the Loop menu names these twelve items used to be spelled out here,
    // as `menuTitle(direction:tier:seconds:)`. The words now live on the
    // catalog rows — one place a title can be changed — and `ActionTitle`
    // appends the live amount. See `ActionCatalog`.
}

/// Where a loop-move lands.
///
/// **It is deliberately the same arithmetic the mouse uses.** Both edges go
/// through `TimelineHandles.resized` and the body through `TimelineHandles.moved`
/// — the functions Task 23 wrote for the drag — so the keyboard and the pointer
/// cannot drift apart on the two questions that matter here:
///
/// * **Inversion swaps, it does not clamp.** Pushing the in point past the out
///   point hands over to the other edge rather than stalling at zero length,
///   which is what Ableton and Logic do and what a drag here already did. See
///   `TimelineHandles.resized` for the full argument.
/// * **The body clamps as a whole**, so a loop pushed against an end of the file
///   stops there with its length intact rather than shrinking against the wall.
///
/// The seconds → frames conversion and its saturation go through
/// `NudgeStepping.target`, which is also what the playhead nudges and the
/// selection moves use, so a corrupted preference cannot trap here either.
public enum LoopMoving {

    /// - Parameter seconds: signed; negative moves left.
    /// - Returns: the loop unchanged when there is nothing meaningful to do —
    ///   an empty region, an empty file, or an unusable amount or sample rate.
    ///   A no-op rather than a guess, so the key does nothing visible instead of
    ///   something wrong.
    public static func moved(
        _ loop: LoopRegion, target: LoopMoveTarget, bySeconds seconds: Double,
        sampleRate: Double, totalFrames: FrameIndex
    ) -> LoopRegion {
        guard !loop.range.isEmpty, totalFrames > 0, seconds.isFinite, sampleRate > 0 else {
            return loop
        }
        let range: FrameRange
        switch target {
        case .inPoint:
            range = TimelineHandles.resized(
                anchor: loop.range.end,
                to: landing(from: loop.range.start, seconds, sampleRate, totalFrames),
                totalFrames: totalFrames)
        case .outPoint:
            range = TimelineHandles.resized(
                anchor: loop.range.start,
                to: landing(from: loop.range.end, seconds, sampleRate, totalFrames),
                totalFrames: totalFrames)
        case .whole:
            range = TimelineHandles.moved(
                loop.range,
                toStart: landing(from: loop.range.start, seconds, sampleRate, totalFrames),
                totalFrames: totalFrames)
        }
        return LoopRegion(range: range, isEnabled: loop.isEnabled)
    }

    private static func landing(
        from frame: FrameIndex, _ seconds: Double, _ sampleRate: Double,
        _ totalFrames: FrameIndex
    ) -> FrameIndex {
        NudgeStepping.target(
            from: frame, bySeconds: seconds, sampleRate: sampleRate, totalFrames: totalFrames)
    }
}
