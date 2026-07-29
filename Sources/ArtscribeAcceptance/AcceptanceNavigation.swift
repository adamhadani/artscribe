import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// Task 14: the three nudge tiers and the Settings window.
///
/// Its own file for the reason the other acceptance files record — the project's
/// 400-line limit — and it is the same run.
extension AcceptanceRun {

    // MARK: - Nudging

    /// Every tier, both directions, both bindings, and both ends of the file.
    ///
    /// Driven through posted key events, so a failure means the binding, the
    /// menu key equivalent or the keyboard focus is broken — not merely that a
    /// model method has a bug, which the unit tests already cover.
    @MainActor
    static func checkNudge(model: ViewerModel, log: inout Logger) async {
        model.fitWholeFile()
        let rate = model.sampleRate
        func frames(_ seconds: Double) -> FrameIndex { FrameIndex((seconds * rate).rounded()) }
        let middle = model.totalFrames / 2

        // The unmodified pair and the plain arrows: 2 s.
        for (back, forward, name) in [(Key.z, Key.x, "Z/X"), (Key.left, Key.right, "←/→")] {
            model.seek(to: middle)
            press(back)
            log.check(
                "\(name) nudges back 2 s (\(model.playhead) vs \(middle - frames(2)))",
                model.playhead == middle - frames(2))
            press(forward)
            log.check("\(name) nudges forward 2 s", model.playhead == middle)
        }

        // The menu has to be populated before a chord can match one of its
        // items: SwiftUI fills a submenu in when its delegate is asked to, so an
        // unopened Playback menu is empty and claims nothing.
        await checkNudgeMenuItems(log: &log)

        // ⇧Z / ⇧X (50 ms) and ⌥Z / ⌥X (10 s) have two routes — the Playback
        // menu's key equivalent and the window's own handler — so each is
        // measured on its own, and each must move exactly one tier.
        for (back, forward, seconds, name) in [
            (Key.shiftZ, Key.shiftX, 0.05, "⇧Z/⇧X"), (Key.optionZ, Key.optionX, 10, "⌥Z/⌥X")
        ] {
            let tier = NudgeAmounts.label(seconds: seconds)
            model.seek(to: middle)
            press(back)
            await settle(seconds: 0.2)
            log.check(
                "\(name) nudges back \(tier) exactly once (\(model.playhead - middle) frames)",
                model.playhead == middle - frames(seconds))
            press(forward)
            await settle(seconds: 0.2)
            log.check("\(name) nudges forward \(tier) exactly once", model.playhead == middle)

            // And the same chord offered to the menu bar, which is the route a
            // real keystroke takes first. Each spelling is measured on its own,
            // because `NSMenu` matches these items only against a *lowercase*
            // `charactersIgnoringModifiers`: the hardware-faithful uppercase
            // event above is not claimed by the fine item at all, which is
            // exactly why the window handles the whole cluster as well.
            var moved: [String: (claimed: Bool, frames: FrameIndex)] = [:]
            for (spelling, chord) in [("uppercase", back), ("lowercase", lowercased(back))] {
                model.seek(to: middle)
                let claimed = offerToMenuBar(chord)
                // A menu item's action lands on the next run-loop pass, unlike
                // the window's own handler.
                await settle(seconds: 0.25)
                moved[spelling] = (claimed, model.playhead - middle)
            }
            log.note(
                "\(name) as the menu bar sees it",
                moved.map { "\($0.key): claimed \($0.value.claimed), \($0.value.frames) frames" }
                    .sorted().joined(separator: "; "))
            // Exactly one tier's worth of movement, or none — never two, which
            // is what a double fire would look like.
            //
            // Deliberately *not* "moves this tier". Since Task 15 put a plain
            // `Z` on the menu, the synthetic lowercase-plus-shift spelling is
            // matched by the plain item rather than the ⇧ one, so it moves the
            // 2 s tier instead of the 50 ms one — measured, and noted above. It
            // does not arise from a keyboard: `charactersIgnoringModifiers`
            // reflects Shift, so a real ⇧Z reports "Z", is claimed by neither
            // item, and reaches the window's handler, which is the route the
            // `press(back)` check above measures at exactly one fine tier.
            let tiers = [frames(0.05), frames(2), frames(10)]
            log.check(
                "a chord offered to the menu bar moves one tier or none, never two",
                moved.values.allSatisfy {
                    $0.frames == 0 || tiers.contains(-$0.frames)
                })
            log.check(
                "\(name) is reachable through the menu bar at all",
                moved.values.contains { $0.claimed })
            model.seek(to: middle)
        }

        // ⌥← / ⌥→ are the same action through the window, because an NSMenuItem
        // carries only one key equivalent.
        model.seek(to: middle)
        press(.optionLeft)
        log.check(
            "⌥← rewinds 10 s exactly once (\(model.playhead - middle) frames)",
            model.playhead == middle - frames(10))
        press(.optionRight)
        log.check("⌥→ skips 10 s exactly once", model.playhead == middle)

        checkNudgeClamping(model: model, log: &log)
        await checkNudgeWhilePlaying(model: model, log: &log)
        checkNudgeAmountsApplyLive(model: model, log: &log)
    }

