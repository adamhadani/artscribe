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
            "Play", "Stop", "Play from Start", "Faster", "Slower", "Output Device",
            "Volume Up", "Volume Down", "Volume Up (Fine)", "Volume Down (Fine)", "Mute",
            // Spec §6.2's three navigation tiers, six items.
            "Nudge Back", "Nudge Forward", "Nudge Back (Fine)", "Nudge Forward (Fine)",
            "Rewind", "Skip"
        ] {
            log.check(
                "the menu carries \(expected)",
                titles.contains { $0.hasPrefix(expected) || $0.contains(expected) })
        }

        // Task 18 split the menu. Anything that answers to Loop or to the
        // selection has to have *left* — an action in two menus is one that can
        // fire twice, or that greys out in one place and not the other.
        for moved in ["Set Loop In", "Set Loop Out", "Restart Loop", "Selection", "Select All"] {
            log.check(
                "\(moved) is no longer in the Playback menu",
                !titles.contains { $0.hasPrefix(moved) })
        }

        // The preset checkmarks are the live-`@Observable`-inside-a-menu case.
        model.setSpeedPreset(0.5)
        await refresh(menu)
        log.check("the active speed preset is checked", item(menu, "50%")?.state == .on)
        log.check("the inactive presets are not", item(menu, "100%")?.state == .off)
        model.setSpeedPreset(1.0)
        await refresh(menu)
        log.check("the checkmark follows the speed", item(menu, "100%")?.state == .on)

        await checkVolumeItems(menu, model: model, log: &log)

        // Stopped, explicitly, because that is the state this check claims to
        // measure. It used to inherit whatever the transport happened to be
        // doing after forty synthesised keystrokes, and on a machine where some
        // of those do not land the item is titled "Pause" and the lookup below
        // silently finds nothing. Measured: adding four `log.note` calls to
        // `checkAutoScroll` was enough to flip an unmodified build into that
        // state, so the dependency was on timing and not on anything the menu
        // does. `pause()` is a guarded no-op when nothing is playing.
        model.pause()
        await refresh(menu)
        let playItem = menu.items.first { $0.title.hasPrefix("Play") && !$0.title.contains("from") }
        log.check("the play item is enabled with a track loaded", playItem?.isEnabled == true)
        // The transport's own answer beside the menu's. Without it a "missing"
        // here is unreadable: the item is titled "Pause" while playing, so it
        // cannot be told apart from a menu that failed to rebuild.
        log.note(
            "play item title",
            "\(playItem?.title ?? "missing") (model.isPlaying = \(model.isPlaying))")

        // The title has to follow the transport, or the menu lies about what
        // pressing it will do.
        press(.shiftSpace)
        await refresh(menu)
        let whilePlaying = menu.items.first {
            $0.title.hasPrefix("Play") || $0.title.hasPrefix("Pause")
        }
        log.check(
            "the play item becomes Pause while playing (\(whilePlaying?.title ?? "missing"))",
            whilePlaying?.title.hasPrefix("Pause") == true)
        log.check("Stop is enabled while playing", item(menu, "Stop")?.isEnabled == true)
        press(.shiftSpace)
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

    /// The **Loop** menu (Task 18): the signature feature, out of the bottom of
    /// a 36-item Playback menu and into a top-level menu of its own.
    ///
    /// Its enablement is read back out of AppKit for the same reason the
    /// Playback menu's is — trap 3, the `.disabled(…)` in a `Commands` body
    /// that silently broke ⌘9 — and because moving the items into a new
    /// `CommandMenu` is exactly the change that could have dropped it.
    @MainActor
    static func checkLoopMenu(model: ViewerModel, log: inout Logger) async {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Loop" })?.submenu
        else {
            log.check("a Loop menu exists in the menu bar", false)
            return
        }
        log.check("a Loop menu exists in the menu bar", true)
        await refresh(menu)
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        log.note("Loop menu", titles.joined(separator: " | "))
        for expected in [
            "Set Loop In", "Set Loop Out", "Loop", "Restart Loop", "Selection", "Clear Loop"
        ] {
            log.check(
                "the Loop menu carries \(expected)", titles.contains { $0.hasPrefix(expected) })
        }

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
        await checkLoopMoveMenuItems(menu, log: &log)
    }

    /// Task 24 B: the twelve `loop.move` items, each carrying a real key
    /// equivalent so AppKit draws the shortcut right-aligned beside it.
    ///
    /// The *firing* of these chords is `checkLoopMovement`'s job, through real
    /// `NSEvent`s. What is measured here is the other half of the requirement:
    /// that the menu is where a user can find out the chord exists. It has to be
    /// asserted rather than assumed, because a `keyboardShortcut` that failed to
    /// reach `NSMenuItem` would leave an item that looks like a plain command.
    @MainActor
    private static func checkLoopMoveMenuItems(_ menu: NSMenu, log: inout Logger) async {
        await refresh(menu)
        struct Expected {
            let title: String
            let key: String
            let modifiers: NSEvent.ModifierFlags
            init(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
                self.title = title
                self.key = key
                self.modifiers = modifiers
            }
        }
        let expected: [Expected] = [
            Expected("Move Loop In Left", "a", .shift),
            Expected("Move Loop In Right", "s", .shift),
            Expected("Move Loop In Left (Far)", "a", [.shift, .option]),
            Expected("Move Loop In Right (Far)", "s", [.shift, .option]),
            Expected("Move Loop Out Left", "d", .shift),
            Expected("Move Loop Out Right", "f", .shift),
            Expected("Move Loop Out Left (Far)", "d", [.shift, .option]),
            Expected("Move Loop Out Right (Far)", "f", [.shift, .option]),
            Expected("Move Loop Left", "c", .shift),
            Expected("Move Loop Right", "v", .shift),
            Expected("Move Loop Left (Far)", "c", [.shift, .option]),
            Expected("Move Loop Right (Far)", "v", [.shift, .option])
        ]
        for want in expected {
            // Exact-prefix match: "Move Loop In Left" must not be satisfied by
            // "Move Loop In Left (Far)", which would let a missing item hide.
            let found = menu.items.first {
                $0.title == want.title || $0.title.hasPrefix(want.title + " ")
            }
            guard let found else {
                log.check("the Loop menu carries \(want.title)", false)
                continue
            }
            log.check(
                "the Loop menu carries \(want.title) with its shortcut "
                    + "(\(found.keyEquivalent), \(found.keyEquivalentModifierMask.rawValue))",
                found.keyEquivalent.lowercased() == want.key
                    && found.keyEquivalentModifierMask == want.modifiers)
        }
    }

    /// The **Edit** menu (Task 18): the selection actions, where macOS
    /// convention puts them.
    ///
    /// The two things measured here could not be reasoned about, and one of
    /// them was wrong on the first attempt: SwiftUI builds an Edit menu of its
    /// own, and appending to its pasteboard group left *two* `Select All`
    /// items with the system's — disabled — holding ⌘A.
    @MainActor
    static func checkEditMenu(model: ViewerModel, log: inout Logger) async {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu
        else {
            log.check("an Edit menu exists in the menu bar", false)
            return
        }
        await refresh(menu)
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        log.note("Edit menu", titles.joined(separator: " | "))
        for expected in [
            "Select All", "Clear Selection", "Extend Selection Left", "Extend Selection Right",
            "Move Selection Left", "Move Selection Right"
        ] {
            log.check(
                "the Edit menu carries \(expected)", titles.contains { $0.hasPrefix(expected) })
        }
        log.check(
            "there is exactly one Select All (\(titles.filter { $0 == "Select All" }.count))",
            titles.filter { $0 == "Select All" }.count == 1)
        let selectAll = item(menu, "Select All")
        log.check(
            "and it is ours, carrying ⌘A (\(selectAll?.keyEquivalent ?? "none"))",
            selectAll?.keyEquivalent == "a"
                && selectAll?.keyEquivalentModifierMask == .command)
        // Cut/Copy/Paste were re-declared when the standard group was replaced,
        // because a text field's field editor gets those chords from the menu
        // and Settings has five of them.
        for expected in ["Cut", "Copy", "Paste"] {
            log.check(
                "the Edit menu still carries \(expected)",
                titles.contains { $0.hasPrefix(expected) })
        }
        await checkSelectionItemsStandDown(menu, log: &log)

        // The move amounts are in the titles, like the nudge amounts.
        let gentle = NudgeAmounts.label(seconds: model.selectionMoveAmounts[.gentle])
        log.check(
            "the move items name their amount (\(gentle))",
            titles.contains { $0.hasPrefix("Move Selection Left") && $0.hasSuffix(gentle) })
    }

    /// `C`, `V` and `Esc` are **plain** key equivalents, offered to the menu
    /// before the key window's first responder — so with Settings open, typing
    /// `c` into an amount field would move the selection instead of typing.
    ///
    /// The remedy is the same one the Playback menu uses: a disabled item
    /// claims nothing. This measures that the whole selection block really does
    /// go dead when the document is not the key window, and comes back.
    @MainActor
    private static func checkSelectionItemsStandDown(
        _ menu: NSMenu, log: inout Logger
    ) async {
        let watched = ["Move Selection Left", "Clear Selection", "Extend Selection Left"]
        KeyWindowTracker.shared.forcedDocumentIsKey = false
        await refresh(menu)
        let dead = watched.allSatisfy { item(menu, $0)?.isEnabled == false }
        KeyWindowTracker.shared.forcedDocumentIsKey = nil
        await refresh(menu)
        let alive = watched.allSatisfy { item(menu, $0)?.isEnabled == true }
        log.check(
            "the selection items go dead while another window holds the keyboard "
                + "— C, V and Esc are plain keys over Settings' fields", dead)
        log.check("and come back when the document holds it again", alive)
    }

    /// Mute reflects state, and the volume items grey out with no track.
    @MainActor
    private static func checkVolumeItems(
        _ menu: NSMenu, model: ViewerModel, log: inout Logger
    ) async {
        model.toggleMute()
        await refresh(menu)
        log.check("Mute is checked while muted", item(menu, "Mute")?.state == .on)
        model.toggleMute()
        await refresh(menu)
        log.check("Mute unchecks when unmuted", item(menu, "Mute")?.state == .off)
        log.check(
            "Volume Up is enabled with a track loaded",
            item(menu, "Volume Up")?.isEnabled == true)
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
