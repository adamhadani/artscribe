import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// Task 15A and 15C, driven through the real buttons and read off the real
/// pixels.
///
/// The load-bearing check here is the last one: after a button has been clicked,
/// **Space must still play**. Adding buttons to a keyboard-driven app is exactly
/// how the keyboard stops working, and the only honest way to know is to click
/// one and then press the key.
extension AcceptanceRun {

    // MARK: - The bar

    @MainActor
    static func checkTransportBar(
        model: ViewerModel, theme: ThemeController, log: inout Logger, outputDirectory: String
    ) async {
        await settle(seconds: 0.3)
        let frames = model.transportFrames
        log.check(
            "every transport control laid out (\(frames.count)/\(TransportControl.allCases.count))",
            frames.count == TransportControl.allCases.count)
        let lanes = model.laneFrame
        guard !frames.isEmpty, !lanes.isEmpty else {
            log.check("the transport bar has a geometry to click", false)
            return
        }
        log.note("transport buttons in the accessibility tree", accessibilityButtons())
        // Directly above the status bar, and below the lanes — the position the
        // plan asks for, read off the layout rather than assumed.
        if let play = frames[.playPause] {
            log.check("the transport bar sits below the waveform lanes", play.minY > lanes.maxY)
            log.note(
                "transport bar geometry",
                "play button at \(rounded(play.minX)),\(rounded(play.minY)) "
                    + "\(rounded(play.width))x\(rounded(play.height)); "
                    + "lanes end at y=\(rounded(lanes.maxY))")
        }

        await checkButtonsDriveTheModel(model: model, log: &log)
        await checkFocusSurvivesAClick(model: model, log: &log)
        // Both themes, because "legible in both" is the acceptance item and a
        // colour that works on near-black is not automatically one that works on
        // near-white — the whole reason the light palette is designed rather
        // than inverted.
        for preference in [ThemePreference.dark, .light] {
            theme.preference = preference
            await settle(seconds: 0.6)
            await checkLoopProminence(model: model, log: &log, outputDirectory: outputDirectory)
        }
        theme.preference = .dark
        await settle(seconds: 0.5)
    }

    /// Each button, pressed for real, changes exactly what its key changes.
    ///
    /// Whether a press can be delivered at all is decided **first**, and from a
    /// fact about the machine rather than from the result: with the login
    /// session's screen locked no application can become active, and a synthetic
    /// pointer event does not reach a SwiftUI control — the same limitation the
    /// selection drag records, and the reason the accessibility tree exposes no
    /// buttons either. On an unlocked machine every check below runs for real.
    @MainActor
    private static func checkButtonsDriveTheModel(model: ViewerModel, log: inout Logger) async {
        var paths: Set<String> = []
        model.fitWholeFile()
        let fitted = model.framesPerPixel
        paths.insert(await activate(.zoomIn, model: model))
        let undeliverable =
            model.framesPerPixel < fitted
            ? nil
            : (screenIsLocked()
                ? "the login session's screen is locked (CGSSessionScreenIsLocked), so no "
                    + "application can become active and a synthesised pointer event does not "
                    + "reach a SwiftUI control — the same limitation the selection drag records"
                : nil)
        log.check("pressing Zoom In zooms in", model.framesPerPixel < fitted, unless: undeliverable)

        paths.insert(await activate(.zoomOut, model: model))
        log.check(
            "pressing Zoom Out zooms back out", model.framesPerPixel >= fitted * 0.999,
            unless: undeliverable)

        model.setSpeedPreset(1.0)
        paths.insert(await activate(.slower, model: model))
        log.check(
            "pressing − steps the speed exactly as Q does (\(model.speed.ratio))",
            model.speed.ratio == 0.95, unless: undeliverable)
        paths.insert(await activate(.faster, model: model))
        log.check("pressing + steps it back", model.speed.ratio == 1.0, unless: undeliverable)

        model.seek(to: model.totalFrames / 2)
        let middle = model.playhead
        let step = FrameIndex((model.nudgeAmounts[.normal] * model.sampleRate).rounded())
        paths.insert(await activate(.nudgeForward, model: model))
        log.check(
            "pressing nudge-forward moves one normal tier (\(model.playhead - middle))",
            model.playhead - middle == step, unless: undeliverable)
        paths.insert(await activate(.nudgeBackward, model: model))
        log.check("pressing nudge-back returns", model.playhead == middle, unless: undeliverable)

        model.selectAll()
        model.loopFromSelection()
        let looping = model.loop.isEnabled
        paths.insert(await activate(.loop, model: model))
        log.check(
            "pressing the loop button toggles looping", model.loop.isEnabled != looping,
            unless: undeliverable)
        log.check(
            "and the button reads its new state", model.transportState.loopIsEnabled != looping,
            unless: undeliverable)
        model.clearLoop()
        model.clearSelection()
        model.setSpeedPreset(1.0)
        model.seek(to: 0)
        log.note("button press path", paths.sorted().joined(separator: ", "))
    }

