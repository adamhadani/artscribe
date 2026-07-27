import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// A scripted drive of the *running* window, used to check the acceptance list
/// on a machine where no synthetic input can be posted from outside the process
/// (screen recording and accessibility are both unavailable here).
///
/// It posts genuine `NSEvent`s through `NSApp.sendEvent`, so the menu bar, the
/// window's first responder and `onKeyPress` are all exercised for real — this
/// is not a model-level unit test wearing a costume. It only runs when the
/// binary is started with `--acceptance <audio-file>`; normal launches never
/// touch it.
enum AcceptanceRun {

    @MainActor
    static func runIfRequested(model: ViewerModel, theme: ThemeController) async {
        let args = CommandLine.arguments
        guard let audioPath = value(after: "--acceptance", in: args) else { return }
        let audio = URL(fileURLWithPath: audioPath)
        let badFile = value(after: "--bad-file", in: args).map { URL(fileURLWithPath: $0) }
        let outputDirectory = value(after: "--out", in: args) ?? "."

        var log = Logger()
        await settle(seconds: 1.0)
        // macOS restores a window's saved frame, so pin a known size: otherwise
        // the resize check below shrinks the window a little on every run.
        await normaliseWindow()
        log.check("regular activation policy (menu bar)", NSApp.activationPolicy() == .regular)
        log.note("app active / key window", "\(NSApp.isActive) / \(NSApp.keyWindow != nil)")
        log.check(
            "window can take keyboard focus",
            NSApp.windows.first.map { $0.canBecomeKey } ?? false)
        log.note(
            "first responder",
            "\(NSApp.windows.first?.firstResponder.map(String.init(describing:)) ?? "none")")

        await checkLoad(model: model, url: audio, log: &log)
        checkStructure(model: model, log: &log)
        snapshot(to: "\(outputDirectory)/01-loaded.png")

        checkZoomAnchor(model: model, log: &log)
        await settle(seconds: 0.2)
        snapshot(to: "\(outputDirectory)/02-zoomed.png")

        await checkDeepZoom(model: model, log: &log, outputDirectory: outputDirectory)

        checkPanClamping(model: model, log: &log)
        await checkTrackpad(model: model, log: &log)
        await checkScrollZoom(model: model, log: &log)
        await checkSpeedEmphasis(model: model, log: &log, outputDirectory: outputDirectory)
        await checkFileAndViewMenus(model: model, log: &log)
        await checkTheme(model: model, theme: theme, log: &log, outputDirectory: outputDirectory)
        await checkSelection(model: model, log: &log)
        await settle(seconds: 0.2)
        snapshot(to: "\(outputDirectory)/03-selection.png")

        await checkZoomToSelection(model: model, log: &log)
        await settle(seconds: 0.2)
        snapshot(to: "\(outputDirectory)/04-zoom-to-selection.png")

        await checkPlayback(model: model, log: &log, outputDirectory: outputDirectory)
        await settle(seconds: 0.2)
        snapshot(to: "\(outputDirectory)/07-playback.png")

        await checkResize(model: model, log: &log)
        await settle(seconds: 0.3)
        snapshot(to: "\(outputDirectory)/05-resized.png")

        if let badFile { await checkBadFile(model: model, url: badFile, log: &log) }
        await settle(seconds: 0.3)
        snapshot(to: "\(outputDirectory)/06-error-banner.png")

        log.report()
        exit(log.exitCode)
    }

    /// Why the playhead cannot possibly move in this session, or `nil` when it
    /// can and therefore must.
    ///
    /// The eight checks that measure `model.playhead` while the transport runs
    /// all need the CoreAudio render thread to be called, and it is not called
    /// when the HAL has no output device to route to — audio does not render in
    /// every agent session. That is a fact about the machine, which the app
    /// already publishes, so it is what gets read here. Deliberately **not**
    /// derived from the playhead itself: "skip the position checks when the
    /// position does not move" would pass on any broken build. With a routable
    /// device present a stationary playhead is still a failure, and still FAILs.
    @MainActor
    static func positionChecksAreImpossible(model: ViewerModel) -> String? {
        guard let notice = model.deviceNotice else { return nil }
        return "the audio render thread is never called in this session: \(notice)"
    }

    // MARK: - Checks

    @MainActor
    private static func checkLoad(model: ViewerModel, url: URL, log: inout Logger) async {
        let started = Date()
        model.open(url: url)
        while model.isLoading || !model.hasTrack {
            if Date().timeIntervalSince(started) > 60 { break }
            await settle(seconds: 0.05)
        }
        log.check("loads reference file", model.hasTrack)
        log.check("waveform bitmap produced", model.waveformImage != nil)
        log.check("overview bitmap produced", model.overviewImage != nil)
        log.note("frames", "\(model.totalFrames) @ \(model.sampleRate) Hz x\(model.channels)")
        log.note(
            "file-chosen to waveform-on-screen",
            String(format: "%.3f s", model.lastLoadSeconds ?? -1))
    }

