import ArtscribeKit

/// Commands sent from the main actor to the render thread.
///
/// Every payload is trivial (Int64/Double/Bool) -- no reference types, no ARC traffic --
/// which is what makes it safe for `CommandRing` to store and move these values through
/// raw memory on the render thread. This is a real invariant, not just a comment: a case
/// carrying a class-typed payload would compile fine today (there is nothing in
/// `CommandRing` that rejects it) but would introduce a retain/release on `pop()`'s path,
/// silently violating the "no ARC on the render thread" requirement.
///
/// True compiler enforcement of this (conforming to `BitwiseCopyable`) was considered and
/// rejected for this task: `FrameRange`'s associated value would also need that
/// conformance, and `BitwiseCopyable` conformance can only be declared in the type's own
/// defining module (`ArtscribeKit`), which is out of this task's scope. If a future task
/// owns `ArtscribeKit` again, adding `extension FrameRange: BitwiseCopyable {}` there and
/// then `BitwiseCopyable` to this enum's conformance list would upgrade this comment into
/// an enforced compile-time guarantee.
public enum PlaybackCommand: Equatable, Sendable {
    case seek(FrameIndex)
    case setTimeRatio(Double)
    case setLoop(FrameRange, Bool)
    case setPlaying(Bool)
}