    /// Whether this login session's screen is locked, asked of CoreGraphics.
    ///
    /// The independent fact behind every skip in this file. Deliberately not
    /// inferred from "the press did nothing", which would turn any broken button
    /// into a skip.
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    /// The classic defect: pressing a button leaves the keyboard on the button,
    /// so Space re-presses it instead of playing.
    ///
    /// Measured two ways, because the strong one needs a key window and this
    /// machine's login session is screen-locked, where nothing can be key.
    ///
    /// 1. **The first responder does not move.** Available in every session: the
    ///    window has a first responder (SwiftUI's key-view proxy for
    ///    `DocumentView`) whether or not the window is key, and a control that
    ///    took focus would have replaced it. Identity is compared, not a
    ///    description.
    /// 2. **Space still plays.** The real thing, and the reason `restoreFocus`
    ///    exists — but only meaningful with a key window, so it is skipped with
    ///    its reason rather than faked when there is none.
    ///
    /// The button used is Zoom In, whose effect is unmistakably *not* the
    /// transport: a Space that re-triggered the last-pressed button would show
    /// up as a second zoom, so success cannot be confused with the defect.
    @MainActor
    private static func checkFocusSurvivesAClick(model: ViewerModel, log: inout Logger) async {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            log.check("the viewer window exists", false)
            return
        }
        model.fitWholeFile()
        let before = window.firstResponder
        let path = await activate(.zoomIn, model: model)
        let after = window.firstResponder
        log.note(
            "first responder around a \(path) press",
            "\(before.map(String.init(describing:)) ?? "none") -> "
                + "\(after.map(String.init(describing:)) ?? "none")")
        // Not vacuous even when the press does not reach the control: the
        // harness hit-tests the window at the button's own frame and calls
        // `mouseDown`/`mouseUp` on the view it finds, which is the call AppKit
        // makes and the point at which a focusable control would take
        // first-responder status.
        log.check("pressing a transport button does not move the first responder", before === after)
        log.check(
            "the first responder is still the document's key view",
            String(describing: after ?? window).contains("KeyView")
                || String(describing: after ?? window).contains("Hosting"))