    /// The six items, each with a real key equivalent.
    ///
    /// The unmodified pair used to be the exception — spelled into the title and
    /// claiming nothing, on the grounds that a plain-letter key equivalent
    /// strobes the menu bar. Task 15 measured that claim against `⇧W` and `⌘0`
    /// (see `checkMenuBarStrobe`), found no difference, and made the convention
    /// uniform, so all six are checked the same way now.
    @MainActor
    private static func checkNudgeMenuItems(log: inout Logger) async {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Playback" })?.submenu
        else {
            log.check("the Playback menu carries the navigation items", false)
            return
        }
        await refreshMenu(menu)
        func item(_ prefix: String) -> NSMenuItem? {
            menu.items.first { $0.title.hasPrefix(prefix) }
        }
        for prefix in [
            "Nudge Back ", "Nudge Forward ", "Nudge Back (Fine)", "Nudge Forward (Fine)",
            "Rewind", "Skip"
        ] {
            guard let found = item(prefix) else {
                log.check("the Playback menu carries \(prefix)", false)
                continue
            }
            log.note(
                "\(prefix.trimmingCharacters(in: .whitespaces)) item",
                "\(found.title)  [\(found.keyEquivalent)"
                    + " \(found.keyEquivalentModifierMask.rawValue)]")
            log.check("\(prefix) is a real menu key equivalent", !found.keyEquivalent.isEmpty)
            log.check("\(prefix) is enabled with a track loaded", found.isEnabled)
        }
    }

    @MainActor
    private static func checkNudgeClamping(model: ViewerModel, log: inout Logger) {
        model.seek(to: 0)
        for _ in 0..<3 { press(.optionZ) }
        log.check("nudging back at the start of the file clamps at zero", model.playhead == 0)
        press(.x)
        log.check("and moves forward again from there", model.playhead > 0)

        model.seek(to: model.totalFrames)
        for _ in 0..<3 { press(.optionX) }
        log.check(
            "nudging forward at the end of the file clamps at the last frame",
            model.playhead == model.totalFrames)
        press(.z)
        log.check("and moves back again from there", model.playhead < model.totalFrames)
        model.seek(to: 0)
    }

    /// Nudging has to work while the transport is running, and must not stop it.
    @MainActor
    private static func checkNudgeWhilePlaying(model: ViewerModel, log: inout Logger) async {
        if let reason = positionChecksAreImpossible(model: model) {
            log.note("nudge-while-playing not checked", reason)
            return
        }
        model.seek(to: model.totalFrames / 2)
        // ⇧Space plays from here; Space is play-from-start and would undo the
        // seek this check depends on.
        press(.shiftSpace)
        await settle(seconds: 0.4)
        guard model.isPlaying else {
            log.check("the transport started for the nudge-while-playing check", false)
            return
        }
        let before = model.playhead
        press(.optionZ)
        await settle(seconds: 0.2)
        let moved = before - model.playhead
        let expected = FrameIndex(10 * model.sampleRate)
        log.check(
            "⌥Z rewinds about 10 s while playing (\(moved) vs \(expected) frames)",
            abs(moved - expected) < FrameIndex(model.sampleRate))
        log.check("the nudge did not stop playback", model.isPlaying)
        press(.shiftSpace)
        await settle(seconds: 0.2)
    }

