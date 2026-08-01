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

    /// Pinch-to-zoom on the waveform lanes.
    ///
    /// `x` is in the **lanes' own** coordinate space, not the window's — which is
    /// why this exists rather than the view calling `zoom(by:at:)`. That one
    /// takes a window point because a pointer can be over the lanes, the
    /// overview strip, or neither; a pinch arrives already attached to the view
    /// it happened on, so the hit-testing step is not merely unnecessary but
    /// wrong: converting to window coordinates and back can land the anchor in
    /// the overview strip when the lanes are short.
    ///
    /// The mapping is direct — `Viewport.zoom(by:)` treats a factor above 1 as
    /// zooming in, and so does `MagnifyGesture.magnification`. Anchoring on the
    /// frame under the fingers is the whole point: a pinch that anchored on the
    /// playhead would slide the passage you are pinching out from under them.
    public func pinchZoom(by factor: Double, atLaneX x: CGFloat) {
        guard hasTrack, factor > 0, factor.isFinite, x.isFinite else { return }
        zoom(by: factor, anchorFrame: PixelMapping.frame(atPixel: x, in: viewport))
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
                // **Not on touch.** See `LaneDragPolicy`: a finger going down is
                // the start of a gesture nobody has decided the meaning of yet,
                // and seeking there interrupts playback exactly when someone is
                // reaching for a passage to mark. A tap still seeks, from
                // `dragEnded`.
                //
                // `seek`, not a bare assignment: with playback wired, moving the
                // playhead without telling the engine would have the next display
                // poll snap it straight back.
                if prefs.seeksOnSelectionPress { seek(to: frame) }
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