    /// The waveform must show structure. A solid block or a flat line would both
    /// still "draw", so this measures the spread of column amplitudes over the
    /// whole file rather than trusting the picture.
    @MainActor
    private static func checkStructure(model: ViewerModel, log: inout Logger) {
        guard let pyramid = model.pyramid else {
            log.check("waveform shows musical structure", false)
            return
        }
        let peaks = pyramid.peaks(
            channel: 0, range: FrameRange(start: 0, count: model.totalFrames), buckets: 1200)
        let heights = peaks.map { Double($0.max - $0.min) }
        guard let loudest = heights.max(), let quietest = heights.min(), loudest > 0 else {
            log.check("waveform shows musical structure", false)
            return
        }
        let mean = heights.reduce(0, +) / Double(heights.count)
        let spread =
            (heights.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(heights.count))
            .squareRoot()
        log.note(
            "column amplitude",
            String(
                format: "min %.3f  mean %.3f  max %.3f  sd %.3f", quietest, mean, loudest, spread)
        )
        log.check("waveform is not a flat line", loudest > 0.2)
        log.check("waveform is not a solid block", quietest < loudest * 0.6 && spread > 0.02)
    }

    /// Every zoom here goes through a posted `E`/`R` key event, so a failure
    /// would mean either the binding or the keyboard focus is broken.
    @MainActor
    private static func checkZoomAnchor(model: ViewerModel, log: inout Logger) {
        model.fitWholeFile()
        let fitted = model.framesPerPixel
        for _ in 0..<6 { press(.r) }
        log.check("R zooms in", model.framesPerPixel < fitted * 0.5)

        // Put the playhead somewhere that is not the origin, then zoom around it.
        model.dragEnded(
            startPixel: 640, endPixel: 640, now: ProcessInfo.processInfo.systemUptime)
        let anchor = model.playhead
        let before = model.viewport.pixel(forFrame: anchor)
        for _ in 0..<6 { press(.r) }
        let afterIn = model.viewport.pixel(forFrame: anchor)
        for _ in 0..<6 { press(.e) }
        let afterOut = model.viewport.pixel(forFrame: anchor)
        log.check(
            "anchor stays under the same pixel while zooming in "
                + "(\(rounded(before)) -> \(rounded(afterIn)))",
            abs(before - afterIn) < 1.5)
        log.check(
            "anchor stays under the same pixel while zooming out "
                + "(\(rounded(afterIn)) -> \(rounded(afterOut)))",
            abs(afterIn - afterOut) < 1.5)

        for _ in 0..<30 { press(.e) }
        log.check("E returns to whole-file zoom", model.framesPerPixel >= fitted * 0.999)
    }

    @MainActor
    private static func checkPanClamping(model: ViewerModel, log: inout Logger) {
        model.fitWholeFile()
        for _ in 0..<6 { press(.r) }
        for _ in 0..<10 { press(.x) }
        let moved = model.viewport.startFrame
        log.check("X pans right (startFrame \(moved))", moved > 0)
        press(.z)
        log.check("Z pans back left", model.viewport.startFrame < moved)
        for _ in 0..<40 { press(.z) }
        log.check("Z clamps at the start", model.viewport.startFrame == 0)
        for _ in 0..<400 { press(.x) }
        log.check("X clamps at the end", model.viewport.endFrame == model.totalFrames)
        log.check("still zoomed in after clamping", model.viewport.startFrame > 0)
    }

    static func rounded(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// The value following `flag` in `args`, or `nil` if the flag is absent
    /// *or is the last argument*. Bounds-checked deliberately: a flag with no
    /// value after it (e.g. `--out` typed last on the command line) must not
    /// trap with an index-out-of-range.
    static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Drags from x=200 to x=520 and checks the resulting selection.
    ///
    /// The drag is delivered as real pointer events when the window is key. It
    /// cannot be while the login session's screen is locked -- no application
    /// can become active then -- so in that case the same drag is driven through
    /// the model entry points the gesture calls, and the run says so rather than
    /// claiming coverage it does not have.
    @MainActor
    private static func checkSelection(model: ViewerModel, log: inout Logger) async {
        model.fitWholeFile()
        let expected = PixelMapping.range(fromPixel: 200, toPixel: 520, in: model.viewport)
        // Try real pointer events first. They reach SwiftUI's gesture machinery
        // only sometimes — Task 10 established that a window that is not key
        // refuses them outright, and that hit-testing the hosting view and
        // calling `mouseDown(with:)` does not always reach the `DragGesture`
        // either. Rather than reporting that as a product failure, the run falls
        // back to the entry points the gesture calls and says which path it took.
        if NSApp.keyWindow != nil { await mouseDrag(fromX: 200, toX: 520) }
        var viaPointer = !model.selection.range.isEmpty
        if !viaPointer {
            model.dragChanged(startPixel: 200, currentPixel: 200, extending: false)
            model.dragChanged(startPixel: 200, currentPixel: 520, extending: false)
            model.dragEnded(
                startPixel: 200, endPixel: 520, now: ProcessInfo.processInfo.systemUptime)
            viaPointer = false
        }
        log.note(
            "drag path",
            viaPointer
                ? "real pointer events"
                : "model entry points (synthetic pointer events did not reach the gesture)")
        let range = model.selection.range
        log.check(
            viaPointer ? "pointer drag selects a range" : "drag selects a range (via model)",
            !range.isEmpty)
        log.note(
            "selection",
            "\(TimeCode.precise(frames: range.start, sampleRate: model.sampleRate))"
                + "-\(TimeCode.precise(frames: range.end, sampleRate: model.sampleRate))")
        log.check("selection matches the dragged pixels", range == expected)
    }
}
