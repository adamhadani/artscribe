import ArtscribeKit
import CoreGraphics

/// Everything the user can do to the view: zoom, pan, and select.
///
/// Split out of `ViewerModel` so the state and loading half stays readable. All
/// of it is deliberately guarded — calling any of these without a loaded track,
/// or with an empty selection, is a no-op rather than an error, because the menu
/// bar can invoke them at any time.
extension ViewerModel {

    public func zoomIn() { zoom(by: Self.zoomStep) }
    public func zoomOut() { zoom(by: 1 / Self.zoomStep) }

    /// Zoom always anchors on the playhead (or the selection start when there is
    /// one) — never the viewport centre, which slides the thing you are looking
    /// at out from under the pointer.
    public var zoomAnchor: FrameIndex {
        selection.isEmpty ? playhead : selection.range.start
    }

    public func zoom(by factor: Double, anchorFrame: FrameIndex? = nil) {
        guard hasTrack else { return }
        viewport.zoom(by: factor, anchorFrame: anchorFrame ?? zoomAnchor)
        refresh()
    }

    /// Zoom driven by the pointer — a wheel, a pinch, or a `⌘`-scroll.
    ///
    /// It anchors on the frame under the pointer, not on the playhead: a
    /// cursor-driven zoom that anchors elsewhere slides the thing you are
    /// pointing at out from under you. Over the overview strip the anchor is a
    /// frame in the *whole file* and it is still the main viewport that zooms —
    /// the strip is always fitted. With the pointer over neither lane (or before
    /// the first layout pass) this is exactly `zoom(by:)`, playhead-anchored.
    ///
    /// - Parameter point: pointer position in window content coordinates.
    public func zoom(by factor: Double, at point: CGPoint?) {
        guard hasTrack else { return }
        guard
            let point,
            let target = PointerZoom.target(at: point, lanes: laneFrame, overview: overviewFrame)
        else {
            zoom(by: factor)
            return
        }
        switch target {
        case .lanes(let x):
            zoom(by: factor, anchorFrame: PixelMapping.frame(atPixel: x, in: viewport))
        case .overview(let x):
            zoom(
                by: factor,
                anchorFrame: PixelMapping.overviewFrame(
                    atPixel: x, totalFrames: totalFrames, width: overviewFrame.width))
        }
    }

    // MARK: - Drag to zoom

    /// How far the drag-to-zoom travels per doubling. Published so the
    /// acceptance run can assert the *rate* a real pointer drag produces rather
    /// than its direction alone: a `.local` coordinate space that arrived
    /// scaled or offset would still zoom, and only the number catches it.
    public static var zoomDragPointsPerDoubling: Double { ZoomDrag.pointsPerDoubling }

    /// A vertical drag that zooms, smoothly and continuously: bare on the time
    /// ruler, ⌥-modified in the waveform lanes. See `ZoomDrag` for the maths
    /// and the direction, and for why the natural-scrolling preference does not
    /// enter into a drag.
    ///
    /// - Parameters:
    ///   - start: where the drag began, local to the dragged view. Its `x` is
    ///     the anchor: the frame under it when the mouse went down stays under
    ///     it for the whole gesture.
    ///   - current: where the pointer is now, in the same space. Only `y` is
    ///     used. **Horizontal travel is deliberately ignored** rather than
    ///     panning as Ableton's ruler does: the gesture's whole contract is
    ///     that the frame under the cursor holds still, and panning at the same
    ///     time would slide it out from under the pointer — as would any
    ///     sideways wobble during what the hand meant as a vertical drag. The
    ///     app has three other ways to pan.
    public func zoomDragChanged(start: CGPoint, current: CGPoint) {
        guard hasTrack else { return }
        var gesture =
            liveZoomDrag(startingAt: start)
            ?? ZoomDrag(
                start: start,
                anchorFrame: PixelMapping.frame(atPixel: start.x, in: viewport),
                startFramesPerPixel: viewport.framesPerPixel,
                // Latched with the gesture, not read per event: see `ZoomDrag`.
                inverted: prefs.invertZoomDrag)
        defer { zoomDrag = gesture }
        guard
            let factor = gesture.factor(
                atY: current.y, currentFramesPerPixel: viewport.framesPerPixel)
        else { return }
        zoom(by: factor, anchorFrame: gesture.anchorFrame)
        gesture.appliedFramesPerPixel = viewport.framesPerPixel
    }

