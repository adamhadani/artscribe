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
        log.check("waveform re-rendered at the new width", model.waveformImage != nil)
    }

    @MainActor
    static func checkBadFile(model: ViewerModel, url: URL, log: inout Logger) async {
        let keptName = model.fileName
        let keptImage = model.waveformImage
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
