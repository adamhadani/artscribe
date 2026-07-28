import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// Task 23, driven with real `NSEvent`s: the loop and selection edges dragged,
/// the loop body moved, and — the half that matters most — every gesture that
/// was already on this surface still doing exactly what it did.
///
/// Nothing here goes through the model's entry points. `pointerDrag` posts real
/// mouse events through `NSWindow.sendEvent`, so SwiftUI's `DragGesture`, the
/// `.local` coordinate space and `LaneDragMode`'s latch are all genuinely under
/// test. The one thing a synthesised event cannot do is move the system cursor,
/// so the *hover* half uses `hover(x:y:)` — warp plus a posted crossing — and
/// reads `NSCursor.currentSystem` back, exactly as Task 17's checks do.
extension AcceptanceRun {

    /// Every check name this can run, for the skip path.
    private static let edgeDragChecks = [
        "hovering a loop edge changes the cursor",
        "and the cursor goes back to the crosshair over open lane",
        "hovering the loop's bar offers a different cursor again",
        "a real drag on the loop's in point moves it",
        "and leaves the out point exactly where it was",
        "a loop edge drag does not move the playhead",
        "dragging the out point past the in point swaps rather than collapsing",
        "a real drag on the loop's top bar moves the whole loop",
        "and preserves its length exactly",
        "a real drag on a selection edge moves that edge",
        "a plain drag through the middle of the loop still selects"
    ]

    @MainActor
    static func checkEdgeDrag(
        model: ViewerModel, theme: ThemeController, log: inout Logger, outputDirectory: String
    ) async {
        let lanes = model.laneFrame
        guard !lanes.isEmpty else {
            log.check("lane geometry is known to the edge-drag check", false)
            return
        }
        adoptViewerWindow(for: model)
        guard await regainKeyWindow() else {
            let reason = "no window is key, so NSWindow.sendEvent drops every click"
            for name in edgeDragChecks { log.skip(name, because: reason) }
            return
        }
        model.fitWholeFile()
        model.clearSelection()

        await checkEdgeHover(model: model, lanes: lanes, log: &log)
        await checkLoopEdgeDrags(model: model, lanes: lanes, log: &log)
        await checkLoopBodyDrag(model: model, lanes: lanes, log: &log)
        await checkSelectionEdgeDrag(model: model, lanes: lanes, log: &log)
        await checkPlainDragSurvives(model: model, lanes: lanes, log: &log)
        await captureTreatment(
            model: model, theme: theme, lanes: lanes, outputDirectory: outputDirectory)

        model.clearLoop()
        model.clearSelection()
        model.fitWholeFile()
    }

    // MARK: - Setup

    /// Puts a loop between two lane points using the real `A`/`S` bindings, so a
    /// regression in those cannot masquerade as an edge-drag pass.
    @MainActor
    private static func setLoop(_ model: ViewerModel, fromPoint: Double, toPoint: Double) {
        model.clearLoop()
        model.seek(to: PixelMapping.frame(atPixel: fromPoint, in: model.viewport))
        press(.a)
        model.seek(to: PixelMapping.frame(atPixel: toPoint, in: model.viewport))
        press(.s)
        model.seek(to: 0)
    }

    @MainActor
    private static func frame(_ model: ViewerModel, atLanePoint point: Double) -> FrameIndex {
        PixelMapping.frame(atPixel: point, in: model.viewport)
    }

    /// One point of slack in either direction: a frame round-trips through the
    /// viewport's `Double` arithmetic on the way in and on the way out.
    @MainActor
    private static func within(
        _ model: ViewerModel, _ actual: FrameIndex, ofPoint point: Double
    ) -> Bool {
        abs(model.viewport.pixel(forFrame: actual) - point) <= 1.5
    }

    // MARK: - Hover

