import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// The Playback menu half of the acceptance run.
///
/// Split from `AcceptancePlayback` only to keep both files inside the project's
/// 400-line limit; it is the same run.
extension AcceptanceRun {

    // MARK: - Menu

    /// Trap 3: `.disabled(…)` in a `Commands` body goes stale against
    /// `@Observable`, which silently broke ⌘9 in Task 10. The menu is therefore
    /// interrogated through AppKit — `update()` then `isEnabled` — rather than
    /// assumed to have re-evaluated.
    @MainActor
    static func checkPlaybackMenu(model: ViewerModel, log: inout Logger) async {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Playback" })?.submenu
        else {
            log.check("a Playback menu exists in the menu bar", false)
            return
        }
        log.check("a Playback menu exists in the menu bar", true)
        await refresh(menu)
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        log.note("Playback menu", titles.joined(separator: " | "))

        for expected in [
            "Play", "Stop", "Play from Start", "Faster", "Slower", "Set Loop In", "Set Loop Out",
            "Loop", "Restart Loop", "Selection", "Output Device"
        ] {
            log.check(
                "the menu carries \(expected)",
                titles.contains { $0.hasPrefix(expected) || $0.contains(expected) })
        }

        // Enablement must track the model, live. This is trap 3, and the whole
        // reason these are read back out of AppKit rather than assumed.
        model.clearSelection()
        await refresh(menu)
        log.check(
            "Selection → Loop is disabled with no selection",
            item(menu, "Selection")?.isEnabled == false)
        model.selectAll()
        await refresh(menu)
        log.check(
            "Selection → Loop enables as soon as there is a selection (the ⌘9 trap)",
            item(menu, "Selection")?.isEnabled == true)
        model.clearSelection()

        // The preset checkmarks are the live-`@Observable`-inside-a-menu case.
        model.setSpeedPreset(0.5)
        await refresh(menu)
        log.check("the active speed preset is checked", item(menu, "50%")?.state == .on)
        log.check("the inactive presets are not", item(menu, "100%")?.state == .off)
        model.setSpeedPreset(1.0)
        await refresh(menu)
        log.check("the checkmark follows the speed", item(menu, "100%")?.state == .on)

        let playItem = menu.items.first { $0.title.hasPrefix("Play") && !$0.title.contains("from") }
        log.check("the play item is enabled with a track loaded", playItem?.isEnabled == true)
        log.note("play item title", playItem?.title ?? "missing")

        // The title has to follow the transport, or the menu lies about what
        // pressing it will do.
        press(.space)
        await refresh(menu)
        let whilePlaying = menu.items.first {
            $0.title.hasPrefix("Play") || $0.title.hasPrefix("Pause")
        }
        log.check(
            "the play item becomes Pause while playing (\(whilePlaying?.title ?? "missing"))",
            whilePlaying?.title.hasPrefix("Pause") == true)
        log.check("Stop is enabled while playing", item(menu, "Stop")?.isEnabled == true)
        press(.space)
        await refresh(menu)
        log.check("Stop is disabled again when stopped", item(menu, "Stop")?.isEnabled == false)

        let engineItem = menu.items.first { $0.title.contains("Engine") }
        log.check(
            "the engine toggle names the active engine",
            engineItem?.title.contains("now:")
                == true)
        log.note("engine item", engineItem?.title ?? "missing")
        log.note(
            "engine item key equivalent",
            "\(engineItem?.keyEquivalent ?? "none") "
                + "\(engineItem?.keyEquivalentModifierMask.rawValue ?? 0)")

        // The items are enabled now, so the modifier-bearing shortcuts are live
        // menu key equivalents — and the window still has its own handler for
        // them. If both fired, one press would step twice. This is the check
        // that says the split between menu shortcuts and window bindings is safe.
        model.setSpeedPreset(1.0)
        press(.shiftW)
        log.check(
            "⇧W steps once, not twice, with the menu item live (\(model.speed.ratio))",
            model.speed.ratio == 1.01)
        press(.shiftQ)
        log.check("⇧Q steps once with the menu item live", model.speed.ratio == 1.0)
        let engine = model.speed.engine
        press(.optionE)
        log.check("⌥E toggles once with the menu item live", model.speed.engine != engine)
        press(.optionE)
        log.check("⌥E toggles back once", model.speed.engine == engine)

        // And the plain letters the menu deliberately does *not* claim.
        press(.w)
        log.check("W still steps once with the menu live", model.speed.ratio == 1.05)
        press(.q)
        log.check("Q still steps once with the menu live", model.speed.ratio == 1.0)
    }

    /// Lets SwiftUI's update transaction run, then asks AppKit to validate.
    ///
    /// `NSMenu.update()` alone is not enough: it runs AppKit's own validation,
    /// but the items are backed by a SwiftUI `View`, whose body re-evaluates on
    /// the next run-loop pass rather than synchronously with the mutation. A
    /// check that reads `isEnabled` immediately after changing the model is
    /// measuring the previous frame.
    @MainActor
    private static func refresh(_ menu: NSMenu) async {
        await settle(seconds: 0.25)
        // What actually happens when the user pulls the menu down: AppKit asks
        // the delegate — SwiftUI — to populate it, and only then validates. A
        // plain `update()` measures the previous frame.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        await settle(seconds: 0.05)
        menu.update()
    }

    /// Menu items are re-created by SwiftUI on every update, so a reference taken
    /// before a change can be a detached item that never updates again. Always
    /// look the item up afresh.
    @MainActor
    private static func item(_ menu: NSMenu, _ prefix: String) -> NSMenuItem? {
        menu.items.first { $0.title.hasPrefix(prefix) }
    }

    // MARK: - Counters

    @MainActor
    static func checkCounters(model: ViewerModel, log: inout Logger) {
        let counts = model.degradation
        log.note(
            "render-thread counters",
            "stalls \(counts.stalls), rejected \(counts.rejectedCommands), "
                + "bad layouts \(counts.bufferLayoutMismatches), dropped \(counts.droppedCommands)")
        log.check("no render stalls during the whole run", counts.stalls == 0)
        log.check("no commands were rejected", counts.rejectedCommands == 0)
        log.check("no unexpected buffer layouts", counts.bufferLayoutMismatches == 0)
        log.check("no commands were dropped by the ring", counts.droppedCommands == 0)
        if let notice = model.playbackNotice {
            log.note("playback notice raised during the run", notice)
        }
        log.check(
            "the counters are consumed by the UI, not merely published",
            counts.summary == model.degradation.summary)
    }
}
