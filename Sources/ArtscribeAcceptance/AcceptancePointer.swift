import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// Real pointer input, and the checks that need it.
///
/// Everything here drives the *view layer* rather than the model: a genuine
/// `NSEvent` through `NSWindow.sendEvent`, which is the same door AppKit puts a
/// real click through, so SwiftUI's `DragGesture` and its `.local` coordinate
/// space are under test rather than assumed. Task 16 could not do this — that
/// session's screen was locked, no application could become key, and a window
/// that is not key refuses mouse events outright — and said so instead of
/// claiming the coverage. This is that gap, closed.
///
/// Two facts about the machine decide whether any of it can run, and both are
/// read directly rather than inferred from a result:
///
/// - **Key window.** Without it `NSWindow.sendEvent` drops the click.
/// - **A pointer this process can aim.** The cursor is shared with whoever is
///   sitting at the machine, so every hover check confirms the pointer is still
///   where it was put before believing what it reads back. If it is not, the
///   check is NOT CHECKED, not relaxed.
extension AcceptanceRun {

    // MARK: - Primitives

    /// The viewer window, resolved once and remembered.
    ///
    /// `NSApp.windows.first` is not it: that array's order is whatever the
    /// window server last put it in, so a run that asked for it twice got two
    /// different windows and converted the same point into two different places
    /// on screen — measured, and the reason this exists. The viewer is
    /// identified by the one thing that distinguishes it: its content view is
    /// the one the waveform lanes are laid out inside.
    @MainActor private static var viewer: NSWindow?

    @MainActor
    static func adoptViewerWindow(for model: ViewerModel) {
        let lanes = model.laneFrame
        viewer =
            NSApp.windows.first {
                guard $0.isVisible, let view = $0.contentView, !lanes.isEmpty else { return false }
                return view.bounds.contains(lanes.insetBy(dx: 1, dy: 1))
            } ?? NSApp.keyWindow ?? NSApp.windows.first
    }

    @MainActor
    static var pointerWindow: NSWindow? {
        viewer ?? NSApp.keyWindow ?? NSApp.windows.first
    }

    /// Window content coordinates (top-left origin) → the screen coordinates
    /// CoreGraphics measures from the primary display's top-left corner.
    @MainActor
    static func screenPoint(x: Double, y: Double) -> CGPoint? {
        guard let window = pointerWindow,
            let view = window.contentView,
            let screen = NSScreen.screens.first
        else { return nil }
        let inView = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        let inWindow = view.convert(inView, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        return CGPoint(x: onScreen.x, y: screen.frame.maxY - onScreen.y)
    }

    /// The same point in the bottom-left window coordinates an `NSEvent` wants.
    @MainActor
    static func windowPoint(x: Double, y: Double) -> NSPoint? {
        guard let window = pointerWindow,
            let view = window.contentView
        else { return nil }
        let inView = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        return view.convert(inView, to: nil)
    }

    /// Puts the pointer somewhere *and tells the window server about it*.
    ///
    /// Both halves are needed and neither is enough on its own, which cost an
    /// afternoon to establish: `CGWarpMouseCursorPosition` moves the cursor but
    /// synthesises no event, so no tracking area ever fires and the cursor
    /// keeps whatever shape it had; a posted `.mouseMoved` fires the tracking
    /// but, injected at `.cghidEventTap`, goes through pointer acceleration and
    /// lands somewhere else entirely. Warp for the position, post at
    /// `.cgSessionEventTap` for the crossing.
    @MainActor
    static func hover(x: Double, y: Double) async {
        guard let point = screenPoint(x: x, y: y) else { return }
        // A few in a row: one crossing event can be coalesced away, and the
        // real thing is a hand moving rather than a teleport.
        for _ in 0..<4 {
            CGWarpMouseCursorPosition(point)
            crossing(at: point)?.post(tap: .cgSessionEventTap)
            await settle(seconds: 0.05)
        }
        CGWarpMouseCursorPosition(point)
        await settle(seconds: 0.25)
    }

    private static func crossing(at point: CGPoint) -> CGEvent? {
        CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
            mouseButton: .left)
    }

