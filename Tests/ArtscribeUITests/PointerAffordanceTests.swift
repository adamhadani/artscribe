import Testing

@testable import ArtscribeUI

/// The region → cursor mapping, which is the whole of the pointer affordance
/// that can be tested: `SwiftUI.PointerStyle` is opaque and not `Equatable`, so
/// what a view was handed cannot be read back. The decision therefore lives in
/// `PointerAffordance` and the view does nothing but translate it.
///
/// Two properties are worth guarding. The **modifier is live** — ⌥ changes the
/// answer with no drag in flight, which is what makes the cursor flip under a
/// stationary pointer. And the **latch wins over the modifier** once a drag has
/// begun, exactly as `LaneDragMode` does: a cursor that reverted to the
/// selection crosshair the instant ⌥ was let go would be telling the user the
/// opposite of what the gesture is still doing.
@Suite("Pointer affordance")
struct PointerAffordanceTests {

    // MARK: - The ruler

    /// The ruler's only gesture is the vertical zoom drag, and it takes no
    /// modifier — so nothing about the keyboard can change what it offers.
    @Test func rulerAlwaysOffersTheVerticalDrag() {
        for option in [false, true] {
            #expect(
                PointerAffordance.over(.timeRuler, optionHeld: option, laneDrag: nil)
                    == .verticalDrag)
        }
    }

    /// A lane drag in flight belongs to the lanes; it must not reach across and
    /// change what the ruler says.
    @Test func rulerIgnoresALaneDragInFlight() {
        for drag: LaneDragMode? in [.zoom, .select(extending: false), .select(extending: true)] {
            #expect(
                PointerAffordance.over(.timeRuler, optionHeld: false, laneDrag: drag)
                    == .verticalDrag)
        }
    }

    // MARK: - The lanes, with nothing in flight

    @Test func lanesOfferSelectionByDefault() {
        #expect(
            PointerAffordance.over(.waveformLanes, optionHeld: false, laneDrag: nil)
                == .selectRange)
    }

    /// The point of the whole exercise: ⌥ down, pointer stationary, cursor
    /// changes. If this returned `.selectRange` the modifier would be invisible
    /// until the user committed to a drag and found out the hard way.
    @Test func optionOverTheLanesOffersZoom() {
        #expect(
            PointerAffordance.over(.waveformLanes, optionHeld: true, laneDrag: nil) == .zoom)
    }

    /// Both directions, since the bug this guards is a cursor that changes on ⌥
    /// down and then sticks.
    @Test func releasingOptionOverTheLanesGoesBackToSelection() {
        var affordance = PointerAffordance.over(
            .waveformLanes, optionHeld: true, laneDrag: nil)
        #expect(affordance == .zoom)
        affordance = PointerAffordance.over(.waveformLanes, optionHeld: false, laneDrag: nil)
        #expect(affordance == .selectRange)
    }

    // MARK: - The lanes, with a drag in flight

    /// `LaneDragMode` latches at mouse-down and holds; the cursor has to follow
    /// the latch, not the live modifier, or it contradicts the gesture.
    @Test func aZoomDragKeepsTheZoomCursorAfterOptionIsReleased() {
        #expect(
            PointerAffordance.over(.waveformLanes, optionHeld: false, laneDrag: .zoom) == .zoom)
    }

    /// And the other way about: ⌥ pressed halfway through a selection does not
    /// abandon the selection, so it must not promise a zoom either.
    @Test func aSelectionDragKeepsTheCrosshairWhenOptionGoesDown() {
        for extending in [false, true] {
            #expect(
                PointerAffordance.over(
                    .waveformLanes, optionHeld: true, laneDrag: .select(extending: extending))
                    == .selectRange)
        }
    }

    // MARK: - The handles (Task 23)

    /// The affordance has to appear on **hover**, not once the drag has begun:
    /// an edge that only admits it is draggable after you have committed to
    /// dragging it is not discoverable at all.
    @Test func hoveringAnEdgeOffersTheFrameResize() {
        #expect(
            PointerAffordance.over(
                .waveformLanes, optionHeld: false, laneDrag: nil,
                hovering: .loopStart) == .resizeRegionLeading)
        #expect(
            PointerAffordance.over(
                .waveformLanes, optionHeld: false, laneDrag: nil,
                hovering: .loopEnd) == .resizeRegionTrailing)
        #expect(
            PointerAffordance.over(
                .waveformLanes, optionHeld: false, laneDrag: nil,
                hovering: .selectionStart) == .resizeRegionLeading)
        #expect(
            PointerAffordance.over(
                .waveformLanes, optionHeld: false, laneDrag: nil,
                hovering: .selectionEnd) == .resizeRegionTrailing)
    }

    /// The loop body opens the hand on hover and closes it while moving —
    /// macOS's own two-state grab, and the only pair here that changes between
    /// hover and drag.
    @Test func theLoopBodyOpensAndClosesTheHand() {
        #expect(
            PointerAffordance.over(
                .waveformLanes, optionHeld: false, laneDrag: nil,
                hovering: .loopBody) == .moveRegion)
        #expect(
            PointerAffordance.over(.waveformLanes, optionHeld: false, laneDrag: .edge(.loopBody))
                == .movingRegion)
    }

    /// Both modifiers outrank a handle, exactly as `LaneDragMode`'s precedence
    /// does. A resize cursor over an edge with ⌥ or ⇧ down would be promising a
    /// gesture that cannot happen.
    @Test func modifiersOutrankAHoveredHandle() {
        #expect(
            PointerAffordance.over(
                .waveformLanes, optionHeld: true, laneDrag: nil,
                hovering: .loopStart) == .zoom)
        #expect(
            PointerAffordance.over(
                .waveformLanes, optionHeld: false, shiftHeld: true,
                laneDrag: nil, hovering: .loopStart) == .selectRange)
    }

    /// And the latch outranks everything, as it already did for the zoom: the
    /// pointer may wander off the edge mid-drag, but the drag is still a resize.
    @Test func aHandleDragKeepsItsCursorWhenThePointerLeavesTheEdge() {
        #expect(
            PointerAffordance.over(
                .waveformLanes, optionHeld: true, shiftHeld: true,
                laneDrag: .edge(.loopEnd), hovering: nil) == .resizeRegionTrailing)
    }

    /// The ruler took on no handle gesture in Task 23 — its whole surface is
    /// claimed by a modifier-free vertical zoom drag — so a handle reported
    /// under the pointer must not change what it says.
    @Test func theRulerIgnoresHandlesEntirely() {
        for handle in TimelineHandle.allCases {
            #expect(
                PointerAffordance.over(
                    .timeRuler, optionHeld: false, laneDrag: nil,
                    hovering: handle) == .verticalDrag)
        }
    }

    // MARK: - The full table

    /// Every combination in one place, so a change to the scheme has to be made
    /// deliberately rather than by adjusting whichever test failed.
    @Test(arguments: [
        (PointerRegion.timeRuler, false, LaneDragMode?.none, PointerAffordance.verticalDrag),
        (.timeRuler, true, nil, .verticalDrag),
        (.waveformLanes, false, nil, .selectRange),
        (.waveformLanes, true, nil, .zoom),
        (.waveformLanes, false, .zoom, .zoom),
        (.waveformLanes, true, .zoom, .zoom),
        (.waveformLanes, false, .select(extending: false), .selectRange),
        (.waveformLanes, true, .select(extending: false), .selectRange),
        (.waveformLanes, false, .select(extending: true), .selectRange),
        (.waveformLanes, true, .select(extending: true), .selectRange)
    ])
    func theWholeScheme(
        region: PointerRegion, option: Bool, drag: LaneDragMode?, expected: PointerAffordance
    ) {
        #expect(PointerAffordance.over(region, optionHeld: option, laneDrag: drag) == expected)
    }
}
