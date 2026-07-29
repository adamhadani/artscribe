import ArtscribeKit
import CoreGraphics

/// The loop and selection edges, dragged (Task 23).
///
/// The arithmetic is all in `TimelineHandles`, which is pure and tested on its
/// own; what lives here is the state machine — latching what was grabbed at
/// mouse-down and holding it, so that an edge dragged past its opposite number
/// keeps following the pointer instead of becoming a different gesture.
///
/// A loop edge dragged during playback goes through `applyLoop`, which is the
/// app's one and only `PlaybackCommand.setLoop` path. That is deliberate: the
/// engine wraps at the boundary it is fed and never resets the stretcher there
/// (spec §5.1), so an edge moved mid-loop takes effect on the next pass with no
/// click and no dropout. There is no second path to invent.
extension ViewerModel {

    /// What the guide line, the live readout and the cursor draw from while an
    /// edge or the loop body is being dragged. `nil` between gestures.
    ///
    /// Observed, unlike `laneDragStart` and `zoomDrag`: the readout has to
    /// follow the pointer, so this one really is drawn from. It is written once
    /// per pointer event, which is the rate the selection and the loop are
    /// already written at during any drag.
    public struct EdgeDrag: Equatable, Sendable {
        public let handle: TimelineHandle
        /// Where the gesture began, which is what identifies it across events —
        /// the same reasoning `dragChanged` records for `dragOrigin`.
        let startPixel: Double
        /// The edge that stays put. `nil` for a body drag, which pivots on
        /// nothing.
        let anchorFrame: FrameIndex?
        /// Body drag: the region as it stood at mouse-down, and how far into it
        /// the pointer took hold.
        let originalRange: FrameRange
        let grabOffset: FrameIndex
        /// The frame the guide and the readout show: the moving edge, or the
        /// region's new start for a body drag.
        public internal(set) var currentFrame: FrameIndex

        /// Which side of the region the guide is on *now*.
        ///
        /// Recomputed rather than latched, because a drag past the opposite edge
        /// swaps them: the in point you grabbed is the out point you are now
        /// holding, and the wash has to fall the other way.
        public var side: TimelineEdgeSide? {
            guard let anchorFrame else { return nil }
            return currentFrame <= anchorFrame ? .leading : .trailing
        }
    }

    /// The handle under a point in the lanes, for the hover treatment and the
    /// cursor. Answers `nil` with no track, so an empty window offers nothing.
    public func timelineHandle(at point: CGPoint) -> TimelineHandle? {
        guard hasTrack else { return nil }
        return TimelineHandles.handle(
            at: point, laneHeight: lanePointHeight, loop: loop, selection: selection,
            viewport: viewport)
    }

    /// One event of a handle drag.
    ///
    /// The grabbed handle, its anchor and the region's original length are all
    /// read **once**, on the gesture's first event. Re-reading them per event
    /// would chase a moving target — after the first event the loop is no longer
    /// where it was — and would turn a drag past the opposite edge into an
    /// edge that ran away from the pointer.
    func edgeDragChanged(handle: TimelineHandle, startPixel: Double, currentPixel: Double) {
        guard hasTrack else { return }
        var drag =
            liveEdgeDrag(handle: handle, startPixel: startPixel)
            ?? beganEdgeDrag(handle: handle, atPixel: startPixel)
        let pointer = PixelMapping.frame(atPixel: currentPixel, in: viewport)
        switch handle {
        case .loopStart, .loopEnd:
            let range = TimelineHandles.resized(
                anchor: drag.anchorFrame ?? pointer, to: pointer, totalFrames: totalFrames)
            applyLoop(LoopRegion(range: range, isEnabled: loop.isEnabled))
            drag.currentFrame = pointer
        case .loopBody:
            let range = TimelineHandles.moved(
                drag.originalRange, toStart: pointer - drag.grabOffset, totalFrames: totalFrames)
            applyLoop(LoopRegion(range: range, isEnabled: loop.isEnabled))
            drag.currentFrame = range.start
        case .selectionStart, .selectionEnd:
            // Through `Selection`'s own anchor/head, so a region dragged past
            // its opposite edge normalises exactly as a backwards drag does.
            selection = Selection(anchor: drag.anchorFrame ?? pointer, head: pointer)
            drag.currentFrame = pointer
        }
        edgeDrag = drag
    }

    func edgeDragEnded() {
        edgeDrag = nil
    }

    /// The gesture already in flight, when this event belongs to it.
    ///
    /// Identified by its start point and its handle rather than by "is there
    /// one?", so a gesture whose end phase never ran — a cancelled drag, or one
    /// another recognizer took — cannot leak its anchor into the next drag. The
    /// same self-correcting shape as `dragChanged`'s `dragOrigin` check.
    private func liveEdgeDrag(handle: TimelineHandle, startPixel: Double) -> EdgeDrag? {
        guard let live = edgeDrag, live.handle == handle, live.startPixel == startPixel else {
            return nil
        }
        return live
    }

    private func beganEdgeDrag(handle: TimelineHandle, atPixel pixel: Double) -> EdgeDrag {
        let grabbed = PixelMapping.frame(atPixel: pixel, in: viewport)
        let region = handle.isLoop ? loop.range : selection.range
        return EdgeDrag(
            handle: handle,
            startPixel: pixel,
            anchorFrame: TimelineHandles.anchor(for: handle, loop: loop, selection: selection),
            originalRange: region,
            grabOffset: grabbed - region.start,
            currentFrame: handle == .loopBody ? region.start : grabbed)
    }
}
