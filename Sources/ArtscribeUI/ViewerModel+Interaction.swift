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
                startFramesPerPixel: viewport.framesPerPixel)
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

    /// A left-drag in the waveform lanes: selection, or an ⌥-modified zoom.
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
        if let live = laneDrag, live.start == start {
            mode = live.mode
        } else {
            mode = LaneDragMode(option: option, shift: shift)
            laneDrag = (start, mode)
            // A new gesture never continues the previous one's zoom, even when
            // the two began at the same point.
            zoomDrag = nil
        }
        switch mode {
        case .select(let extending):
            dragChanged(startPixel: start.x, currentPixel: current.x, extending: extending)
        case .zoom:
            zoomDragChanged(start: start, current: current)
        }
    }

    /// Ends a lane drag, on the terms it began on.
    ///
    /// A zoom drag must **not** fall through to `dragEnded`: an ⌥-drag that
    /// never really moved would otherwise be read as a click, seek the playhead
    /// and throw the selection away — and two of them as a double-click, which
    /// selects the whole file.
    ///
    /// With no latched mode this behaves exactly as it did before ⌥-drag
    /// existed, so an end that somehow arrives without a preceding change still
    /// runs the click logic.
    public func laneDragEnded(start: CGPoint, end: CGPoint, now: Double) {
        let mode = laneDrag?.mode
        laneDrag = nil
        switch mode {
        case .zoom:
            zoomDragEnded()
        case .select, nil:
            dragEnded(startPixel: start.x, endPixel: end.x, now: now)
        }
    }

    public func fitWholeFile() {
        guard hasTrack else { return }
        viewport.fit()
        refresh()
    }

    public func zoomToSelection() {
        guard hasTrack, !selection.isEmpty else { return }
        viewport.zoom(to: selection.range)
        refresh()
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
    /// playhead and clears the selection, and two of them in quick succession
    /// select the whole file.
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
        if isSecondClick(at: endPixel, now: now) {
            lastClick = nil
            selectAll()
            return
        }
        lastClick = (endPixel, now)
        seek(to: PixelMapping.frame(atPixel: endPixel, in: viewport))
        selection.clear()
    }

    private func isSecondClick(at pixel: Double, now: Double) -> Bool {
        guard let previous = lastClick else { return false }
        return now - previous.time < Self.doubleClickSeconds
            && abs(previous.pixel - pixel) < Self.clickSlopPoints
    }
}