    /// The gesture already in flight, when this event belongs to it: same start
    /// point, and nothing else has moved the viewport since its last event.
    /// `nil` otherwise, which starts a fresh gesture from wherever the viewport
    /// now is — see `ZoomDrag.appliedFramesPerPixel`.
    private func liveZoomDrag(startingAt start: CGPoint) -> ZoomDrag? {
        guard let live = zoomDrag, live.start == start else { return nil }
        return live.appliedFramesPerPixel == viewport.framesPerPixel ? live : nil
    }

    public func zoomDragEnded() {
        zoomDrag = nil
    }

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
    public func laneDragEnded(start: CGPoint, end: CGPoint, now: Double) {
        let mode = laneDragMode
        laneDragStart = nil
        laneDragMode = nil
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

    // MARK: - Selection

    public func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
    }

    public func selectAll() {
        guard hasTrack else { return }
        selection.begin(at: 0)
        selection.extend(to: totalFrames)
    }

    /// A drag in the waveform lane. `extending` is shift-drag: it keeps the
    /// existing anchor and moves only the head.
    ///
    /// The "is this a new drag" check compares against `startPixel` rather than
    /// testing `dragOrigin == nil`. `DragGesture.Value.startLocation` is stable
    /// for the whole lifetime of one drag, so a mismatch always means a new
    /// gesture started — this is self-correcting even if `dragEnded` never ran
    /// (a cancelled gesture, or another gesture winning the recognizer race),
    /// where a nil-only check would leave `dragOrigin` stuck from the previous
    /// drag and silently extend its selection from a stale anchor.
    public func dragChanged(startPixel: Double, currentPixel: Double, extending: Bool) {
        guard hasTrack else { return }
        if dragOrigin != startPixel {
            dragOrigin = startPixel
            if extending && !selection.isEmpty {
                // Keep the anchor; the head follows the pointer.
            } else {
                let frame = PixelMapping.frame(atPixel: startPixel, in: viewport)
                selection.begin(at: frame)
                // `seek`, not a bare assignment: with playback wired, moving the
                // playhead without telling the engine would have the next display
                // poll snap it straight back.
                seek(to: frame)
            }
        }
        selection.extend(to: PixelMapping.frame(atPixel: currentPixel, in: viewport))
    }

    /// Ends a drag. A drag that never really moved is a click: it places the
    /// playhead and clears the selection, and two of them in quick succession do
    /// that **and start playing from there**.
    ///
    /// Double-click was Select All until Task 22. `⌘A` still is, so nothing was
    /// lost — only the gesture was reassigned, to the thing a transcriber
    /// actually wants from pointing at a spot twice.
    ///
    /// It plays from the click point and from nowhere else. In particular it is
    /// **not** routed through `PlaybackStart`, which is what `⇧Space` uses: that
    /// rule picks a start when the user has not named one, and a double-click
    /// names one. Aiming it at a selection or a loop's in point would make the
    /// pointer land somewhere the finger did not.
    ///
    /// The playhead is placed before playing, so `play`'s end-of-file rewind sees
    /// the clicked position rather than the one being left behind.
    ///
    /// **And the engine honours it.** Task 22 decided that a double-click outside
    /// an active loop should still be pulled into the region; the user overruled
    /// that in Task 24, having also found it behaved differently before the loop
    /// than after it. `PlaybackEngine.feedSource` now captures on *arrival* only,
    /// so all three cases read the same way and match Ableton and Logic:
    ///
    /// - click **before** the loop → plays from the click, runs on, is captured
    ///   at the out point, then loops;
    /// - click **inside** → plays from the click and loops normally;
    /// - click **after** → plays from the click to the end of the file.
    ///
    /// Nothing here clears or disables the loop, so no state the user set on
    /// purpose is destroyed by a transient click: the loop is still on, still
    /// drawn, and `F` puts playback back inside it in one key.
    ///
    /// The `dragOrigin` reset here is a courtesy, not the correctness
    /// mechanism — see `dragChanged`, which recovers on its own if this never
    /// runs.
    public func dragEnded(startPixel: Double, endPixel: Double, now: Double) {
        defer { dragOrigin = nil }
        guard hasTrack else { return }
        guard abs(endPixel - startPixel) < Self.clickSlopPoints else {
            lastClick = nil
            return
        }
        // Cleared, not advanced: consuming it is what stops a third click from
        // chaining into another double-click.
        let isDouble = isSecondClick(at: endPixel, now: now)
        lastClick = isDouble ? nil : (endPixel, now)
        seek(to: PixelMapping.frame(atPixel: endPixel, in: viewport))
        selection.clear()
        if isDouble { play() }
    }

    private func isSecondClick(at pixel: Double, now: Double) -> Bool {
        guard let previous = lastClick else { return false }
        return now - previous.time < Self.doubleClickSeconds
            && abs(previous.pixel - pixel) < Self.clickSlopPoints
    }
}
