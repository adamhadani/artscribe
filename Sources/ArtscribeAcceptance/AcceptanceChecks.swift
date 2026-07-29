import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// The zoom, pan, pointer and error-recovery half of the acceptance run.
extension AcceptanceRun {

    /// Sweeps from whole-file down to individual cycles, timing the model work
    /// each keystroke causes. This is the cost that has to stay off the frame
    /// budget: peaks plus the cached-bitmap redraw for one viewport change.
    @MainActor
    static func checkDeepZoom(
        model: ViewerModel,
        log: inout Logger,
        outputDirectory: String
    ) async {
        model.fitWholeFile()
        model.clearSelection()
        var worst = 0.0
        var total = 0.0
        var steps = 0
        // Timed against the model, not a key event, so the number is the cost of
        // one viewport change: peaks plus the cached bitmap redraw.
        while model.framesPerPixel > Viewport.minFramesPerPixel * 1.01 {
            let started = Date()
            model.zoomIn()
            let elapsed = Date().timeIntervalSince(started)
            worst = max(worst, elapsed)
            total += elapsed
            steps += 1
            if steps > 200 { break }
        }
        log.note(
            "zoom sweep",
            "\(steps) steps to \(rounded(model.framesPerPixel)) f/px, "
                + String(
                    format: "mean %.2f ms, worst %.2f ms", total / Double(steps) * 1000,
                    worst * 1000))
        log.check("a viewport change costs well under one frame", worst < 0.016)
        log.check("reaches sample-level zoom", model.framesPerPixel <= 0.011)

        // Back off to somewhere individual cycles are visible in the picture.
        for _ in 0..<14 { press(.e) }
        await settle(seconds: 0.25)
        log.note("cycle-level zoom", "\(rounded(model.framesPerPixel)) f/px")
        snapshot(to: "\(outputDirectory)/02b-cycles.png")
        model.fitWholeFile()
    }

    /// Pinch has no public `NSEvent` constructor, so only the scroll half of the
    /// trackpad path can be driven from here; the shared decision logic is
    /// covered by `TrackpadActionTests`.
    @MainActor
    static func checkTrackpad(model: ViewerModel, log: inout Logger) async {
        model.fitWholeFile()
        for _ in 0..<6 { press(.r) }
        let before = model.viewport.startFrame
        for _ in 0..<8 { scroll(deltaX: -24) }
        await settle(seconds: 0.3)
        log.check(
            "two-finger scroll pans (\(before) -> \(model.viewport.startFrame))",
            model.viewport.startFrame > before)
    }

    /// P0: the scroll-wheel/trackpad split, and pointer-anchored zoom.
    ///
    /// The events are genuine `NSEvent`s posted through the application queue,
    /// with the same `hasPreciseScrollingDeltas` a real device would set —
    /// `.line` for a wheel, `.pixel` for a trackpad. They carry no window, so
    /// the pointer is warped first and the viewer resolves the anchor from it.
    @MainActor
    static func checkScrollZoom(model: ViewerModel, log: inout Logger) async {
        model.fitWholeFile()
        model.clearSelection()
        model.seek(to: 0)
        let lanes = model.laneFrame
        let strip = model.overviewFrame
        log.note("lane frame", "\(lanes)")
        log.note("overview frame", "\(strip)")
        guard !lanes.isEmpty, !strip.isEmpty else {
            log.check("lane geometry is known to the model", false)
            return
        }

        // A quarter of the way across the lanes, so anchoring on the playhead
        // (at frame 0, the far left) would be unmistakable.
        let laneX = lanes.width * 0.25
        warp(toX: lanes.minX + laneX, y: lanes.midY)
        await settle(seconds: 0.2)
        let anchored = PixelMapping.frame(atPixel: laneX, in: model.viewport)
        let fitted = model.zoomFactor
        for _ in 0..<4 { scroll(deltaY: 1, units: .line) }
        await settle(seconds: 0.3)
        log.check(
            "mouse wheel up zooms in (\(rounded(fitted))x -> \(rounded(model.zoomFactor))x)",
            model.zoomFactor > fitted * 1.5)
        let landed = model.viewport.pixel(forFrame: anchored)
        log.check(
            "wheel zoom anchors under the pointer "
                + "(\(rounded(laneX)) pt -> \(rounded(landed)) pt)",
            abs(landed - laneX) <= 2)

        for _ in 0..<4 { scroll(deltaY: -1, units: .line) }
        await settle(seconds: 0.3)
        log.check(
            "mouse wheel down zooms back out (\(rounded(model.zoomFactor))x)",
            model.zoomFactor < fitted * 1.05)

        for _ in 0..<3 { press(.r) }
        let panFrom = model.viewport.startFrame
        for _ in 0..<6 { scroll(deltaX: -24, units: .pixel) }
        await settle(seconds: 0.3)
        log.check(
            "two-finger scroll still pans (\(panFrom) -> \(model.viewport.startFrame))",
            model.viewport.startFrame > panFrom)

        // Task 16 made ⌘-scroll the *fine* zoom, at a third of the bare rate, so
        // it takes three times the travel to cover the same ground. Twelve
        // events at 30 points is what four used to be.
        let zoomFrom = model.zoomFactor
        for _ in 0..<12 { scroll(deltaY: 30, units: .pixel, flags: .maskCommand) }
        await settle(seconds: 0.3)
        log.check(
            "Command-scroll zooms on a trackpad "
                + "(\(rounded(zoomFrom))x -> \(rounded(model.zoomFactor))x)",
            model.zoomFactor > zoomFrom * 1.5)

        await checkFineScrollZoom(model: model, log: &log)
        await checkOverviewZoom(model: model, strip: strip, log: &log)
    }

