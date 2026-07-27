import ArtscribeKit

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
                playhead = frame
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
        playhead = PixelMapping.frame(atPixel: endPixel, in: viewport)
        selection.clear()
    }

    private func isSecondClick(at pixel: Double, now: Double) -> Bool {
        guard let previous = lastClick else { return false }
        return now - previous.time < Self.doubleClickSeconds
            && abs(previous.pixel - pixel) < Self.clickSlopPoints
    }
}
