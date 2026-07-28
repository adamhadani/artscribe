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
    /// "This region's leading edge can be moved." Task 23.
    case resizeRegionLeading
    /// "…and this is its trailing edge."
    ///
    /// `frameResize(position:)` rather than `columnResize(directions:)`, which
    /// was the alternative. A column resize means *the divider between two
    /// panes moves and the space is redistributed between them* — there is a
    /// neighbour on the other side that gives up what this one gains. A loop
    /// region has no such neighbour: it is a bounded frame on the timeline
    /// being resized from one of its own edges, which is the exact situation
    /// `frameResize` is named for. It also carries the *position*, so macOS
    /// draws an edge-appropriate arrow and the cursor says which end of the
    /// region is under the hand — information `columnResize` cannot express.
    case resizeRegionTrailing
    /// "The whole loop can be picked up and moved." The open hand, which is
    /// what macOS uses everywhere for "this object moves with you".
    case moveRegion
    /// The same, with the hand closed, while it is actually being moved.
    case movingRegion

    /// The scheme, in one function.
    ///
    /// - Parameters:
    ///   - optionHeld: read live, so pressing or releasing ⌥ changes the answer
    ///     under a stationary pointer. This is the half most likely to be got
    ///     wrong — a cursor that only updates on entry leaves the modifier
    ///     invisible until the user has already committed to a drag.
    ///   - shiftHeld: read live for the same reason, and it matters for the
    ///     same reason: with ⇧ down a drag extends the selection *even on top
    ///     of a loop edge*, so a resize cursor there would be a lie.
    ///   - laneDrag: the lane gesture in flight, if any. It **wins over the
    ///     modifier**, because `LaneDragMode` latches at mouse-down and holds:
    ///     releasing ⌥ mid-zoom keeps zooming, so a cursor that snapped back to
    ///     the crosshair would be describing a gesture that is not happening.
    ///   - hovering: the handle under the pointer, if any. Ranked below both
    ///     modifiers, exactly as `LaneDragMode`'s precedence ranks it, so the
    ///     cursor and the gesture can never disagree.
    static func over(
        _ region: PointerRegion,
        optionHeld: Bool,
        shiftHeld: Bool = false,
        laneDrag: LaneDragMode?,
        hovering: TimelineHandle? = nil
    ) -> PointerAffordance {
        switch region {
        case .timeRuler:
            // The ruler's only gesture is the zoom drag and it takes no
            // modifier, so no argument can change this. Task 23 deliberately
            // added nothing here: the ruler's whole surface is claimed by a
            // modifier-free vertical drag, and carving grab zones out of it at
            // the loop edges would break that zoom exactly where the loop is.
            return .verticalDrag
        case .waveformLanes:
            switch laneDrag {
            case .zoom: return .zoom
            case .select: return .selectRange
            case .edge(let handle): return forHandle(handle, dragging: true)
            case nil:
                if optionHeld { return .zoom }
                if shiftHeld { return .selectRange }
                guard let hovering else { return .selectRange }
                return forHandle(hovering, dragging: false)
            }
        }
    }

    private static func forHandle(
        _ handle: TimelineHandle, dragging: Bool
    ) -> PointerAffordance {
        switch handle.side {
        case .leading: return .resizeRegionLeading
        case .trailing: return .resizeRegionTrailing
        case nil: return dragging ? .movingRegion : .moveRegion
        }
    }

    /// The one-line translation into SwiftUI's opaque type. Everything worth
    /// deciding was decided above.
    var pointerStyle: PointerStyle {
        switch self {
        case .verticalDrag: return .rowResize
        case .zoom: return .zoomIn
        case .selectRange: return .rectSelection
        case .resizeRegionLeading: return .frameResize(position: .leading)
        case .resizeRegionTrailing: return .frameResize(position: .trailing)
        case .moveRegion: return .grabIdle
        case .movingRegion: return .grabActive
        }
    }
}
