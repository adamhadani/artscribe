import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// Task 15's three questions, asked of the running app.
///
/// 1. Does every menu item present its shortcut the system's way?
/// 2. Does a **plain-letter** menu key equivalent flash the menu bar — the claim
///    `PlaybackCommands` used to record as the reason plain keys were kept off
///    the menu — and does anything fire twice now that they are on it?
/// 3. Does a plain-letter key equivalent fire while a text field has focus?
///
/// Every one is measured rather than reasoned about, and the strobe question is
/// measured **against a control**: `⇧W` and `⌘0` have been real menu key
/// equivalents since Task 11, so if a plain `W` behaves as they do then whatever
/// the menu bar does on a keystroke is not something plain letters introduced.
extension AcceptanceRun {

    // MARK: - Presentation

    /// The convention: right-aligned and system-drawn, never spelled into a
    /// title. `"  ("` — two spaces then a parenthesis — was the shape every
    /// spelled shortcut used, and now nothing uses it, which makes "no title
    /// contains `  (`" a one-line check with no exceptions to remember.
    @MainActor
    static func checkShortcutPresentation(log: inout Logger) async {
        // Every menu the app puts items into, including the two Task 18 added.
        for name in ["Edit", "View", "Playback", "Loop"] {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == name })?.submenu
            else {
                log.check("a \(name) menu exists", false)
                continue
            }
            await refreshMenu(menu)
            let spelled = menu.items.map(\.title).filter { $0.contains("  (") }
            log.check(
                "no \(name) item spells its shortcut into the title "
                    + "(\(spelled.isEmpty ? "none" : spelled.joined(separator: ", ")))",
                spelled.isEmpty)
            let described = menu.items
                .filter { !$0.isSeparatorItem && $0.submenu == nil && !$0.title.isEmpty }
                .map { "\($0.title)=\(describe($0))" }
            log.note("\(name) key equivalents", described.joined(separator: " | "))
        }
    }

    /// The keys that have no printable form, written as a menu writes them.
    private static let keyNames: [String: String] = [
        " ": "Space", "\r": "↩", "\u{1B}": "⎋", "\u{F700}": "↑", "\u{F701}": "↓",
        "\u{F702}": "←", "\u{F703}": "→"
    ]

    /// One item's key equivalent as a user would read it off the menu.
    @MainActor
    private static func describe(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "—" }
        var text = ""
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + (keyNames[key] ?? key.uppercased())
    }

    // MARK: - The strobe claim

    /// Counts what AppKit does to the menus while a key equivalent is performed.
    ///
    /// Three observable signals, all public API:
    /// * `NSMenu.didBeginTrackingNotification` — a menu opening. A menu-bar
    ///   flash is a menu title being highlighted, which is menu tracking.
    /// * `NSMenu.highlightedItem` on the main menu and on the submenu, sampled
    ///   immediately after the chord is performed.
    /// * whether the chord was claimed at all, which is the precondition for any
    ///   of it.
    @MainActor
    static func checkMenuBarStrobe(model: ViewerModel, log: inout Logger) async {
        let counter = TrackingCounter()
        var observers: [any NSObjectProtocol] = []
        let count = { @Sendable (_: Notification) in
            MainActor.assumeIsolated { counter.count += 1 }
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main, using: count))
        }
        defer { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

        let playback = NSApp.mainMenu?.items.first { $0.title == "Playback" }?.submenu

        /// One chord, twenty times, as a held key repeat would deliver it.
        func sweep(_ key: Key) -> Sweep {
            counter.count = 0
            var result = Sweep()
            for _ in 0..<20 {
                if offerToMenuBar(key) { result.claimed += 1 }
                if NSApp.mainMenu?.highlightedItem != nil { result.highlighted += 1 }
                if playback?.highlightedItem != nil { result.highlighted += 1 }
            }
            result.tracking = counter.count
            return result
        }

        model.setSpeedPreset(1.0)
        let plain = sweep(.w)
        model.setSpeedPreset(1.0)
        let shifted = sweep(lowercased(.shiftW))
        model.setSpeedPreset(1.0)
        let commanded = sweep(.zero)
        model.setSpeedPreset(1.0)

        log.note("20× plain W", plain.description)
        log.note("20× ⇧W (a menu key equivalent since Task 11)", shifted.description)
        log.note("20× ⌘0 (an ordinary ⌘ item)", commanded.description)
        // Stated so that it FAILS if the strobe claim is true.
        log.check(
            "a held plain-letter sweep opens no menu and highlights nothing (\(plain))",
            plain.tracking == 0 && plain.highlighted == 0)
        // And the control: whatever the menu bar does on a plain letter, it does
        // on a chord the app has shipped as a key equivalent for four tasks. If
        // these differ, plain letters really are special and the old comment was
        // right; if they agree, the distinction the old split rested on is not
        // there to be measured.
        log.check(
            "a plain letter is treated no differently from ⇧W (\(plain) vs \(shifted))",
            plain.tracking == shifted.tracking && plain.highlighted == shifted.highlighted)
        log.check("the plain letter was claimed by the menu at all", plain.claimed == 20)
    }

    /// What one 20-press sweep did to the menus.
    struct Sweep: CustomStringConvertible {
        var claimed = 0
        var tracking = 0
        var highlighted = 0

        var description: String {
            "claimed \(claimed)/20, menu-tracking events \(tracking), "
                + "highlighted samples \(highlighted)/40"
        }
    }

    /// A box for the notification count. The observer block is `@Sendable`, so a
    /// captured local `var` will not do.
    @MainActor
    final class TrackingCounter {
        var count = 0
    }

    /// Exactly one step per keypress, for every plain letter now on the menu.
    ///
    /// The hazard the old split was also protecting against: the menu claims a
    /// chord *and* `DocumentView` handles it, so one press moves two steps. Each
    /// key is driven through `press(…)`, which is `NSApp.sendEvent` — the same
    /// route a real keystroke takes, menu bar first.
    @MainActor
    static func checkSingleFire(model: ViewerModel, log: inout Logger) {
        model.setSpeedPreset(1.0)
        press(.w)
        log.check("W steps the speed once (\(model.speed.ratio))", model.speed.ratio == 1.05)
        press(.q)
        log.check("Q steps the speed once (\(model.speed.ratio))", model.speed.ratio == 1.0)
        press(.q)
        press(.q)
        log.check("two Q presses step twice, not four times", model.speed.ratio == 0.90)
        model.setSpeedPreset(1.0)

        model.seek(to: model.totalFrames / 2)
        let middle = model.playhead
        let step = FrameIndex((model.nudgeAmounts[.normal] * model.sampleRate).rounded())
        press(.x)
        log.check(
            "X nudges once (\(model.playhead - middle) frames, one step is \(step))",
            model.playhead - middle == step)
        press(.z)
        log.check("Z nudges back once", model.playhead == middle)

        let engine = model.speed.engine
        press(.optionE)
        log.check("⌥E still toggles once with the plain keys live", model.speed.engine != engine)
        press(.optionE)
        log.check("⌥E toggles back once", model.speed.engine == engine)

        model.clearLoop()
        press(.a)
        press(.s)
        log.note("loop after A then S", "\(model.loop.range)")
        press(.d)
        let enabled = model.loop.isEnabled
        press(.d)
        log.check("D toggles the loop once per press", model.loop.isEnabled != enabled)
        model.clearLoop()
        model.seek(to: 0)
    }

    // MARK: - The mechanism behind the guard

    /// A **disabled** menu item does not claim its key equivalent.
    ///
    /// This is the whole mechanism `KeyWindowTracker` rests on: with another
    /// window key, the transport menus disable themselves and the transport does
    /// not fire.
    ///
    /// Measured on `Loop` / `D`, and that choice is load-bearing. Most items are
    /// disabled precisely when their model action is *also* a guarded no-op, so
    /// "nothing happened" would prove nothing about the menu. `toggleLoop()`
    /// guards only on `hasTrack`: with a track loaded and no loop region the
    /// item is disabled, yet the action, if it ran, would visibly switch looping
    /// on. Silence there is therefore evidence about the menu and not about the
    /// model.
    @MainActor
    static func checkDisabledItemsClaimNothing(model: ViewerModel, log: inout Logger) async {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Playback" })?.submenu
        else {
            log.check("a Playback menu exists to measure enablement on", false)
            return
        }
        // The control first: `performKeyEquivalent` is only evidence of a claim
        // if it can also say no. `J` is bound to nothing in this app.
        let claimedUnbound = offerToMenuBar(.unbound)
        log.note("the menu bar's answer for an unbound key (J)", "\(claimedUnbound)")
        log.check("performKeyEquivalent can say no at all", !claimedUnbound)

        // `Faster` / `W`: a plain `Button`, and `faster(fine:)` guards only on
        // `hasTrack`, so if a disabled item still ran its action the speed would
        // visibly move. Most items are disabled exactly when their model action
        // is already a guarded no-op, which would make "nothing happened" prove
        // nothing about the menu.
        func offerFaster() async -> (claimed: Bool, moved: Bool) {
            model.setSpeedPreset(1.0)
            await refreshMenu(menu)
            let claimed = offerToMenuBar(.w)
            await settle(seconds: 0.5)
            return (claimed, model.speed.ratio != 1.0)
        }

        KeyWindowTracker.shared.forcedDocumentIsKey = true
        let live = await offerFaster()
        let liveEnabled = menu.items.first { $0.title == "Faster" }?.isEnabled == true

        // The state the guard exists for: some other window — Settings, with its
        // editable amounts — is the one taking keystrokes.
        KeyWindowTracker.shared.forcedDocumentIsKey = false
        let guarded = await offerFaster()
        let guardedEnabled = menu.items.first { $0.title == "Faster" }?.isEnabled == true

        KeyWindowTracker.shared.forcedDocumentIsKey = nil
        model.setSpeedPreset(1.0)
        await refreshMenu(menu)

        log.note(
            "Faster vs W",
            "document key: enabled=\(liveEnabled) claimed=\(live.claimed) moved=\(live.moved); "
                + "another window key: enabled=\(guardedEnabled) claimed=\(guarded.claimed) "
                + "moved=\(guarded.moved)")
        log.check("the transport items are live while the document holds the keyboard", liveEnabled)
        log.check("and the menu's own shortcut fires them", live.moved)
        log.check(
            "they go dead the moment another window holds it — the remedy for a plain-letter "
                + "equivalent over a text field",
            !guardedEnabled)
        log.check("and the keystroke no longer moves the transport", !guarded.moved)
        model.clearLoop()
        model.clearSelection()
    }

    // MARK: - Typing

    /// A plain-letter key equivalent is offered to the menu **before** the key
    /// window's first responder, so this is the hazard that decides whether the
    /// convention is safe at all.
    ///
    /// The field is put **inside the viewer window** rather than in a second one
    /// of its own. That is not a shortcut, it is the only way to measure
    /// anything here: a new window would have to become key to hold focus, and
    /// on a machine whose login session is screen-locked no window can. Made
    /// first responder of a window that already receives the harness's
    /// synthesised events, an `NSTextField` behaves as Settings' nudge fields do
    /// — the field editor is in the responder chain, and the main menu is still
    /// offered the event first.
    ///
    /// What that arrangement can and cannot show:
    /// * it **can** show whether a live plain-letter key equivalent beats the
    ///   field to the keystroke — the hazard itself;
    /// * it **cannot** show `KeyWindowTracker` doing its job, because the tracker
    ///   keys off *which window* is key and here there is only one. The item's
    ///   enablement is measured instead, in `checkDisabledItemsClaimNothing`.
    @MainActor
    static func checkTypingInAField(model: ViewerModel, log: inout Logger) async {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
            let content = window.contentView
        else {
            log.check("the viewer window exists to host a text field", false)
            return
        }
        let previous = window.firstResponder
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 160, height: 22))
        content.addSubview(field)
        await settle(seconds: 0.3)
        let focused = window.makeFirstResponder(field)
        await settle(seconds: 0.3)
        log.check("a text field can take the responder chain", focused)

        func type(_ key: Key) async -> (speed: Double, text: String) {
            model.setSpeedPreset(1.0)
            field.stringValue = ""
            await settle(seconds: 0.2)
            press(key)
            await settle(seconds: 0.3)
            return (model.speed.ratio, field.currentEditor()?.string ?? field.stringValue)
        }

        let typed = await type(.q)
        // A live field editor is what makes this a real test rather than a
        // responder-chain formality: `currentEditor()` is non-nil only while the
        // field is actually being edited, which is the state Settings' nudge
        // fields are in when you are typing an amount into one.
        let editing = field.currentEditor() != nil
        log.note(
            "Q sent with a text field being edited",
            "field editor: \(editing), speed \(typed.speed), field \"\(typed.text)\"")
        log.check(
            "typing in a text field does not step the speed (\(typed.speed))", typed.speed == 1.0,
            unless: editing
                ? nil
                : "the field never entered editing, so this would measure a responder chain "
                    + "rather than a focused field")
        log.check("and the keystroke reached the field instead", typed.text.contains("q"))

        model.setSpeedPreset(1.0)
        // Put the window back exactly as it was found. A field left in the
        // responder chain swallows every later keystroke in the run — measured,
        // as four unrelated transport checks failing the first time this ran.
        // It is also why this check is the last thing the run does.
        field.removeFromSuperview()
        window.makeFirstResponder(previous)
        await settle(seconds: 0.3)
        log.check(
            "the responder chain is left as it was found", window.firstResponder === previous)
    }
}