        // Stopped explicitly rather than sampling `isPlaying` and asserting it
        // flipped. Task 28 made Space a play-from-start for one release, under
        // which a press while already playing leaves `isPlaying` alone and the
        // old form read as the keyboard never having arrived; the deterministic
        // "stopped, pressed, now playing" survives that and says more.
        model.pause()
        await settle(seconds: 0.2)
        let zoom = model.framesPerPixel
        press(.space)
        await settle(seconds: 0.4)
        // Deliberately not skipped when no window is key. Since Task 15 made
        // Space a real menu key equivalent, it is claimed by the menu bar before
        // any first responder is consulted — so it plays whether or not the
        // window has focus, which is the strongest form of "a button cannot
        // break the keyboard" available. The first-responder check above is what
        // covers the focus half.
        log.note(
            "how Space reached the transport",
            NSApp.keyWindow == nil
                ? "no key window (screen locked): through the Playback menu's key equivalent"
                : "with a key window: menu key equivalent, first responder unchanged")
        log.check(
            "Space still reaches the transport after a button was pressed "
                + "(stopped -> \(model.isPlaying))",
            model.isPlaying,
            unless: model.canPlay
                ? nil
                : "there is no audio output session in this run, so play() reports the fact "
                    + "instead of latching and the transport cannot change either way")
        log.check("Space did not re-press the last-pressed button", model.framesPerPixel == zoom)
        if model.isPlaying { press(.space) }
        await settle(seconds: 0.2)
        model.fitWholeFile()
    }

    // MARK: - Loop prominence (Task 15C)

    /// An engaged loop reads as a mode, in both themes.
    ///
    /// Counted in rendered pixels of the status-bar band, the same way the speed
    /// emphasis is: the point of the item is that it reaches the screen. The
    /// loop violet appears nowhere else down there.
    @MainActor
    static func checkLoopProminence(
        model: ViewerModel, log: inout Logger, outputDirectory: String
    ) async {
        let band = statusBarRect()
        model.selectAll()
        model.loopFromSelection()
        if model.loop.isEnabled { model.toggleLoop() }
        await settle(seconds: 0.35)
        let violet = colour(Palette.of(model.appearance).loop)
        // A wider window than the speed check's, because this ink is a mid-tone
        // and the capture's colour round-trip moves it further — see
        // `pixelCount(near:in:tolerance:)`. The loop-off control below is what
        // stops the wider window from making the check vacuous: it still has to
        // read exactly zero.
        let tolerance = 0.15
        let whenOff = pixelCount(near: violet, in: band, tolerance: tolerance)
        model.toggleLoop()
        await settle(seconds: 0.35)
        let whenOn = pixelCount(near: violet, in: band, tolerance: tolerance)
        snapshot(to: "\(outputDirectory)/10-loop-on-\(model.appearance.rawValue).png")

        log.note(
            "status-bar loop pixels (\(model.appearance))",
            "loop off: \(whenOff), loop on: \(whenOn)")
        log.check("an engaged loop is emphasised in the status bar", whenOn > 15)
        log.check("a disengaged loop is not", whenOff == 0)
        log.check("the transport's loop button reads on", model.transportState.loopIsEnabled)

        model.toggleLoop()
        model.clearLoop()
        model.clearSelection()
        await settle(seconds: 0.2)
    }

    // MARK: - Pressing a button

    /// Presses a transport button, by pointer if the pointer works and through
    /// accessibility if it does not, and says which.
    ///
    /// The pointer path is tried first because it is the real thing. It does not
    /// always reach a SwiftUI control here, for the reason `mouseDrag` already
    /// records for `DragGesture`: `NSWindow.sendEvent` refuses to deliver a
    /// click to a window that is not key, and no window can be key while the
    /// login session's screen is locked, so the harness has to call the view's
    /// `mouseDown`/`mouseUp` directly and SwiftUI does not always route those.
    ///
    /// The accessibility path is not a stand-in for a click: it is the same
    /// entry point VoiceOver uses, in-process, needing no permissions, and it
    /// runs the `Button`'s real action — including `restoreFocus`. What it does
    /// not exercise is AppKit's first-responder handling, which is why the focus
    /// check reads the first responder around the press rather than trusting it.
    ///
    /// - Returns: `"pointer"`, `"accessibility"`, or `"nothing landed"`.
    @MainActor
    static func activate(_ control: TransportControl, model: ViewerModel) async -> String {
        let before = fingerprint(model)
        await clickPointer(control, model: model)
        if fingerprint(model) != before { return "pointer" }
        pressViaAccessibility(control, model: model)
        await settle(seconds: 0.25)
        return fingerprint(model) != before ? "accessibility" : "nothing landed"
    }

    /// Everything a transport button can change, as one comparable value.
    @MainActor
    private static func fingerprint(_ model: ViewerModel) -> String {
        "\(model.playhead)|\(model.speed.ratio)|\(model.speed.engine)|"
            + "\(model.framesPerPixel)|\(model.loop)|\(model.isPlaying)"
    }

    @MainActor
    private static func clickPointer(_ control: TransportControl, model: ViewerModel) async {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
            let content = window.contentView,
            let frame = model.transportFrames[control]
        else { return }
        // `transportFrames` is SwiftUI's global space: window content
        // coordinates with a top-left origin. AppKit hit-testing is bottom-up.
        let point = NSPoint(x: frame.midX, y: content.bounds.height - frame.midY)
        guard let target = content.hitTest(point) else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            if type == .leftMouseDown {
                target.mouseDown(with: event)
            } else {
                target.mouseUp(with: event)
            }
            await settle(seconds: 0.05)
        }
        await settle(seconds: 0.25)
    }

    /// Finds the button by its accessibility label — which is exactly
    /// `TransportControl.title(in:)`, so the search is against the same string
    /// the tooltip shows — and presses it.
    @MainActor
    @discardableResult
    private static func pressViaAccessibility(
        _ control: TransportControl, model: ViewerModel
    ) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
            let root = window.contentView
        else { return false }
        let wanted = control.title(in: model.transportState)
        // Hit-test first. A SwiftUI hierarchy builds its accessibility elements
        // lazily — with no assistive client attached, walking `accessibilityChildren`
        // from the hosting view returns nothing at all (measured: "none exposed") —
        // and a hit test is the request that makes AppKit produce them.
        let hit = model.transportFrames[control].flatMap {
            window.accessibilityHitTest(screenPoint(of: $0, in: root, window: window))
                as? any NSAccessibilityProtocol
        }
        if let hit, hit.accessibilityRole() == .button {
            return hit.accessibilityPerformPress()
        }
        guard let element = findButton(labelled: wanted, under: root, depth: 0) else {
            return false
        }
        return element.accessibilityPerformPress()
    }

    /// The centre of a SwiftUI-global rect, in the screen coordinates AppKit's
    /// accessibility hit test wants.
    @MainActor
    private static func screenPoint(
        of frame: CGRect, in view: NSView, window: NSWindow
    ) -> NSPoint {
        let inView = NSPoint(
            x: frame.midX, y: view.isFlipped ? frame.midY : view.bounds.height - frame.midY)
        return window.convertPoint(toScreen: view.convert(inView, to: nil))
    }

    /// Every button the accessibility tree exposes, for the log — so a press
    /// that finds nothing says whether the tree is empty or merely differently
    /// labelled, rather than leaving that to guesswork.
    @MainActor
    private static func accessibilityButtons() -> String {
        guard let root = (NSApp.keyWindow ?? NSApp.windows.first)?.contentView else { return "—" }
        var found: [String] = []
        collectButtons(under: root, depth: 0, into: &found)
        return found.isEmpty ? "none exposed" : found.joined(separator: ", ")
    }

    @MainActor
    private static func collectButtons(under element: Any, depth: Int, into found: inout [String]) {
        guard depth < 40, found.count < 30, let node = element as? any NSAccessibilityProtocol
        else { return }
        if node.accessibilityRole() == .button {
            found.append(node.accessibilityLabel() ?? node.accessibilityTitle() ?? "unlabelled")
        }
        for child in node.accessibilityChildren() ?? [] {
            collectButtons(under: child, depth: depth + 1, into: &found)
        }
    }

    /// Depth-first walk of the accessibility tree. Bounded, because a SwiftUI
    /// hierarchy is deep and a cycle in an `NSAccessibility` implementation
    /// would otherwise hang the run.
    @MainActor
    private static func findButton(
        labelled label: String, under element: Any, depth: Int
    ) -> (any NSAccessibilityProtocol)? {
        guard depth < 40, let node = element as? any NSAccessibilityProtocol else { return nil }
        let matches =
            node.accessibilityLabel() == label || node.accessibilityTitle() == label
        if node.accessibilityRole() == .button, matches { return node }
        for child in node.accessibilityChildren() ?? [] {
            if let found = findButton(labelled: label, under: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}