    /// Task 16: `⌘`-scroll and the bare wheel over the *same* travel, so the
    /// difference measured is the rate and nothing else. Both are real posted
    /// `NSEvent`s, so this also proves the modifier survives the trip through
    /// the event queue into `TrackpadAction`.
    @MainActor
    private static func checkFineScrollZoom(model: ViewerModel, log: inout Logger) async {
        model.fitWholeFile()
        for _ in 0..<4 { scroll(deltaY: 1, units: .line) }
        await settle(seconds: 0.3)
        let coarse = model.zoomFactor

        model.fitWholeFile()
        for _ in 0..<4 { scroll(deltaY: 1, units: .line, flags: .maskCommand) }
        await settle(seconds: 0.3)
        let fine = model.zoomFactor

        log.check(
            "Command-scroll is finer than the bare wheel over the same travel "
                + "(\(rounded(coarse))x vs \(rounded(fine))x)",
            fine > 1.0001 && fine < coarse)
        model.fitWholeFile()
    }

    /// Task 16: the vertical drag on the time ruler, and the ⌥-drag in the
    /// lanes that does the same thing without taking the plain left-drag away
    /// from selection.
    ///
    /// Driven through the model entry points the gestures call, for the reason
    /// `checkSelection` records at length: a synthesised pointer drag does not
    /// reach SwiftUI's `DragGesture` while the login session's screen is locked,
    /// and claiming otherwise would be claiming coverage this run does not have.
    @MainActor
    static func checkDragZoom(model: ViewerModel, log: inout Logger) async {
        model.fitWholeFile()
        model.clearSelection()
        let lanes = model.laneFrame
        guard !lanes.isEmpty else {
            log.check("lane geometry is known to the drag-zoom check", false)
            return
        }
        log.note("drag-zoom path", "model entry points (the gesture's own)")

        // A quarter across, so anchoring on the playhead (frame 0) would show.
        let anchorX = lanes.width * 0.25
        let start = CGPoint(x: anchorX, y: 12)
        let anchored = PixelMapping.frame(atPixel: anchorX, in: model.viewport)
        let fitted = model.zoomFactor

        // 240 points down: two doublings at the shipped rate, in the direction
        // Task 18 made the default. Fed one point at a time, the way
        // `DragGesture` delivers it.
        for offset in 1...240 {
            model.zoomDragChanged(
                start: start, current: CGPoint(x: anchorX, y: 12 + Double(offset)))
        }
        await settle(seconds: 0.25)
        let landed = model.viewport.pixel(forFrame: anchored)
        let peak = model.zoomFactor
        log.check(
            "dragging down the ruler zooms in (\(rounded(fitted))x -> \(rounded(peak))x)",
            peak > fitted * 1.5)
        log.check(
            "the ruler drag stays anchored where it began "
                + "(\(rounded(anchorX)) pt -> \(rounded(landed)) pt)",
            abs(landed - anchorX) <= 2)

        // Back down the same distance **without letting go**: one gesture, so
        // the zoom is a function of where the pointer is rather than of the
        // path it took, and it returns exactly. (Releasing and starting again
        // deliberately does *not* return — the second gesture begins from where
        // the viewport now is, which `ViewerModelDragZoomTests` pins.)
        for offset in stride(from: 239, through: 0, by: -1) {
            model.zoomDragChanged(
                start: start, current: CGPoint(x: anchorX, y: 12 + Double(offset)))
        }
        model.zoomDragEnded()
        await settle(seconds: 0.25)
        log.check(
            "dragging back up without letting go returns to where it started "
                + "(\(rounded(peak))x -> \(rounded(model.zoomFactor))x)",
            abs(model.zoomFactor - fitted) < fitted * 0.02)

        await checkOptionDragZoom(model: model, lanes: lanes, log: &log)
    }

