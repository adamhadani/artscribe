import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// **Task 21's Practice hub, driven for real.**
///
/// Three things here cannot be reached by a unit test, and they are the whole
/// reason this group exists:
///
/// * `⌘P` puts a real, visible, resizable `NSWindow` on screen, **and the
///   waveform keeps every pixel of its width** — measured through
///   `Viewport.widthPixels`, which only `ViewerModel.setLaneSize` writes. That
///   is the reason the hub is a window rather than an inspector page, and Task
///   20 got it the wrong way round once already.
/// * The empty state. With no loop, the window has to say what is missing
///   rather than offer a Start button that does nothing.
/// * **The ramp advancing on real loop wraps.** `PracticeRampTests` feeds the
///   wrap detector positions by hand; this one plays a real four-second loop
///   through the real render thread and watches the repetition counter climb on
///   its own. It is the only place the two halves — the engine's wrap and the
///   ramp's step — are ever proved to meet.
///
/// The last of those needs the CoreAudio render thread to actually be called,
/// which is not true in every agent session, so it is gated on the app's own
/// device notice exactly as the other position-based checks are.
extension AcceptanceRun {

    @MainActor
    static func checkPracticeHub(
        model: ViewerModel, theme: ThemeController, context: MenuContext, log: inout Logger,
        outputDirectory: String
    ) async {
        checkNoTwoMenuItemsShareAChord(log: &log)
        await checkPracticeWindowIsSeparate(
            model: model, theme: theme, context: context, log: &log,
            outputDirectory: outputDirectory)
        await checkRampOverRealWraps(
            model: model, theme: theme, log: &log, outputDirectory: outputDirectory)
        context.practice.show()
        await settle(seconds: 0.4)
        practiceWindow()?.performClose(nil)
        await settle(seconds: 0.4)
        model.stopRamp()
        model.clearLoop()
        model.setSpeedPreset(1.0)
    }

