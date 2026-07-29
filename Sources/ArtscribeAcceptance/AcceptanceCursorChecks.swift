import AppKit
import ArtscribeUI
import Foundation

/// Task 17: the pointer affordances, read back from the *system cursor*.
///
/// `NSCursor.currentSystem` is what is actually on screen, so this measures the
/// thing the user sees rather than the value a view was handed —
/// `SwiftUI.PointerStyle` is opaque and cannot be inspected, which is why the
/// decision was extracted into `PointerAffordance` and unit-tested separately.
/// What is left for here is the wiring: that the styles reach the screen, that
/// ⌥ changes one of them *without the pointer moving*, that a latched ⌥-drag
/// keeps saying "zoom" after ⌥ is let go, and that every region hands the arrow
/// back on the way out.
extension AcceptanceRun {

    /// One pass of the probe. Gathered first, asserted second, because the
    /// gathering has to move a pointer somebody else may also be using and the
    /// window for doing so is short.
    struct CursorReadings {
        var notes: [(String, String)] = []
        /// Why a missing reading is missing — never inferred from the reading
        /// itself, which would turn a real defect into a skip.
        var unavailable: String?
        var outside: String?
        var ruler: String?
        var lanes: String?
        var lanesWithOption: String?
        var lanesAfterRelease: String?
        var duringLatchedZoom: String?
        var afterTheDragEnded: String?
        var transport: String?
        var outsideAgain: String?

        /// Records a reading taken at a point the pointer refused to stay at.
        mutating func missed(_ name: String, asked: String, found: String) {
            unavailable =
                unavailable
                ?? "the pointer would not stay where it was put "
                + "(something else on this machine is moving it)"
            notes.append(("cursor over \(name)", "not read — asked for \(asked), found \(found)"))
        }
    }

    @MainActor
    static func checkPointerAffordances(model: ViewerModel, log: inout Logger) async {
        let ruler = model.rulerFrame
        let lanes = model.laneFrame
        guard !ruler.isEmpty, !lanes.isEmpty else {
            log.check("ruler and lane geometry are known to the cursor check", false)
            return
        }
        adoptViewerWindow(for: model)
        guard await regainKeyWindow() else {
            log.skip(
                "the pointer affordances reach the screen",
                because: "no window is key, so nothing here owns the cursor")
            return
        }
        let readings = await gatherCursorReadings(model: model, ruler: ruler, lanes: lanes)
        report(readings, log: &log)
    }

    // MARK: - Gathering

    @MainActor
    private static func gatherCursorReadings(
        model: ViewerModel, ruler: CGRect, lanes: CGRect
    ) async -> CursorReadings {
        let restoreTo = NSEvent.mouseLocation
        var readings = CursorReadings()

        readings.outside = await read(
            "nothing (the window's title bar)", x: ruler.midX, y: -12, into: &readings)
        readings.ruler = await read(
            "the time ruler", x: ruler.midX, y: ruler.midY, into: &readings)
        readings.lanes = await read(
            "the waveform lanes", x: lanes.midX, y: lanes.midY, into: &readings)

        await readOptionHeldOverLanes(lanes: lanes, into: &readings)
        if readings.lanes != nil {
            await readLatchedZoomDrag(model: model, lanes: lanes, into: &readings)
        }

        readings.transport = await read(
            "the transport bar", x: lanes.midX, y: transportY(model), into: &readings)
        readings.outsideAgain = await read(
            "nothing again", x: ruler.midX, y: -12, into: &readings)
        // Put the pointer back where it was found. `NSEvent.mouseLocation` is
        // bottom-up from the primary display; `CGWarpMouseCursorPosition` is
        // top-down from it.
        CGWarpMouseCursorPosition(
            CGPoint(
                x: restoreTo.x,
                y: (NSScreen.screens.first?.frame.maxY ?? restoreTo.y) - restoreTo.y))
        return readings
    }

    /// Hovers and reads, or records why the reading would be worthless.
    @MainActor
    private static func read(
        _ name: String, x: Double, y: Double, into readings: inout CursorReadings
    ) async -> String? {
        await hover(x: x, y: y)
        guard pointerIsAt(x: x, y: y) else {
            readings.missed(
                name,
                asked: screenPoint(x: x, y: y).map(String.init(describing:)) ?? "?",
                found: "\(NSEvent.mouseLocation)")
            return nil
        }
        let found = signature(NSCursor.currentSystem)
        readings.notes.append(("cursor over \(name)", found))
        return found
    }

    /// ⌥ down with the pointer standing still, then up again.
    ///
    /// This is the half most likely to be got wrong: a cursor resolved only
    /// when the pointer *enters* a view leaves the modifier invisible until the
    /// user has already committed to a drag.
    @MainActor
    private static func readOptionHeldOverLanes(
        lanes: CGRect, into readings: inout CursorReadings
    ) async {
        await setModifier(optionKey, flags: .maskAlternate, down: true)
        await settle(seconds: 0.4)
        if pointerIsAt(x: lanes.midX, y: lanes.midY) {
            let found = signature(NSCursor.currentSystem)
            readings.lanesWithOption = found
            readings.notes.append(("cursor over the lanes, ⌥ held", found))
        }
        await setModifier(optionKey, flags: .maskAlternate, down: false)
        await settle(seconds: 0.4)
        if pointerIsAt(x: lanes.midX, y: lanes.midY) {
            let found = signature(NSCursor.currentSystem)
            readings.lanesAfterRelease = found
            readings.notes.append(("cursor over the lanes, ⌥ released", found))
        }
    }