    /// Whether the pointer is still where `hover` put it. The machine's user
    /// can move it at any moment, and a cursor read taken after that is a
    /// reading of somewhere else.
    @MainActor
    static func pointerIsAt(x: Double, y: Double) -> Bool {
        guard let window = pointerWindow,
            let view = window.contentView
        else { return false }
        let onScreen = NSEvent.mouseLocation
        let inWindow = window.convertPoint(fromScreen: onScreen)
        let inView = view.convert(inWindow, from: nil)
        let flipped = view.isFlipped ? inView.y : view.bounds.height - inView.y
        return abs(inView.x - x) <= 1.5 && abs(flipped - y) <= 1.5
    }

    /// Holds or releases a real modifier key, so `NSEvent.modifierFlags` — which
    /// is what `WaveformLanesView` reads at mouse-down — actually reports it.
    /// An event's own `modifierFlags` would not: that static reads the hardware.
    @MainActor
    static func setModifier(_ key: CGKeyCode, flags: CGEventFlags, down: Bool) async {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
        else { return }
        event.type = .flagsChanged
        event.flags = down ? flags : []
        event.post(tap: .cgSessionEventTap)
        await settle(seconds: 0.2)
    }

    static let optionKey: CGKeyCode = 58
    static let shiftKey: CGKeyCode = 56

    /// Gets the viewer window back to key, and says whether it managed it.
    ///
    /// Necessary because a run lasts a couple of minutes on a machine somebody
    /// else may be using, and every pointer check below needs the window that
    /// was key at launch to still be key now. Deliberately re-asserted here
    /// rather than assumed from the activation `normaliseWindow` did at the
    /// start of the run — that was two minutes and forty checks ago.
    @MainActor
    static func regainKeyWindow() async -> Bool {
        guard let window = pointerWindow else { return false }
        for _ in 0..<30 {
            if NSApp.isActive, NSApp.keyWindow === window { return true }
            NSApp.activate()
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
            await settle(seconds: 0.15)
        }
        return NSApp.keyWindow === window
    }

    /// A drag delivered as real `NSEvent`s through the window.
    ///
    /// `NSWindow.sendEvent` rather than `NSApp.sendEvent` or a posted `CGEvent`:
    /// all three were measured to reach `DragGesture`, and this one is the only
    /// one that puts the pointer exactly where it is asked without going
    /// through pointer acceleration. It does not move the system cursor at all,
    /// which is also why it is safe to run on a machine somebody is using.
    ///
    /// - Parameter steps: how many intermediate positions to deliver, so the
    ///   gesture sees a stream rather than a jump.
    @MainActor
    static func pointerDrag(
        from origin: CGPoint, to destination: CGPoint, steps: Int = 8
    ) async {
        sendMouse(.leftMouseDown, at: origin)
        await settle(seconds: 0.05)
        await pointerDragged(from: origin, to: destination, steps: steps)
        sendMouse(.leftMouseUp, at: destination)
        await settle(seconds: 0.1)
    }

    /// The middle of a drag, on its own, so a check can do something else
    /// between mouse-down and mouse-up.
    @MainActor
    static func pointerDragged(
        from origin: CGPoint, to destination: CGPoint, steps: Int = 8
    ) async {
        for step in 1...max(1, steps) {
            let fraction = Double(step) / Double(max(1, steps))
            sendMouse(
                .leftMouseDragged,
                at: CGPoint(
                    x: origin.x + (destination.x - origin.x) * fraction,
                    y: origin.y + (destination.y - origin.y) * fraction))
            await settle(seconds: 0.02)
        }
    }

    /// Distinct per event, because AppKit uses it to tell one press from the
    /// next and a repeated number reads as the same click arriving twice.
    @MainActor private static var eventNumber = 900