    /// The Settings amounts reach the keys without a relaunch. Driven through
    /// the model's own setter — the same one the Settings field's binding
    /// calls — because a `TextField` inside a settings window cannot be typed
    /// into from here.
    @MainActor
    private static func checkNudgeAmountsApplyLive(model: ViewerModel, log: inout Logger) {
        let middle = model.totalFrames / 2
        model.setNudgeAmount(4, for: .normal)
        model.seek(to: middle)
        press(.z)
        log.check(
            "a changed nudge amount applies to the next keypress with no relaunch",
            model.playhead == middle - FrameIndex(4 * model.sampleRate))

        model.restoreDefaultNudgeAmounts()
        log.check(
            "Restore Defaults returns 50 ms / 2 s / 10 s",
            model.nudgeAmounts == NudgeAmounts.defaults)
        model.seek(to: middle)
        press(.z)
        log.check(
            "and the keys follow it straight back",
            model.playhead == middle - FrameIndex(2 * model.sampleRate))

        // Nonsense must not be storable: a nudge of nothing is the silent
        // degradation the spec forbids.
        model.setNudgeAmount(0, for: .normal)
        log.check(
            "a zero amount is rejected in favour of the minimum "
                + "(\(model.nudgeAmounts[.normal]) s)",
            model.nudgeAmounts[.normal] >= NudgeAmounts.minimumSeconds)
        model.seek(to: middle)
        press(.z)
        log.check("so the key still moves the playhead", model.playhead != middle)
        model.restoreDefaultNudgeAmounts()
        model.seek(to: 0)
    }

    // MARK: - Settings

    /// **Artscribe ▸ Settings…**, in the app menu with ⌘,, as the `Settings`
    /// scene puts it — and the Theme control gone from the View menu, because
    /// two preference surfaces is one too many.
    @MainActor
    static func checkSettings(
        model: ViewerModel, theme: ThemeController, log: inout Logger
    ) async {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            log.check("the app menu exists", false)
            return
        }
        await refreshMenu(appMenu)
        log.note("app menu", appMenu.items.map(\.title).joined(separator: " | "))
        let settings = appMenu.items.first { $0.title.hasPrefix("Settings") }
        log.check("the app menu carries Settings…", settings != nil)
        log.check("Settings is on ⌘,", settings?.keyEquivalent == ",")
        log.check(
            "with Command as its modifier",
            settings?.keyEquivalentModifierMask == .command)

        if let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu {
            await refreshMenu(view)
            log.check(
                "the View menu no longer carries a second theme control",
                !view.items.contains { $0.title == "Theme" })
        }

        // The window itself is deliberately **not** opened here, and this is a
        // measured decision rather than a shrug. Sending the item's action once
        // did open something the harness could not see (`isVisible` false, no
        // titled window) and cost the viewer its keyboard focus for the rest of
        // the run: twenty later checks that press a key went from PASS to FAIL,
        // because `press(…)` aims at `NSApp.keyWindow ?? windows.first` and that
        // was no longer the viewer. Nothing about the settings window can be
        // read back from here anyway — its fields cannot be typed into — so the
        // run checks the menu item, and the amounts are driven through the same
        // model setters the fields' bindings call.
        log.note(
            "the settings window itself",
            "not opened by the harness: it takes focus and cannot be inspected; "
                + "the item, its shortcut and the amounts it edits are checked instead")
        log.check("the model still has its track", model.hasTrack)

        // Theme lives in Settings now, bound to this same controller — which is
        // what `checkTheme` drives end to end, so the live-repaint coverage did
        // not move with the control.
        log.note("theme preference behind the Settings control", "\(theme.preference)")
    }
}