    /// The cursor *during* a drag, which the modifier alone cannot settle:
    /// `LaneDragMode` latches at mouse-down, so an ⌥-drag that outlives the ⌥
    /// that began it must keep the magnifier. This is the only reading taken
    /// with a gesture in flight, and it is the whole reason
    /// `ViewerModel.laneDragMode` is observed rather than ignored.
    @MainActor
    private static func readLatchedZoomDrag(
        model: ViewerModel, lanes: CGRect, into readings: inout CursorReadings
    ) async {
        guard NSApp.keyWindow === pointerWindow else { return }
        let at = CGPoint(x: lanes.midX, y: lanes.midY)
        let lifted = CGPoint(x: at.x, y: at.y - 40)
        await setModifier(optionKey, flags: .maskAlternate, down: true)
        sendMouse(.leftMouseDown, at: at)
        await settle(seconds: 0.05)
        await pointerDragged(from: at, to: lifted, steps: 4)
        // ⌥ let go with the button still down. The gesture keeps zooming, so
        // the cursor has to keep saying so.
        await setModifier(optionKey, flags: .maskAlternate, down: false)
        await settle(seconds: 0.35)
        if pointerIsAt(x: at.x, y: at.y) {
            let found = signature(NSCursor.currentSystem)
            readings.duringLatchedZoom = found
            readings.notes.append(("cursor mid-drag, ⌥ already released", found))
        }
        sendMouse(.leftMouseUp, at: lifted)
        await settle(seconds: 0.35)
        if pointerIsAt(x: at.x, y: at.y) {
            let found = signature(NSCursor.currentSystem)
            readings.afterTheDragEnded = found
            readings.notes.append(("cursor after the drag ended", found))
        }
        model.fitWholeFile()
        model.clearSelection()
    }

    // MARK: - Asserting

    @MainActor
    private static func report(_ readings: CursorReadings, log: inout Logger) {
        let arrow = signature(NSCursor.arrow)
        log.note("arrow", arrow)
        for (name, value) in readings.notes { log.note(name, value) }
        let missing = readings.unavailable
        let noDrag = missing ?? "no drag could be delivered"

        log.check(
            "the pointer over nothing in particular is the plain arrow",
            readings.outside == arrow, unless: readings.outside == nil ? missing : nil)
        // Named cursors, not merely "different from the arrow": `.rowResize` is
        // documented to be the row-resize arrows and `.rectSelection` the
        // crosshair, and an assertion that only said "not the arrow" would pass
        // on entirely the wrong one.
        log.check(
            "the time ruler says it can be dragged up and down "
                + "(rowResize == NSCursor.resizeUpDown)",
            readings.ruler == signature(NSCursor.resizeUpDown),
            unless: readings.ruler == nil ? missing : nil)
        log.check(
            "the waveform lanes say a passage can be dragged out "
                + "(rectSelection == NSCursor.crosshair)",
            readings.lanes == signature(NSCursor.crosshair),
            unless: readings.lanes == nil ? missing : nil)
        log.check(
            "⌥ changes the cursor with the pointer standing still",
            readings.lanesWithOption != nil && readings.lanesWithOption != readings.lanes
                && readings.lanesWithOption != arrow,
            unless: readings.lanesWithOption == nil ? missing : nil)
        log.check(
            "and releasing ⌥ hands the crosshair straight back",
            readings.lanesAfterRelease == readings.lanes,
            unless: readings.lanesAfterRelease == nil ? missing : nil)
        log.check(
            "an Option-drag keeps the magnifier after ⌥ is let go mid-drag",
            readings.duringLatchedZoom != nil
                && readings.duringLatchedZoom == readings.lanesWithOption,
            unless: readings.duringLatchedZoom == nil ? noDrag : nil)
        log.check(
            "and the crosshair comes back when the button does",
            readings.afterTheDragEnded == readings.lanes,
            unless: readings.afterTheDragEnded == nil ? noDrag : nil)
        log.check(
            "the transport bar keeps the plain arrow", readings.transport == arrow,
            unless: readings.transport == nil ? missing : nil)
        log.check(
            "leaving the timeline restores the arrow", readings.outsideAgain == arrow,
            unless: readings.outsideAgain == nil ? missing : nil)
    }

    /// Somewhere inside the transport bar, which sits between the lanes and the
    /// status bar and must keep the ordinary arrow — a cursor that changed
    /// everywhere would stop meaning anything.
    @MainActor
    private static func transportY(_ model: ViewerModel) -> Double {
        if let play = model.transportFrames[.playPause] { return play.midY }
        return model.laneFrame.maxY + 20
    }

    /// Identifies a cursor by its artwork and hot spot. The image bytes are the
    /// only thing that distinguishes the system cursors from one another —
    /// `NSCursor` exposes no name — and they compare exactly, because both
    /// sides are the same `NSImage` the system handed out.
    static func signature(_ cursor: NSCursor?) -> String {
        guard let cursor else { return "none" }
        let bytes = cursor.image.tiffRepresentation?.count ?? 0
        let size = cursor.image.size
        return "\(Int(size.width))x\(Int(size.height))@"
            + "\(Int(cursor.hotSpot.x)),\(Int(cursor.hotSpot.y))/\(bytes)"
    }
}
