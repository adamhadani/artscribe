import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation
import Playback

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

    /// Set to `1` to actually *hear* an acceptance run. Audible is the explicit
    /// choice; silence is what you get by not choosing.
    static let audibleEnvironmentKey = "ARTSCRIBE_ACCEPTANCE_AUDIBLE"

    /// An automated run makes no sound.
    ///
    /// Agents launch this binary to check their own work, on a machine that is
    /// usually in the same room as a person; turning the system volume down is
    /// not a fix, because the run happens whether or not anyone did. So the
    /// harness closes `OutputAudibility`'s gate itself, unconditionally, and the
    /// override has to be typed on purpose.
    ///
    /// Called twice — from `AcceptanceMain.init`, which is this binary's first
    /// line, and again here on the run path before any file is loaded. Both are
    /// before an `AudioOutput` can exist, and either alone is sufficient; two
    /// because a single call in an entry point is exactly the kind of thing a
    /// later refactor drops without noticing.
    static func silenceOutput() {
        guard ProcessInfo.processInfo.environment[audibleEnvironmentKey] != "1" else { return }
        OutputAudibility.shared.silence()
    }

    @MainActor
    static func runIfRequested(model: ViewerModel, theme: ThemeController) async {
        silenceOutput()
        let args = CommandLine.arguments
        guard let audioPath = value(after: "--acceptance", in: args) else { return }
        let audio = URL(fileURLWithPath: audioPath)
        let badFile = value(after: "--bad-file", in: args).map { URL(fileURLWithPath: $0) }
        let outputDirectory = value(after: "--out", in: args) ?? "."

        var log = Logger()
        // Asserted, not assumed: the whole point is that no run can make a noise
        // by accident, so the run says whether it can.
        log.check(
            "this run cannot reach the speakers", OutputAudibility.shared.isSilenced,
            unless: ProcessInfo.processInfo.environment[audibleEnvironmentKey] == "1"
                ? "\(audibleEnvironmentKey)=1 was set, so this run is deliberately audible" : nil)
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

        // Task 17, and deliberately early. The same gestures Task 16 could only
        // reach through the model, this time as real pointer events into
        // SwiftUI's own machinery, plus the cursors that advertise them. Both
        // need a key window and a pointer this process can aim; a run lasts
        // minutes on a machine somebody else may be using, and by the time the
        // playback checks are done neither is reliably still true.
        await checkPointerGestures(model: model, log: &log)
        await checkPointerAffordances(model: model, log: &log)

        checkZoomAnchor(model: model, log: &log)
        await settle(seconds: 0.2)
        snapshot(to: "\(outputDirectory)/02-zoomed.png")

        await checkDeepZoom(model: model, log: &log, outputDirectory: outputDirectory)

        checkPanClamping(model: model, log: &log)
        await checkTrackpad(model: model, log: &log)
        await checkScrollZoom(model: model, log: &log)
        await checkDragZoom(model: model, log: &log)
        await checkZoomDirection(model: model, log: &log)
        await checkSpeedEmphasis(model: model, log: &log, outputDirectory: outputDirectory)
        await checkFileAndViewMenus(model: model, log: &log)
        // Task 15. The presentation and strobe checks read the menus; the
        // transport bar checks click real buttons and then press Space.
        await checkShortcutPresentation(log: &log)
        await checkMenuBarStrobe(model: model, log: &log)
        checkSingleFire(model: model, log: &log)
        await checkDisabledItemsClaimNothing(model: model, log: &log)
        await checkTransportBar(
            model: model, theme: theme, log: &log, outputDirectory: outputDirectory)
        await checkNudge(model: model, log: &log)
        await checkSettings(model: model, theme: theme, log: &log)
        await checkTheme(model: model, theme: theme, log: &log, outputDirectory: outputDirectory)
        await checkSelection(model: model, log: &log)
        await settle(seconds: 0.2)
        snapshot(to: "\(outputDirectory)/03-selection.png")

        await checkZoomToSelection(model: model, log: &log)
        await settle(seconds: 0.2)
        snapshot(to: "\(outputDirectory)/04-zoom-to-selection.png")

        // Task 18: the selection moves and extends, and the two menus it now
        // lives in. Deliberately *after* `checkZoomToSelection`, which reads the
        // selection this leaves cleared — measured, as a ⌘9 check that framed an
        // empty range.
        await checkSelectionMovement(model: model, log: &log)
        await checkEditMenu(model: model, log: &log)
        await checkLoopMenu(model: model, log: &log)

        await checkPlayback(model: model, log: &log, outputDirectory: outputDirectory)
        await settle(seconds: 0.2)
        snapshot(to: "\(outputDirectory)/07-playback.png")

        await checkResize(model: model, log: &log)
        await settle(seconds: 0.3)
        snapshot(to: "\(outputDirectory)/05-resized.png")

        if let badFile { await checkBadFile(model: model, url: badFile, log: &log) }
        await settle(seconds: 0.3)
        snapshot(to: "\(outputDirectory)/06-error-banner.png")

        // Deliberately last. It puts a text field into the window's responder
        // chain, and a field left there swallows every later keystroke — which
        // is exactly what happened the first time it ran earlier in the run.
        await checkTypingInAField(model: model, log: &log)

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

    /// Panning and its clamps.
    ///
    /// Driven through the model rather than through `Z`/`X`: those are spec
    /// §6.2's nudge keys as of Task 14, and the View menu's Scroll items — which
    /// call exactly these methods — are what is left of keyboard panning. The
    /// keys themselves are covered by `checkNudge`.
    @MainActor
    private static func checkPanClamping(model: ViewerModel, log: inout Logger) {
        model.fitWholeFile()
        for _ in 0..<6 { press(.r) }
        for _ in 0..<10 { model.scrollRight() }
        let moved = model.viewport.startFrame
        log.check("scrolling right pans (startFrame \(moved))", moved > 0)
        model.scrollLeft()
        log.check("scrolling left pans back", model.viewport.startFrame < moved)
        for _ in 0..<40 { model.scrollLeft() }
        log.check("panning clamps at the start", model.viewport.startFrame == 0)
        for _ in 0..<400 { model.scrollRight() }
        log.check("panning clamps at the end", model.viewport.endFrame == model.totalFrames)
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
            // The lane entry points, which is what the view calls as of Task 16
            // — the plain left-drag now arrives through the same door as the
            // ⌥-drag zoom, and this is where it is proved it still selects.
            let from = CGPoint(x: 200, y: model.laneFrame.height / 2)
            let to = CGPoint(x: 520, y: model.laneFrame.height / 2)
            model.laneDragChanged(start: from, current: from, option: false, shift: false)
            model.laneDragChanged(start: from, current: to, option: false, shift: false)
            model.laneDragEnded(
                start: from, end: to, now: ProcessInfo.processInfo.systemUptime)
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