    @MainActor
    static func sendMouse(_ type: NSEvent.EventType, at point: CGPoint) {
        guard let window = pointerWindow, NSApp.keyWindow === window,
            let location = windowPoint(x: point.x, y: point.y)
        else { return }
        eventNumber += 1
        guard
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        window.sendEvent(event)
    }

    // MARK: - Gestures, driven for real

    /// Task 17: the drag gestures Task 16 could only reach through the model.
    ///
    /// Each check states the *quantity* it expects, not merely a direction.
    /// `ViewerModel.zoomDragPointsPerDoubling` is 120, so 120 points of travel is exactly
    /// one doubling — a `.local` coordinate space that arrived scaled, flipped
    /// or offset would still move the zoom, and only the number catches it.
    @MainActor
    static func checkPointerGestures(model: ViewerModel, log: inout Logger) async {
        let ruler = model.rulerFrame
        let lanes = model.laneFrame
        guard !ruler.isEmpty, !lanes.isEmpty else {
            log.check("ruler and lane geometry are known to the pointer check", false)
            return
        }
        log.note("ruler frame", "\(ruler)")
        adoptViewerWindow(for: model)
        let key = await regainKeyWindow()
        log.note("app active / key window at the pointer checks", "\(NSApp.isActive) / \(key)")
        guard key else {
            let reason = "no window is key, so NSWindow.sendEvent drops every click"
            for name in [
                "a real drag on the ruler zooms", "the ruler drag holds its anchor",
                "a real plain drag in the lanes selects", "a real Option-drag zooms",
                "and an Option-drag makes no selection"
            ] {
                log.skip(name, because: reason)
            }
            return
        }

        await checkRulerPointerDrag(model: model, ruler: ruler, log: &log)
        await checkLanePointerDrags(model: model, lanes: lanes, log: &log)
    }

    @MainActor
    private static func checkRulerPointerDrag(
        model: ViewerModel, ruler: CGRect, log: inout Logger
    ) async {
        model.fitWholeFile()
        model.clearSelection()
        model.seek(to: 0)
        // A quarter across, so anchoring on the playhead (frame 0, far left)
        // would be unmistakable.
        let anchorX = ruler.minX + ruler.width * 0.25
        let anchored = PixelMapping.frame(atPixel: anchorX - ruler.minX, in: model.viewport)
        let fitted = model.zoomFactor
        let start = CGPoint(x: anchorX, y: ruler.midY)
        let travel = ViewerModel.zoomDragPointsPerDoubling

        await pointerDrag(from: start, to: CGPoint(x: anchorX, y: start.y + travel))
        let zoomed = model.zoomFactor
        log.check(
            "a real drag down the ruler zooms in (\(rounded(fitted))x -> \(rounded(zoomed))x)",
            zoomed > fitted * 1.2)
        // One doubling for one `pointsPerDoubling` of travel. This is the check
        // that says the `.local` coordinates arrived undistorted: a space that
        // was flipped would zoom *out*, one that was scaled would land on the
        // wrong factor, and one measured from the window rather than the view
        // would be off by the ruler's origin.
        log.check(
            "and by exactly the documented rate — \(Int(travel)) pt is one doubling "
                + "(\(rounded(zoomed / fitted))x)",
            abs(zoomed / fitted - 2) < 0.08)
        let landed = model.viewport.pixel(forFrame: anchored)
        log.check(
            "the ruler drag holds its anchor under the pointer "
                + "(\(rounded(anchorX - ruler.minX)) pt -> \(rounded(landed)) pt)",
            abs(landed - (anchorX - ruler.minX)) <= 2)
        log.check("a ruler drag selects nothing", model.selection.isEmpty)
        log.check("and does not move the playhead", model.playhead == 0)

        // The other direction. A second gesture starts from where the viewport
        // now is, so this first climbs one more doubling and then comes down
        // one — deliberately away from the whole-file floor, which `Viewport`
        // clamps at and where a "did it zoom out" check would pass on any
        // build that merely stopped.
        await pointerDrag(from: start, to: CGPoint(x: anchorX, y: start.y + travel))
        let higher = model.zoomFactor
        await pointerDrag(from: start, to: CGPoint(x: anchorX, y: start.y - travel))
        log.check(
            "dragging the ruler up zooms back out by the same one doubling "
                + "(\(rounded(higher))x -> \(rounded(model.zoomFactor))x)",
            higher > zoomed * 1.5 && abs(model.zoomFactor / higher - 0.5) < 0.04)
        model.fitWholeFile()
    }