    /// The affordance has to arrive **before** the mouse goes down. A cursor
    /// that only changes once the drag is under way tells the user nothing they
    /// could have acted on.
    @MainActor
    private static func checkEdgeHover(
        model: ViewerModel, lanes: CGRect, log: inout Logger
    ) async {
        setLoop(model, fromPoint: 300, toPoint: 700)
        let crosshair = signature(NSCursor.crosshair)
        let restoreTo = NSEvent.mouseLocation

        func read(_ x: Double, _ y: Double) async -> String? {
            await hover(x: x, y: y)
            guard pointerIsAt(x: x, y: y) else { return nil }
            return signature(NSCursor.currentSystem)
        }

        let overOpenLane = await read(lanes.minX + 500, lanes.midY)
        let overEdge = await read(lanes.minX + 300, lanes.midY)
        let backOverOpenLane = await read(lanes.minX + 500, lanes.midY)
        let overBar = await read(lanes.minX + 500, lanes.minY + 3)
        CGWarpMouseCursorPosition(
            CGPoint(
                x: restoreTo.x,
                y: (NSScreen.screens.first?.frame.maxY ?? restoreTo.y) - restoreTo.y))

        let unread = "the pointer would not stay where it was put"
        log.note("cursor over open lane", overOpenLane ?? "not read")
        log.note("cursor over the loop's in point", overEdge ?? "not read")
        log.note("cursor over the loop's top bar", overBar ?? "not read")
        // Named against the crosshair rather than merely "different": what the
        // lane offers by default is documented as `rectSelection`, so a reading
        // that matched it would mean the edge announced nothing at all.
        log.check(
            "hovering a loop edge changes the cursor",
            overEdge != nil && overEdge != crosshair && overEdge != signature(NSCursor.arrow),
            unless: overEdge == nil ? unread : nil)
        log.check(
            "and the cursor goes back to the crosshair over open lane",
            backOverOpenLane == crosshair && overOpenLane == crosshair,
            unless: backOverOpenLane == nil || overOpenLane == nil ? unread : nil)
        log.check(
            "hovering the loop's bar offers a different cursor again",
            overBar != nil && overBar != crosshair && overBar != overEdge,
            unless: overBar == nil ? unread : nil)
    }

    // MARK: - The edges

    @MainActor
    private static func checkLoopEdgeDrags(
        model: ViewerModel, lanes: CGRect, log: inout Logger
    ) async {
        setLoop(model, fromPoint: 300, toPoint: 700)
        let outPointBefore = model.loop.range.end
        model.seek(to: frame(model, atLanePoint: 100))
        let playheadBefore = model.playhead

        await pointerDrag(
            from: CGPoint(x: lanes.minX + 300, y: lanes.midY),
            to: CGPoint(x: lanes.minX + 380, y: lanes.midY))
        let moved = model.loop.range
        log.note("loop after dragging the in point", "\(moved.start)…\(moved.end)")
        log.check(
            "a real drag on the loop's in point moves it",
            within(model, moved.start, ofPoint: 380))
        log.check(
            "and leaves the out point exactly where it was", moved.end == outPointBefore)
        log.check("a loop edge drag does not move the playhead", model.playhead == playheadBefore)

        // The inversion decision, for real: the out point taken past the in
        // point keeps following the pointer and the region reappears the other
        // side of it, rather than sticking at zero length.
        await pointerDrag(
            from: CGPoint(x: lanes.minX + 700, y: lanes.midY),
            to: CGPoint(x: lanes.minX + 250, y: lanes.midY))
        let swapped = model.loop.range
        log.note(
            "loop after dragging the out point past the in point",
            "\(swapped.start)…\(swapped.end)")
        log.check(
            "dragging the out point past the in point swaps rather than collapsing",
            swapped.count > 0 && within(model, swapped.start, ofPoint: 250)
                && within(model, swapped.end, ofPoint: 380))
    }

    // MARK: - The body

    @MainActor
    private static func checkLoopBodyDrag(
        model: ViewerModel, lanes: CGRect, log: inout Logger
    ) async {
        setLoop(model, fromPoint: 300, toPoint: 700)
        let lengthBefore = model.loop.range.count
        // On the bar the loop draws along the top of the lanes, which is where
        // the body handle lives — mid-lane is still the selection drag's.
        await pointerDrag(
            from: CGPoint(x: lanes.minX + 500, y: lanes.minY + 3),
            to: CGPoint(x: lanes.minX + 600, y: lanes.minY + 3))
        let moved = model.loop.range
        log.note("loop after dragging its bar", "\(moved.start)…\(moved.end)")
        log.check(
            "a real drag on the loop's top bar moves the whole loop",
            within(model, moved.start, ofPoint: 400))
        log.check("and preserves its length exactly", moved.count == lengthBefore)
    }

    @MainActor
    private static func checkSelectionEdgeDrag(
        model: ViewerModel, lanes: CGRect, log: inout Logger
    ) async {
        model.clearLoop()
        model.clearSelection()
        // Dragged out for real, so the edge being grabbed is one the pointer
        // actually made.
        await pointerDrag(
            from: CGPoint(x: lanes.minX + 500, y: lanes.midY),
            to: CGPoint(x: lanes.minX + 800, y: lanes.midY))
        let startBefore = model.selection.range.start
        await pointerDrag(
            from: CGPoint(x: lanes.minX + 800, y: lanes.midY),
            to: CGPoint(x: lanes.minX + 900, y: lanes.midY))
        let moved = model.selection.range
        log.note("selection after dragging its trailing edge", "\(moved.start)…\(moved.end)")
        log.check(
            "a real drag on a selection edge moves that edge",
            moved.start == startBefore && within(model, moved.end, ofPoint: 900))
    }

    // MARK: - The regression that would be instantly visible