    /// The whole menu bar, scanned for a key equivalent claimed twice.
    ///
    /// `ActionCatalogTests.noTwoActionsShareAChord` proves the *catalog* has no
    /// duplicate. What it cannot see is a collision with an item this app never
    /// declared — a standard group SwiftUI or AppKit contributes, which is
    /// exactly the risk `⌘P` runs, since `⌘P` is Print on most Mac apps. Asked
    /// of the live menu bar, so the answer is about what is on screen.
    @MainActor
    private static func checkNoTwoMenuItemsShareAChord(log: inout Logger) {
        var owners: [String: [String]] = [:]
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let chord = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
                    owners[chord, default: []].append("\(path)\(item.title)")
                }
                if let submenu = item.submenu { walk(submenu, path: "\(path)\(item.title) ▸ ") }
            }
        }
        if let main = NSApp.mainMenu { walk(main, path: "") }
        let clashes = owners.filter { $0.value.count > 1 }
        for (chord, titles) in clashes {
            log.note("chord claimed twice", "\(chord): \(titles.joined(separator: ", "))")
        }
        log.check(
            "no two menu items in the whole menu bar share a key equivalent "
                + "(\(owners.count) chords)",
            clashes.isEmpty)
    }

    /// `⌘P`, and the width the waveform must not lose.
    @MainActor
    private static func checkPracticeWindowIsSeparate(
        model: ViewerModel, theme: ThemeController, context: MenuContext, log: inout Logger,
        outputDirectory: String
    ) async {
        // Deliberately with the loop cleared, so the first thing captured is the
        // empty state.
        model.stopRamp()
        model.clearLoop()
        let before = model.viewport.widthPixels
        // Held from before the second window exists, and by identity: the
        // document window is renamed after the loaded track, so looking it up by
        // title later would find nothing.
        let document = NSApp.keyWindow ?? NSApp.windows.first

        press(.commandP)
        await settle(seconds: 1.2)
        var window = practiceWindow()
        if window == nil {
            // The same fallback the shortcut window's check has: a synthesised
            // ⌘ chord reaches the menu bar only when this process can be active,
            // which it cannot while the login session's screen is locked.
            log.note("⌘P path", "the synthesised chord did not reach the menu bar; opened directly")
            context.practice.show()
            await settle(seconds: 1.2)
            window = practiceWindow()
        }
        guard let window else {
            log.check("⌘P opens a Practice window", false)
            return
        }
        log.check("⌘P opens a Practice window", true)
        log.check("it is visible", window.isVisible)
        log.check(
            "it is resizable (styleMask \(window.styleMask.rawValue))",
            window.styleMask.contains(.resizable))
        log.check("it has a close button of its own", window.styleMask.contains(.closable))
        log.note("its frame", "\(window.frame)")

        let during = model.viewport.widthPixels
        log.check(
            "the waveform keeps its full width (\(before) → \(during) px)", during == before)

        // The empty state: no loop, so nothing can ramp and the window has to
        // say so rather than offering a control that does nothing.
        log.check("with no loop, a ramp cannot be started", !model.canRamp)
        model.startRamp()
        log.check("and pressing Start with no loop does nothing", model.ramp.isIdle)
        // What the empty state *says* is checked in `PracticeRampTests` against
        // the strings themselves, and captured here. It is deliberately not read
        // off the screen: SwiftUI does not materialise its accessibility tree
        // until an assistive client attaches, so an AX walk of this window
        // returns its title and nothing else — measured, and it made two checks
        // pass vacuously before it was noticed.
        log.note("empty state", "captured to 26-practice-no-loop.png; text asserted in unit tests")
        snapshot(window, to: "\(outputDirectory)/26-practice-no-loop.png")

        // Both themes, like the shortcut window: the light palette is designed
        // rather than inverted, so it has to be seen to reach the screen.
        let wasTheme = theme.preference
        theme.preference = .light
        await settle(seconds: 0.8)
        snapshot(window, to: "\(outputDirectory)/27-practice-light.png")
        theme.preference = wasTheme
        await settle(seconds: 0.5)

        // Closable on its own, and the document is untouched by it.
        let documentWasVisible = document?.isVisible == true
        window.performClose(nil)
        await settle(seconds: 0.8)
        log.check("the window closes on its own", practiceWindow()?.isVisible != true)
        log.check("the document window was there to survive it", documentWasVisible)
        log.check("and the document window is untouched", document?.isVisible == true)
        log.check(
            "the waveform is still the width it was (\(model.viewport.widthPixels) px)",
            model.viewport.widthPixels == before)
    }

    /// Sets the loop and starts the ramp, checking every precondition on the way.
    ///
    /// Split from the watching half for length. The loop is deliberately left
    /// **switched off** before starting: turning it on is what keeps the Start
    /// button from silently doing nothing on a region that exists.
    @MainActor
    private static func armRamp(model: ViewerModel, log: inout Logger, stalled: String?) {
        let inPoint = FrameIndex(model.sampleRate * 30)
        let outPoint = FrameIndex(model.sampleRate * 34)
        model.seek(to: inPoint)
        press(.a)
        model.seek(to: outPoint)
        press(.s)
        log.check("a four-second loop is set for the ramp", model.loop.range.count > 0)
        log.check("and a ramp can now be started", model.canRamp)
        if model.loop.isEnabled { press(.d) }
        log.check("the loop is set but switched off", !model.loop.isEnabled)

        // Three repetitions rather than the default ten: at four seconds a pass
        // that is twelve seconds of real time at tempo, and it completes inside
        // this run rather than being cut off half way.
        model.setRampSchedule(RampSchedule(startRatio: 0.5, endRatio: 1.0, repetitions: 3))
        // ⌥P — a plain modified letter, which `NSMenu` will not claim from a
        // synthesised event, so the window's own handler is what answers.
        press(.optionP)
        if !model.ramp.isRunning {
            log.note("⌥P path", "the synthesised chord did not fire; started through the model")
            model.startRamp()
        }
        log.check("the ramp is running", model.ramp.isRunning)
        log.check("starting it switched looping on", model.loop.isActive)
        log.check("it began at the start speed (50%)", model.speed.ratio == 0.5)
        log.check("and at the loop's in point", model.playhead == model.loop.range.start)
        log.check("the transport is playing", model.isPlaying, unless: stalled)
    }

    /// What the window shows while the ramp runs — a practice tool whose progress
    /// is invisible is a stopwatch you cannot see.
    ///
    /// Read from the same functions the window's body draws, and asked of the
    /// *running* model rather than a constructed one, so a ramp that advanced
    /// without the readout following it would fail here. That the strings reach
    /// the screen is what the screenshot beside this is for: SwiftUI does not
    /// materialise its accessibility tree until an assistive client attaches, so
    /// there is nothing on screen for this process to read back.
    @MainActor
    private static func checkLiveReadout(model: ViewerModel, log: inout Logger) {
        log.check(
            "the readout names the repetition it is on",
            PracticeReadout.headline(model.ramp) == "Repetition 1 of 3")
        log.check(
            "and how many are left",
            PracticeReadout.remaining(model.ramp) == "2 more repetitions")
        log.check(
            "and the loop it is practising",
            PracticeReadout.loop(range: model.loop.range, sampleRate: model.sampleRate)
                .contains("4.0 s"))
    }

    /// **The ramp against real audio.** A four-second loop, three repetitions,
    /// 50% to 100%, played until it completes.
    ///
    /// The assertions are the ones a timer-driven implementation could not
    /// satisfy: the repetition index only ever moves when the playhead has just
    /// jumped backwards, it moves once per pass and not once per poll, and the
    /// speed the transport is at follows the schedule rather than the clock.
    @MainActor
    private static func checkRampOverRealWraps(
        model: ViewerModel, theme: ThemeController, log: inout Logger, outputDirectory: String
    ) async {
        let stalled = positionChecksAreImpossible(model: model)
        armRamp(model: model, log: &log, stalled: stalled)
        for _ in 0..<9 { model.zoomIn() }
        model.centre(on: model.loop.range.start + model.loop.range.count / 2)
        await settle(seconds: 0.4)
        snapshot(practiceWindow(), to: "\(outputDirectory)/28-practice-running.png")
        checkLiveReadout(model: model, log: &log)

        // Watch it. Two things are recorded: the repetition counter's steps, and
        // how long each repetition lasted in **wall clock**.
        //
        // The durations are the evidence that this is not a timer. A four-second
        // loop takes 8 s to play at 50%, 5.33 s at 75% and 4 s at 100% — so a
        // ramp that follows the loop produces intervals that shorten as it
        // climbs, in the ratio the speeds dictate, while any fixed-interval
        // implementation produces equal ones. Nothing here could tell those two
        // apart from the counter alone.
        var repetitions = [model.ramp.repetition]
        var speeds = [model.speed.ratio]
        var durations: [Double] = []
        var wraps = 0
        var lastAdvance = Date()
        var previous = model.playhead
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, model.ramp.isRunning {
            await settle(seconds: 0.02)
            let now = model.playhead
            if now < previous - 4096 { wraps += 1 }
            previous = now
            if model.ramp.repetition != repetitions.last {
                durations.append(Date().timeIntervalSince(lastAdvance))
                lastAdvance = Date()
                repetitions.append(model.ramp.repetition)
                speeds.append(model.speed.ratio)
            }
        }

        log.note("repetitions observed", "\(repetitions)")
        log.note("speeds observed", "\(speeds)")
        log.note(
            "seconds per repetition",
            durations.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        log.check(
            "the ramp advanced once per repetition (\(repetitions.count) of 3)",
            repetitions == [1, 2, 3], unless: stalled)
        // Deliberately `>=`, and deliberately not an equality.
        //
        // `wraps` here is the *naive* count — every backward step of more than a
        // block — which is more than the number of laps, because the audible
        // position jitters across the boundary each time the ramp changes the
        // speed. That is measured and documented in `LoopWrapTracker`, and it is
        // exactly what the product's own rule has to see through. Asserting
        // equality would either fail on that jitter or force this check to
        // reimplement the rule it is supposed to be independent of; what it can
        // honestly say is that no repetition happened without the loop coming
        // round at all. The *timing* check below is the sharp one.
        log.note("naive boundary crossings", "\(wraps) (laps: \(repetitions.count - 1))")
        log.check(
            "no repetition advanced without the loop coming round "
                + "(\(repetitions.count - 1) advances, \(wraps) crossings)",
            wraps >= repetitions.count - 1, unless: stalled)
        log.check(
            "the speed followed the schedule (\(speeds))",
            speeds == [0.5, 0.75, 1.0], unless: stalled)
        // 8 s then 5.33 s, give or take the 20 ms sampling and the audible-position
        // latency compensation. The bound is loose on purpose — what it has to
        // exclude is *equal* intervals, which is what a timer would give.
        let durationLabel = durations.map { String(format: "%.2f s", $0) }
            .joined(separator: " then ")
        log.check(
            "each repetition took as long as the loop does at its speed, not a fixed "
                + "interval (\(durationLabel))",
            durations.count == 2 && durations[0] > durations[1] * 1.25
                && abs(durations[0] - 8.0) < 1.5 && abs(durations[1] - 16.0 / 3) < 1.2,
            unless: stalled)
        log.check(
            "the ramp completed rather than running on",
            model.ramp.phase == .complete, unless: stalled)
        log.check(
            "it holds the final speed rather than resetting it (\(model.speed.ratio))",
            model.speed.ratio == 1.0, unless: stalled)
        log.check(
            "and it did not stop the transport", model.isPlaying, unless: stalled)
        log.check("the loop is still going round", model.loop.isActive, unless: stalled)
        log.check(
            "and the completion is stated rather than left to be inferred",
            PracticeReadout.headline(model.ramp) == "Ramp complete — holding 100%",
            unless: stalled)
        snapshot(practiceWindow(), to: "\(outputDirectory)/29-practice-complete.png")

        // The whole window in the light theme, which is designed rather than
        // inverted and so has to be seen to reach the screen.
        let wasTheme = theme.preference
        theme.preference = .light
        await settle(seconds: 0.8)
        snapshot(practiceWindow(), to: "\(outputDirectory)/30-practice-light-complete.png")
        theme.preference = wasTheme
        await settle(seconds: 0.5)

        press(.space)
        await settle(seconds: 0.2)
    }

    @MainActor
    private static func practiceWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Practice" }
    }
}
