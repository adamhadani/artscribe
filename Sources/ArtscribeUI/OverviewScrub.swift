import CoreGraphics

/// A drag on the overview strip, as a value.
///
/// ## Why the strip needed a state machine at all
///
/// It used to centre the viewport on wherever the finger was, on every event
/// including the first. With a mouse that reads as "click to go there", which is
/// fine. With a **finger on the lens** it is wrong twice over: the view
/// teleports the instant you touch it — the lens jumps out from under the
/// fingertip that was aiming at it — and from then on the strip is an absolute
/// position control rather than something you are carrying. Reported from an
/// iPhone as *"an initial jerk, but it doesn't let me swipe around"*, which is
/// exactly those two halves.
///
/// So: **a drag that starts inside the lens carries it**, at a fixed offset,
/// with no jump at all. A drag that starts outside jumps there first — that is
/// the "click to go there" the strip has always had, and it is what every
/// scrubber with a visible thumb does — and then carries it from there.
///
/// Pure, so both readings are testable without a window: the whole gesture is
/// `begin` plus a `centrePixel(for:)` per event.
struct OverviewScrub: Equatable {

    /// Strip pixels between where the finger went down and the lens centre it
    /// took hold of. Zero when the drag started outside the lens, which is what
    /// makes that case jump on its first event and carry after.
    let grabOffset: Double

    /// Whether the finger landed on the lens. Only used for the reason above;
    /// kept so a test can say which branch it is exercising.
    let grabbedLens: Bool

    /// - Parameters:
    ///   - x: where the finger went down, in the strip's own coordinates.
    ///   - lensCentre: the centre of the visible-window rectangle, same space.
    ///   - lensWidth: its width. A fully zoomed-out lens covers the whole strip,
    ///     so *every* touch is inside it — and carrying it is a no-op, because
    ///     there is nowhere to scroll. That is the right answer rather than a
    ///     case to special-case: the view does not move, and nothing jumps.
    init(startPixel x: Double, lensCentre: Double, lensWidth: Double) {
        // A minimum grab width, because the lens is drawn with a 2pt floor and a
        // deeply zoomed-in lens is a hairline nobody can put a fingertip on. 44
        // is the HIG's minimum touch target; using it here means the *drawn*
        // hairline still behaves like something you can take hold of.
        let grabWidth = Swift.max(lensWidth, Self.minimumGrabWidth)
        let inside = abs(x - lensCentre) <= grabWidth / 2
        grabbedLens = inside
        grabOffset = inside ? x - lensCentre : 0
    }

    static let minimumGrabWidth: Double = 44

    /// Where the viewport centre should be, for a finger now at `x`.
    func centrePixel(for x: Double) -> Double { x - grabOffset }
}