    /// The eighth gesture must not have eaten the first. A plain drag through
    /// the middle of a loop region still drags out a passage, because the loop's
    /// body handle is its bars and not its whole area.
    @MainActor
    private static func checkPlainDragSurvives(
        model: ViewerModel, lanes: CGRect, log: inout Logger
    ) async {
        setLoop(model, fromPoint: 200, toPoint: 900)
        model.clearSelection()
        let expected = PixelMapping.range(fromPixel: 400, toPixel: 600, in: model.viewport)
        await pointerDrag(
            from: CGPoint(x: lanes.minX + 400, y: lanes.midY),
            to: CGPoint(x: lanes.minX + 600, y: lanes.midY))
        log.check(
            "a plain drag through the middle of the loop still selects",
            model.selection.range == expected)
    }

    // MARK: - What it looks like

    /// Snapshots of the hover and the active drag, in both themes.
    ///
    /// Views are not snapshot-*tested* in this project — there is no golden
    /// image to compare against, and a pixel diff over a live waveform would be
    /// noise. These are for a person to look at, which is the only honest way
    /// to check "nuanced but palpable": the mid-drag one is taken with the
    /// mouse button still down, which is the only moment the guide line and the
    /// time flag exist at all.
    @MainActor
    private static func captureTreatment(
        model: ViewerModel, theme: ThemeController, lanes: CGRect, outputDirectory: String
    ) async {
        let wanted = theme.preference
        for (appearance, name) in [(ThemePreference.dark, "dark"), (.light, "light")] {
            theme.preference = appearance
            await settle(seconds: 0.5)
            setLoop(model, fromPoint: 300, toPoint: 700)
            model.seek(to: 0)

            await hover(x: lanes.minX + 300, y: lanes.midY)
            snapshot(to: "\(outputDirectory)/11-edge-hover-\(name).png")

            // Held open: mouse down, dragged part-way, captured, then released.
            let from = CGPoint(x: lanes.minX + 700, y: lanes.midY)
            let to = CGPoint(x: lanes.minX + 560, y: lanes.midY)
            sendMouse(.leftMouseDown, at: from)
            await settle(seconds: 0.05)
            await pointerDragged(from: from, to: to, steps: 6)
            await settle(seconds: 0.25)
            snapshot(to: "\(outputDirectory)/12-edge-drag-\(name).png")
            sendMouse(.leftMouseUp, at: to)
            await settle(seconds: 0.15)
        }
        theme.preference = wanted
        await settle(seconds: 0.4)
    }

    // MARK: - While playing

    /// A loop edge moved with the transport running has to take effect without
    /// a click or a dropout. It cannot: the edge goes through `applyLoop`, which
    /// is the app's one `PlaybackCommand.setLoop` path, and the engine wraps at
    /// the boundary it is fed without ever resetting the stretcher there.
    ///
    /// What is measurable from here is the *consequence*: the transport is still
    /// running afterwards, the playhead ends up inside the region the drag left
    /// behind, and none of the render-thread degradation counters moved — a
    /// stall, a rejected command or a dropped one is exactly what a dropout
    /// would show up as.
    @MainActor
    static func checkEdgeDragWhilePlaying(model: ViewerModel, log: inout Logger) async {
        let names = [
            "a loop edge dragged during playback is still playing afterwards",
            "the dragged loop's new out point contains the playhead",
            "and no render stall, rejected or dropped command was counted"
        ]
        guard model.canPlay else {
            for name in names { log.skip(name, because: "no audio output was opened") }
            return
        }
        if let reason = positionChecksAreImpossible(model: model) {
            for name in names { log.skip(name, because: reason) }
            return
        }
        let lanes = model.laneFrame
        adoptViewerWindow(for: model)
        guard !lanes.isEmpty, await regainKeyWindow() else {
            for name in names {
                log.skip(name, because: "no window is key, so a real drag cannot be delivered")
            }
            return
        }

        model.fitWholeFile()
        model.clearSelection()
        setLoop(model, fromPoint: 200, toPoint: 800)
        if !model.loop.isEnabled { press(.d) }
        model.seek(to: model.loop.range.start)
        let before = model.degradation
        model.play()
        await settle(seconds: 1.2)

        // Pull the out point in while the engine is running through the region.
        await pointerDrag(
            from: CGPoint(x: lanes.minX + 800, y: lanes.midY),
            to: CGPoint(x: lanes.minX + 500, y: lanes.midY))
        await settle(seconds: 1.5)
        let playing = model.isPlaying
        let region = model.loop.range
        let position = model.playhead
        let after = model.degradation
        model.pause()
        await settle(seconds: 0.2)

        log.note("loop after the drag", "\(region.start)…\(region.end), playhead \(position)")
        log.check("a loop edge dragged during playback is still playing afterwards", playing)
        log.check(
            "the dragged loop's new out point contains the playhead",
            position >= region.start && position <= region.end)
        log.check(
            "and no render stall, rejected or dropped command was counted", after == before)
    }
}