    @MainActor
    private static func checkLanePointerDrags(
        model: ViewerModel, lanes: CGRect, log: inout Logger
    ) async {
        model.fitWholeFile()
        model.clearSelection()

        // 1. Plain drag still selects, and selects exactly the dragged pixels.
        let fromX = lanes.minX + 200
        let toX = lanes.minX + 520
        let expected = PixelMapping.range(fromPixel: 200, toPixel: 520, in: model.viewport)
        await pointerDrag(
            from: CGPoint(x: fromX, y: lanes.midY), to: CGPoint(x: toX, y: lanes.midY))
        let selected = model.selection.range
        log.check("a real plain drag in the lanes selects", !selected.isEmpty)
        log.check("and selects exactly the dragged pixels", selected == expected)

        // 2. ⇧-drag extends from the same anchor rather than starting again.
        //    The modifier is a real one — `NSEvent.modifierFlags` reads the
        //    hardware, so an event's own flags would prove nothing.
        await setModifier(shiftKey, flags: .maskShift, down: true)
        let heldShift = NSEvent.modifierFlags.contains(.shift)
        await pointerDrag(
            from: CGPoint(x: toX + 40, y: lanes.midY),
            to: CGPoint(x: lanes.minX + 800, y: lanes.midY))
        await setModifier(shiftKey, flags: .maskShift, down: false)
        let extended = model.selection.range
        log.check(
            "Shift really reached the gesture", heldShift,
            unless: heldShift
                ? nil : "a synthesised flagsChanged did not reach NSEvent.modifierFlags"
        )
        log.check(
            "a real Shift-drag extends the selection instead of restarting it "
                + "(\(selected.start)…\(selected.end) -> \(extended.start)…\(extended.end))",
            extended.start == selected.start && extended.end > selected.end,
            unless: heldShift ? nil : "Shift never reached the process")

        // 3. ⌥-drag zooms, and takes nothing away from the selection.
        model.fitWholeFile()
        let fitted = model.zoomFactor
        let keptSelection = model.selection.range
        let keptPlayhead = model.playhead
        let anchorX = lanes.minX + lanes.width * 0.4
        let travel = ViewerModel.zoomDragPointsPerDoubling
        await setModifier(optionKey, flags: .maskAlternate, down: true)
        let heldOption = NSEvent.modifierFlags.contains(.option)
        await pointerDrag(
            from: CGPoint(x: anchorX, y: lanes.midY),
            to: CGPoint(x: anchorX, y: lanes.midY + travel))
        await setModifier(optionKey, flags: .maskAlternate, down: false)
        let optionReason =
            heldOption ? nil : "a synthesised flagsChanged did not reach NSEvent.modifierFlags"
        log.check("Option really reached the gesture", heldOption, unless: optionReason)
        log.check(
            "a real Option-drag in the lanes zooms "
                + "(\(rounded(fitted))x -> \(rounded(model.zoomFactor))x)",
            model.zoomFactor > fitted * 1.2, unless: optionReason)
        log.check(
            "and makes no selection while doing it",
            model.selection.range == keptSelection, unless: optionReason)
        log.check(
            "and leaves the playhead alone", model.playhead == keptPlayhead,
            unless: optionReason)
        model.fitWholeFile()
        model.clearSelection()
    }
}
