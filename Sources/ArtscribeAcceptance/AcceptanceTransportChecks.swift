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
        log.note(
            "transport layout",
            TransportControl.allCases.map {
                "\($0)@\(frames[$0].map { rounded($0.midX) } ?? "—")"
            }.joined(separator: " "))
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
    /// **Every press happens first; the verdict is passed afterwards.** The
    /// order matters, and the reason is a run that reported five of these as
    /// failures on a machine where no press could be delivered at all. The old
    /// form decided deliverability from the *first* press alone — if Zoom In did
    /// not land it asked whether the screen was locked, and an unlocked machine
    /// whose frontmost app was someone's terminal answered "no", so every
    /// remaining check failed for a reason that had nothing to do with the
    /// buttons.
    ///
    /// Two facts are now kept apart:
    ///
    /// * **Did any press land?** Collected across all eight, not one. A single
    ///   broken button among working ones still fails, because the other seven
    ///   prove the delivery path works — which is the property the old
    ///   "deliberately not inferred from the result" comment was protecting, and
    ///   it survives here.
    /// * **Can this session deliver a press at all?** Asked of the machine —
    ///   `screenIsLocked`, `NSApp.isActive` — never of the model.
    ///
    /// A check is skipped only when *nothing* landed **and** the session cannot
    /// deliver. Nothing landing on a machine that can deliver is a real failure,
    /// and still reads as one.
    @MainActor
    private static func checkButtonsDriveTheModel(model: ViewerModel, log: inout Logger) async {
        var paths: Set<String> = []
        var results: [(String, Bool)] = []

        // Come to the front before pressing anything. A plain `activate()` is
        // the call that silently does nothing when the caller is not already
        // the active app — the defect that left four focus fixes unverifiable —
        // and `ignoringOtherApps` is the form that works from a background
        // shell. Skipping these checks is the fallback; making them deliverable
        // is the point.
        NSApp.activate(ignoringOtherApps: true)
        await settle(seconds: 0.5)

        model.fitWholeFile()
        let fitted = model.framesPerPixel
        paths.insert(await activate(.zoomIn, model: model))
        let zoomedIn = model.framesPerPixel
        results.append(("pressing Zoom In zooms in", zoomedIn < fitted))

        paths.insert(await activate(.zoomOut, model: model))
        // A transition, not a destination. `>= fitted * 0.999` on its own is
        // true when neither press landed and the view never left `fitted` —
        // this check passed green through the whole run that prompted the fix,
        // on a delivery path that did not work.
        results.append(
            (
                "pressing Zoom Out zooms back out "
                    + "(\(rounded(zoomedIn)) -> \(rounded(model.framesPerPixel)))",
                model.framesPerPixel > zoomedIn && model.framesPerPixel >= fitted * 0.999
            ))

        model.setSpeedPreset(1.0)
        paths.insert(await activate(.slower, model: model))
        let slowed = model.speed.ratio
        results.append(("pressing − steps the speed exactly as Q does (\(slowed))", slowed == 0.95))
        paths.insert(await activate(.faster, model: model))
        // Likewise: `== 1.0` alone is true when neither press landed.
        results.append(
            (
                "pressing + steps it back (\(slowed) -> \(model.speed.ratio))",
                model.speed.ratio > slowed && model.speed.ratio == 1.0
            ))

        model.seek(to: model.totalFrames / 2)
        let middle = model.playhead
        let step = FrameIndex((model.prefs.nudgeAmounts[.normal] * model.sampleRate).rounded())
        paths.insert(await activate(.nudgeForward, model: model))
        let nudged = model.playhead
        results.append(
            (
                "pressing nudge-forward moves one normal tier (\(nudged - middle))",
                nudged - middle == step
            ))
        paths.insert(await activate(.nudgeBackward, model: model))
        results.append(
            (
                "pressing nudge-back returns (\(nudged) -> \(model.playhead))",
                model.playhead < nudged && model.playhead == middle
            ))

        model.selectAll()
        model.loopFromSelection()
        let looping = model.loop.isEnabled
        paths.insert(await activate(.loop, model: model))
        results.append(
            (
                "pressing the loop button toggles looping (\(looping) -> \(model.loop.isEnabled))",
                model.loop.isEnabled != looping
            ))
        results.append(
            ("and the button reads its new state", model.transportState.loopIsEnabled != looping))

        // The bar's other mode button, and the one a user found inert by hand
        // when the `.preroll` case was missing from `performSpeedOrView`. Now
        // that a press reaches the control, that defect is reachable from the
        // harness rather than only from someone clicking it.
        let prerollWas = model.prefs.prerollEnabled
        paths.insert(await activate(.preroll, model: model))
        results.append(
            (
                "pressing the preroll button toggles it "
                    + "(\(prerollWas) -> \(model.prefs.prerollEnabled))",
                model.prefs.prerollEnabled != prerollWas
            ))
        if model.prefs.prerollEnabled != prerollWas { model.togglePreroll() }
        model.clearLoop()
        model.clearSelection()
        model.setSpeedPreset(1.0)
        model.seek(to: 0)

        let landed = paths.contains { $0 != "nothing landed" }
        let undeliverable = landed ? nil : sessionCannotDeliverAPress()
        log.note("button press path", paths.sorted().joined(separator: ", "))
        if let undeliverable {
            log.note("transport button checks skipped", undeliverable)
        }
        for (name, passed) in results { log.check(name, passed, unless: undeliverable) }
    }

    /// Why a synthesised press cannot reach a SwiftUI control in this session,
    /// or `nil` if it can and a press that did nothing is a real defect.
    ///
    /// Asked of the machine only. Both conditions are independent of whether any
    /// button works, which is what keeps a broken button from excusing itself:
    ///
    /// * **The screen is locked.** No application can become active, so nothing
    ///   can be key and AppKit builds no accessibility elements to press.
    /// * **This app is not active.** How an agent reaches it — the run is
    ///   launched from a background shell while someone is using the Mac, so
    ///   Artscribe never comes to the front, `NSWindow.sendEvent` will not
    ///   deliver a click to a window that is not key, and the accessibility
    ///   tree stays unbuilt. Measured: `button press path: nothing landed`,
    ///   `transport buttons in the accessibility tree: none exposed`.
    ///
    /// To make these checks run for real, launch the harness so that Artscribe
    /// comes to the front and leave it frontmost for the transport group.
    @MainActor
    static func sessionCannotDeliverAPress() -> String? {
        if screenIsLocked() {
            return "the login session's screen is locked (CGSSessionScreenIsLocked), so no "
                + "application can become active and a synthesised pointer event does not "
                + "reach a SwiftUI control — the same limitation the selection drag records"
        }
        if !NSApp.isActive {
            return "Artscribe is not the active application (NSApp.isActive == false — the run "
                + "was launched from a background shell), so a synthesised pointer event does "
                + "not reach a SwiftUI control and AppKit builds no accessibility elements to "
                + "press instead"
        }
        return nil
    }

    /// Whether this login session's screen is locked, asked of CoreGraphics.
    ///
    /// One of the two independent facts behind every skip in this file.
    /// Deliberately not inferred from "the press did nothing", which would turn
    /// any broken button into a skip.
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
        // "The focus did not move" is the one assertion here that a press which
        // never arrived satisfies perfectly. It is still worth making when the
        // harness reached a view — hit-testing the button's own frame and
        // calling `mouseDown`/`mouseUp` is the call AppKit makes, and the point
        // at which a focusable control would take first-responder status — but
        // when nothing landed at all it is measuring nothing, so it says so
        // rather than reading green.
        let undeliverable = path == "nothing landed" ? sessionCannotDeliverAPress() : nil
        log.check(
            "pressing a transport button does not move the first responder", before === after,
            unless: undeliverable)
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
        let violet = colour(Palette.of(model.cache.appearance).loop)
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
        snapshot(to: "\(outputDirectory)/10-loop-on-\(model.cache.appearance.rawValue).png")

        log.note(
            "status-bar loop pixels (\(model.cache.appearance))",
            "loop off: \(whenOff), loop on: \(whenOn)")
        log.check("an engaged loop is emphasised in the status bar", whenOn > 15)
        log.check("a disengaged loop is not", whenOff == 0)
        log.check("the transport's loop button reads on", model.transportState.loopIsEnabled)

        model.toggleLoop()
        model.clearLoop()
        model.clearSelection()
        await settle(seconds: 0.2)
    }
}