    /// ⌥-drag zooms; the plain left-drag it sits beside still selects. Both
    /// halves matter — the second is the regression the first one risks.
    @MainActor
    private static func checkOptionDragZoom(
        model: ViewerModel, lanes: CGRect, log: inout Logger
    ) async {
        model.fitWholeFile()
        model.clearSelection()
        let start = CGPoint(x: lanes.width * 0.4, y: lanes.height * 0.5)
        let fitted = model.zoomFactor
        for offset in 1...240 {
            model.laneDragChanged(
                start: start, current: CGPoint(x: start.x, y: start.y + Double(offset)),
                option: true, shift: false)
        }
        model.laneDragEnded(
            start: start, end: CGPoint(x: start.x, y: start.y + 240), now: 0)
        await settle(seconds: 0.25)
        log.check(
            "Option-drag in the lanes zooms (\(rounded(fitted))x -> "
                + "\(rounded(model.zoomFactor))x)",
            model.zoomFactor > fitted * 1.5)
        log.check("and makes no selection while doing it", model.selection.isEmpty)

        // The modifier released halfway must not start selecting.
        model.fitWholeFile()
        let second = CGPoint(x: lanes.width * 0.6, y: lanes.height * 0.5)
        model.laneDragChanged(start: second, current: second, option: true, shift: false)
        for offset in 1...120 {
            model.laneDragChanged(
                start: second,
                current: CGPoint(x: second.x + Double(offset), y: second.y + Double(offset)),
                option: false, shift: false)
        }
        model.laneDragEnded(
            start: second, end: CGPoint(x: second.x + 120, y: second.y + 120), now: 0)
        log.check(
            "releasing Option mid-drag does not turn the zoom into a selection",
            model.selection.isEmpty && model.zoomFactor > 1.5)
        model.fitWholeFile()
        model.clearSelection()
    }

    /// The overview strip always shows the whole file, so zooming there has to
    /// move the *main* viewport toward the frame under the pointer.
    @MainActor
    private static func checkOverviewZoom(
        model: ViewerModel, strip: CGRect, log: inout Logger
    ) async {
        model.fitWholeFile()
        let stripX = strip.width * 0.75
        warp(toX: strip.minX + stripX, y: strip.midY)
        await settle(seconds: 0.2)
        let target = PixelMapping.overviewFrame(
            atPixel: stripX, totalFrames: model.totalFrames, width: strip.width)
        for _ in 0..<8 { scroll(deltaY: 1, units: .line) }
        await settle(seconds: 0.3)
        let visible = model.viewport.startFrame...model.viewport.endFrame
        log.check(
            "wheel over the overview zooms the main viewport toward that frame "
                + "(\(rounded(model.zoomFactor))x, \(visible.lowerBound)…\(visible.upperBound) "
                + "contains \(target))",
            model.zoomFactor > 1.5 && visible.contains(target))
        model.fitWholeFile()
    }

    @MainActor
    static func checkZoomToSelection(model: ViewerModel, log: inout Logger) async {
        let range = model.selection.range
        press(.nine)
        await settle(seconds: 0.25)
        let framed =
            model.viewport.startFrame == range.start
            && abs(Double(model.viewport.visibleFrames - range.count)) < Double(range.count) * 0.05
        log.check("Cmd-9 frames the selection", framed)
        if !framed {
            log.note(
                "Cmd-9 detail",
                "start \(model.viewport.startFrame) vs \(range.start), "
                    + "visible \(model.viewport.visibleFrames) vs \(range.count)")
        }
        press(.escape)
        log.check("Esc clears the selection", model.selection.isEmpty)
        press(.zero)
        await settle(seconds: 0.15)
        log.check(
            "Cmd-0 returns to the whole file",
            model.viewport.startFrame == 0
                && model.framesPerPixel >= model.viewport.maxFramesPerPixel * 0.999)
    }

    @MainActor
    static func checkResize(model: ViewerModel, log: inout Logger) async {
        guard let window = NSApp.windows.first else {
            log.check("resize re-renders", false)
            return
        }
        press(.r)
        press(.r)
        let beforeWidth = model.viewport.widthPixels
        var frame = window.frame
        frame.size.width -= 260
        window.setFrame(frame, display: true)
        await settle(seconds: 0.4)
        log.check(
            "window resize updates the viewport width (\(beforeWidth) -> "
                + "\(model.viewport.widthPixels))",
            model.viewport.widthPixels < beforeWidth)
        log.check("waveform re-rendered at the new width", model.cache.waveformImage != nil)
    }

    @MainActor
    static func checkBadFile(model: ViewerModel, url: URL, log: inout Logger) async {
        let keptName = model.fileName
        let keptImage = model.cache.waveformImage
        model.open(url: url)
        let started = Date()
        while model.errorMessage == nil, Date().timeIntervalSince(started) < 20 {
            await settle(seconds: 0.05)
        }
        log.check("non-audio file surfaces an inline error", model.errorMessage != nil)
        log.note("banner", model.errorMessage ?? "(none)")
        log.check("previous file stays loaded", model.fileName == keptName && keptImage != nil)
    }
}
