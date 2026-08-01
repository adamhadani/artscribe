import ArtscribeKit
import CoreGraphics

/// The one gesture in the waveform lanes, and the three things it can turn out
/// to mean.
///
/// Split out of `ViewerModel+Interaction` — which is about the *view* (zoom,
/// pan, fit) — because this is about a **gesture's identity**: what a press
/// gets latched as, how a pinch takes it back, and what a release does when the
/// pointer never really moved. Those rules have bitten this project repeatedly
/// and are worth reading as one piece.
extension ViewerModel {

    // MARK: - The lane drag, and what it was decided to mean

    /// A left-drag in the waveform lanes: a handle, a selection, or an
    /// ⌥-modified zoom.
    ///
    /// **The precedence is `LaneDragMode`'s and it is written down there and in
    /// `TimelineHandles`.** In one line: ⌥ zooms and ⇧ extends wherever the
    /// pointer is; otherwise a loop or selection edge within its grab zone —
    /// or the loop's own top/bottom bar — is taken hold of; otherwise the drag
    /// starts a new selection exactly as it always has.
    ///
    /// **The mode is latched at mouse-down.** `option` and `shift` are read
    /// live from `NSEvent.modifierFlags` by the view, so they change the moment
    /// the user's finger does; without the latch, pressing ⌥ halfway through a
    /// selection would abandon the selection and start zooming instead, and
    /// releasing it mid-zoom would start selecting. What the gesture is gets
    /// decided once and holds.
    ///
    /// A gesture is recognised as new when it starts somewhere the live one did
    /// not. `DragGesture.Value.startLocation` is stable for one drag's whole
    /// lifetime, so this is self-correcting even if `laneDragEnded` never ran —
    /// the same reasoning `dragChanged` records for `dragOrigin`.
    public func laneDragChanged(start: CGPoint, current: CGPoint, option: Bool, shift: Bool) {
        guard hasTrack else { return }
        let mode: LaneDragMode
        if laneDragStart == start, let live = laneDragMode {
            mode = live
        } else {
            mode = LaneDragMode(
                option: option, shift: shift, handle: timelineHandle(at: start))
            laneDragStart = start
            laneDragMode = mode
            selectionBeforeLaneDrag = selection
            playheadBeforeLaneDrag = playhead
            laneDragCancelled = false
            // A new gesture never continues the previous one's zoom or handle
            // drag, even when the two began at the same point.
            zoomDrag = nil
            edgeDrag = nil
        }
        switch mode {
        case .select(let extending):
            dragChanged(startPixel: start.x, currentPixel: current.x, extending: extending)
        case .zoom:
            zoomDragChanged(start: start, current: current)
        case .edge(let handle):
            edgeDragChanged(handle: handle, startPixel: start.x, currentPixel: current.x)
        }
    }

    /// Ends a lane drag, on the terms it began on.
    ///
    /// A zoom drag must **not** fall through to `dragEnded`: an ⌥-drag that
    /// never really moved would otherwise be read as a click, seek the playhead
    /// and throw the selection away — and two of them as a double-click, which
    /// starts playing. A handle drag is excluded for exactly the same reason:
    /// taking hold of a loop edge and thinking better of it must not move the
    /// playhead, and two of them in a second must not start playback.
    ///
    /// With no latched mode this behaves exactly as it did before ⌥-drag
    /// existed, so an end that somehow arrives without a preceding change still
    /// runs the click logic.
    /// Abandons an in-flight lane drag and puts back what it changed.
    ///
    /// **What a pinch needs.** SwiftUI cannot tell a `DragGesture` how many
    /// fingers are down, so the first finger of a pinch starts a selection and
    /// the second cannot cancel it. The pinch is attached `simultaneous`
    /// deliberately — an exclusive one would let the drag win outright — which
    /// leaves this as the way to undo what it began.
    ///
    /// Restoring selection and playhead is only half. The other half is
    /// `laneDragCancelled`: the gesture still delivers its `onEnded`, and without
    /// the flag that end runs the click path — seeking to wherever the pinch
    /// started, and reading two pinches in a second as a double-click, which
    /// starts playback.
    public func cancelLaneDrag() {
        guard laneDragMode != nil else { return }
        if let previous = selectionBeforeLaneDrag { selection = previous }
        if let previous = playheadBeforeLaneDrag { seek(to: previous) }
        selectionBeforeLaneDrag = nil
        playheadBeforeLaneDrag = nil
        laneDragMode = nil
        laneDragStart = nil
        dragOrigin = nil
        zoomDrag = nil
        edgeDrag = nil
        laneDragCancelled = true
        refresh()
    }

    public func laneDragEnded(start: CGPoint, end: CGPoint, now: Double) {
        // A cancelled drag still gets its `onEnded`. Swallow it once — the flag
        // is cleared here rather than in `cancelLaneDrag` so exactly one end is
        // absorbed and the next real gesture is unaffected.
        if laneDragCancelled {
            laneDragCancelled = false
            return
        }
        let mode = laneDragMode
        laneDragStart = nil
        laneDragMode = nil
        selectionBeforeLaneDrag = nil
        playheadBeforeLaneDrag = nil
        switch mode {
        case .zoom:
            zoomDragEnded()
        case .edge:
            edgeDragEnded()
        case .select, nil:
            dragEnded(startPixel: start.x, endPixel: end.x, now: now)
        }
    }

    public func fitWholeFile() {
        guard hasTrack else { return }
        viewport.fit()
        refresh()
    }

    /// `⌘9`. Fills the view with the selection — or, failing that, the loop.
    ///
    /// **The selection wins when there is one**, because it is the more
    /// transient of the two: you drag a selection out to look at something, and
    /// a loop you set ten minutes ago should not override what you just did.
    /// With no selection the loop is the only passage the user has named, and
    /// zooming to it is obviously what was meant — the alternative, which is
    /// what this used to do, was nothing at all, on the one key whose whole job
    /// is "show me the bit I care about".
    ///
    /// The loop counts whether or not it is *engaged*: its range is a marked
    /// passage either way, and refusing to zoom to a loop you can plainly see
    /// because playback is not currently cycling it would be a distinction
    /// without a difference.
    public func zoomToSelection() {
        guard hasTrack, let range = zoomTarget else { return }
        viewport.zoom(to: range)
        refresh()
    }

    /// What `⌘9` would zoom to, or `nil` when there is nothing to zoom to.
    ///
    /// Separate so the menu item can grey itself out on exactly the condition
    /// the command acts on, rather than on a second copy of the rule that can
    /// drift from it.
    public var zoomTarget: FrameRange? {
        if !selection.isEmpty { return selection.range }
        if !loop.range.isEmpty { return loop.range }
        return nil
    }

    public func scrollLeft() { scroll(byPoints: -panStep) }
    public func scrollRight() { scroll(byPoints: panStep) }

    public func scroll(byPoints points: Int) {
        guard hasTrack, points != 0 else { return }
        viewport.scroll(byPixels: points)
        refresh()
    }

    /// Centres the viewport on `frame`, used by the overview strip.
    public func centre(on frame: FrameIndex) {
        guard hasTrack else { return }
        let delta = viewport.pixel(forFrame: frame) - Double(lanePointWidth) / 2
        scroll(byPoints: Int(delta.rounded()))
    }

    private var panStep: Int {
        Swift.max(1, Int((Double(lanePointWidth) * Self.panFraction).rounded()))
    }
}
