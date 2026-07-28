import SwiftUI

/// The parts of the timeline that answer the pointer differently.
///
/// Only two, and deliberately so: the overview strip and the transport bar are
/// clickable in the ordinary way and an arrow says that correctly. A cursor
/// that changes everywhere stops meaning anything.
enum PointerRegion: Equatable, Sendable {
    case timeRuler
    case waveformLanes
}

/// What the pointer should say this region can do.
///
/// Named for the *intent* rather than for the cursor artwork, because the
/// artwork is the part most likely to be reconsidered and the intent is not.
///
/// It exists as a value type at all because `SwiftUI.PointerStyle` is opaque
/// and not `Equatable`: there is no way to read back which style a view was
/// handed, so a scheme expressed only in `body` could not be tested. The
/// decision lives here — where `PointerAffordanceTests` pins all ten
/// combinations — and the view does nothing but translate it.
enum PointerAffordance: Equatable, Sendable {
    /// "This can be dragged, and vertically." Drawn as the row-resize arrows,
    /// which is the one cursor macOS has that means exactly that.
    case verticalDrag
    /// "This drag changes the zoom." Drawn as the magnifier.
    ///
    /// `zoomIn` rather than a neutral magnifier because macOS ships no neutral
    /// one — the choice is `zoomIn`, `zoomOut` or nothing. The drag runs both
    /// ways, so the `+` slightly over-promises; what it buys is that the
    /// *subject* of the gesture is unmistakable the moment ⌥ goes down, which
    /// is the thing nobody could otherwise discover. Alternating it with
    /// `zoomOut` by drag direction was considered and rejected: the cursor
    /// would flicker at the turning point of every drag.
    case zoom
    /// "Drag out a passage." Drawn as the crosshair.
    ///
    /// `rectSelection`, not the bare crosshair: it is the named affordance for
    /// dragging out a region, which is precisely what a plain lane drag does,
    /// and it resolves to the same crosshair artwork anyway.
    case selectRange

    /// The scheme, in one function.
    ///
    /// - Parameters:
    ///   - optionHeld: read live, so pressing or releasing ⌥ changes the answer
    ///     under a stationary pointer. This is the half most likely to be got
    ///     wrong — a cursor that only updates on entry leaves the modifier
    ///     invisible until the user has already committed to a drag.
    ///   - laneDrag: the lane gesture in flight, if any. It **wins over the
    ///     modifier**, because `LaneDragMode` latches at mouse-down and holds:
    ///     releasing ⌥ mid-zoom keeps zooming, so a cursor that snapped back to
    ///     the crosshair would be describing a gesture that is not happening.
    static func over(
        _ region: PointerRegion, optionHeld: Bool, laneDrag: LaneDragMode?
    ) -> PointerAffordance {
        switch region {
        case .timeRuler:
            // The ruler's only gesture is the zoom drag and it takes no
            // modifier, so neither argument can change this.
            return .verticalDrag
        case .waveformLanes:
            switch laneDrag {
            case .zoom: return .zoom
            case .select: return .selectRange
            case nil: return optionHeld ? .zoom : .selectRange
            }
        }
    }

    /// The one-line translation into SwiftUI's opaque type. Everything worth
    /// deciding was decided above.
    var pointerStyle: PointerStyle {
        switch self {
        case .verticalDrag: return .rowResize
        case .zoom: return .zoomIn
        case .selectRange: return .rectSelection
        }
    }
}
