import AppKit
import ArtscribeUI
import Foundation

/// **The shortcut window's focus model, driven with a real pointer.**
///
/// Everything here is measured against `NSWindow.firstResponder` and not against
/// SwiftUI's `@FocusState`, because the first responder is what
/// `ModifierMonitor` reads to decide whether a held ⇧ is a layer request or a
/// capital letter — and it is the only one of the two observable from outside
/// the view that declares it.
///
/// The window opened unfocused before this task and stayed that way *only until
/// the first click*, at which point there was no way back out: three separate
/// measurements — click on the drawn keyboard, `⎋`, and `⎋` again — all left
/// `_SystemTextFieldFieldEditor` holding the keyboard. That is the regression
/// these checks exist to stop happening a third time.
///
/// **Two facts about the machine gate the whole thing**, and both are read
/// rather than inferred from a failure:
///
/// - The window has to be **key**, or `NSWindow.sendEvent` drops every click.
/// - The click has to reach `NSTextView.mouseDown:`, which runs its own modal
///   tracking loop; the release is therefore *queued before* the press, or the
///   run wedges. That is measured, not defensive — an earlier version of this
///   file hung the harness for fifteen minutes inside
///   `_bellerophonTrackMouseWithMouseDownEvent:`.
extension AcceptanceRun {

    @MainActor
    static func checkShortcutFocus(
        model: ViewerModel, shortcuts: ShortcutWindowController, document: NSWindow?,
        log: inout Logger
    ) async {
        shortcuts.show()
        await settle(seconds: 1.0)
        guard let window = shortcuts.window else {
            log.check("the shortcut window exists to measure focus in", false)
            return
        }
        let key = await claimTheKeyboard(for: window)
        log.note(
            "shortcut window",
            "key \(window.isKeyWindow), app active \(NSApp.isActive), frontmost "
                + "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
        let opening =
            key
            ? nil
            : "no window in this process can become key — an application launched from a "
                + "background shell cannot activate, so NSApp.sendEvent drops every "
                + "synthesised click and nothing here would be measuring focus"
        // Re-read before **every** check rather than once: a run takes half a
        // minute on a machine somebody else is using, and one click of theirs
        // takes the keyboard away mid-sequence. Every check after that would
        // fail, and a failure that means "somebody moved" is worse than useless.
        func undeliverable() -> String? { opening ?? lostTheKeyboard(window) }

        // 1. Opened — including *re*-opened, which is the case the one-shot
        //    release in `ShortcutWindow.configure` never covered: SwiftUI hands
        //    the `TextField` first responder on every open of the scene, and
        //    this window was reopened three times before this line.
        log.note("responder on open", describeResponder(window))
        log.check(
            "the filter does not hold the keyboard when the window opens "
                + "(\(describeResponder(window)))",
            TextFocusProbe.editor(in: window) == nil, unless: undeliverable())

        guard let field = textInput(in: window.contentView) else {
            log.check("a text input was found in the shortcut window", false)
            return
        }
        let rect = inWindow(field)
        let content = window.contentView?.bounds ?? .zero
        let inertPoint = CGPoint(x: content.width * 0.25, y: content.height * 0.62)
        let fieldPoint = CGPoint(x: rect.midX, y: rect.midY)

        // 2. A click puts the caret in it.
        clickShortcut(window, at: fieldPoint)
        await settle(seconds: 0.4)
        log.note("responder after clicking the filter", describeResponder(window))
        let focused = TextFocusProbe.editor(in: window) != nil
        log.check("a click in the filter gives it the keyboard", focused, unless: undeliverable())

        // 3. …and a click anywhere else takes it back. The whole complaint.
        clickShortcut(window, at: inertPoint)
        await settle(seconds: 0.4)
        log.note("responder after clicking the keyboard pane", describeResponder(window))
        log.check(
            "a click outside the filter gives the keyboard back to the window "
                + "(\(describeResponder(window)))",
            TextFocusProbe.editor(in: window) == nil,
            unless: undeliverable() ?? (focused ? nil : "the filter never took the keyboard"))

        await checkEscape(
            window, shortcuts: shortcuts, at: fieldPoint, log: &log, undeliverable: undeliverable)
        await checkPasteboard(
            FilterTarget(model: model, window: window, fieldPoint: fieldPoint),
            shortcuts: shortcuts, log: &log, undeliverable: undeliverable)

        // 8. The other window's turn. The user believed this already worked;
        //    it does, and the reason is worth recording — the shortcut window
        //    keeps its field editor as *its* first responder, but `isTyping`
        //    reads the **key** window, which is now the document's.
        document?.makeKeyAndOrderFront(nil)
        await settle(seconds: 0.8)
        log.note(
            "after the document window is raised",
            "key window \(NSApp.keyWindow.map { $0.title } ?? "none"), shortcut responder "
                + "\(describeResponder(window)), document responder "
                + "\(document.map(describeResponder) ?? "none")")
        // The guard flips here: the *document* is meant to be key now, so
        // `undeliverable()` — which asks whether the shortcut window still is —
        // would skip exactly the state being measured.
        let noKeyWindow =
            opening ?? (NSApp.keyWindow == nil ? "no window in this process is key at all" : nil)
        log.check(
            "clicking the document window sends keys back to it",
            document.map { NSApp.keyWindow === $0 } == true,
            unless: noKeyWindow)
        log.check(
            "and a held modifier is a layer again, not typing",
            !TextFocusProbe.isEditingText, unless: noKeyWindow)

        shortcuts.query = ""
        window.performClose(nil)
        await settle(seconds: 0.5)
    }

    /// `⎋` clears the filter, then releases it. Both steps, in that order.
    @MainActor
    private static func checkEscape(
        _ window: NSWindow, shortcuts: ShortcutWindowController, at fieldPoint: CGPoint,
        log: inout Logger, undeliverable: () -> String?
    ) async {
        clickShortcut(window, at: fieldPoint)
        await settle(seconds: 0.3)
        shortcuts.query = "loop"
        await settle(seconds: 0.3)
        let focusedWithText = TextFocusProbe.editor(in: window) != nil
        press(.escape)
        await settle(seconds: 0.4)
        log.note(
            "first ⎋", "query \"\(shortcuts.query)\", responder \(describeResponder(window))")
        log.check(
            "⎋ over a filter with text in it clears the filter (\"\(shortcuts.query)\")",
            shortcuts.query.isEmpty,
            unless: undeliverable()
                ?? (focusedWithText ? nil : "the filter never took the keyboard"))
        log.check(
            "and keeps the caret in it, so a second ⎋ is what leaves",
            TextFocusProbe.editor(in: window) != nil,
            unless: undeliverable()
                ?? (focusedWithText ? nil : "the filter never took the keyboard"))

        press(.escape)
        await settle(seconds: 0.4)
        log.note("second ⎋", "responder \(describeResponder(window))")
        log.check(
            "⎋ over an empty filter gives the keyboard back to the window "
                + "(\(describeResponder(window)))",
            TextFocusProbe.editor(in: window) == nil, unless: undeliverable())
    }

    /// `⌘V`, `⌘A` and `⌘C`, over the field, through the menu bar.
    ///
    /// Driven as real keystrokes rather than as `NSApp.sendAction`, because the
    /// difference is the entire finding: `sendAction(copy:)` reached the field
    /// editor and copied correctly all along, while the `⌘A` a reader presses
    /// first was claimed by this app's own `Select All` and selected the whole
    /// *track* — leaving nothing selected in the field for the `⌘C` to take.
    @MainActor
    private static func checkPasteboard(
        _ target: FilterTarget, shortcuts: ShortcutWindowController, log: inout Logger,
        undeliverable: () -> String?
    ) async {
        let (model, window, fieldPoint) = (target.model, target.window, target.fieldPoint)
        clickShortcut(window, at: fieldPoint)
        await settle(seconds: 0.4)
        let focused = TextFocusProbe.editor(in: window) != nil
        let unfocused =
            undeliverable() ?? (focused ? nil : "the filter never took the keyboard to type into")

        shortcuts.query = ""
        model.clearSelection()
        await settle(seconds: 0.3)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("nudge", forType: .string)
        press(Key(9, "v", modifiers: .command))
        await settle(seconds: 0.5)
        log.check(
            "⌘V pastes into the filter (\"\(shortcuts.query)\")", shortcuts.query == "nudge",
            unless: unfocused)

        press(Key(0, "a", modifiers: .command))
        await settle(seconds: 0.4)
        let selection = TextFocusProbe.editor(in: window)?.selectedRange()
        log.note(
            "after ⌘A",
            "field selection \(selection.map { "\($0)" } ?? "none"), audio selection "
                + "\(model.selection)")
        log.check(
            "⌘A over the filter selects its text, not the whole track",
            selection?.length == shortcuts.query.utf16.count && selection?.length ?? 0 > 0,
            unless: unfocused)
        log.check(
            "and leaves the audio selection alone", model.selection.isEmpty, unless: unfocused)

        NSPasteboard.general.clearContents()
        press(Key(8, "c", modifiers: .command))
        await settle(seconds: 0.5)
        let copied = NSPasteboard.general.string(forType: .string)
        log.check(
            "⌘C then copies what is in the filter (\"\(copied ?? "nil")\")", copied == "nudge",
            unless: unfocused)

        // And typing still works, which is the thing all of the above could
        // break by taking the keyboard away too eagerly.
        shortcuts.query = ""
        await settle(seconds: 0.3)
        press(Key(6, "z"))
        await settle(seconds: 0.4)
        log.check(
            "typing still reaches the focused filter (\"\(shortcuts.query)\")",
            shortcuts.query == "z", unless: unfocused)
        shortcuts.query = ""
    }

    // MARK: - Primitives

    /// Gets this window to key, and says whether it managed it.
    ///
    /// `activate(ignoringOtherApps:)` is deliberate and is the only place in the
    /// harness that uses it: macOS's cooperative activation refuses a plain
    /// `NSApp.activate()` from a process launched by a background shell — the
    /// screen is *not* locked here and `NSApp.keyWindow` was still `nil` through
    /// forty polite attempts — and without a key window there is no focus to
    /// measure at all.
    @MainActor
    private static func claimTheKeyboard(for window: NSWindow) async -> Bool {
        for attempt in 0..<20 {
            if NSApp.keyWindow === window { return true }
            if attempt.isMultiple(of: 2) {
                NSApp.activate(ignoringOtherApps: true)
            } else {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            }
            window.makeKeyAndOrderFront(nil)
            await settle(seconds: 0.15)
        }
        return NSApp.keyWindow === window
    }

    /// Why a check cannot be believed right now, or `nil` if it can.
    @MainActor
    private static func lostTheKeyboard(_ window: NSWindow) -> String? {
        NSApp.keyWindow === window
            ? nil
            : "the shortcut window is no longer key (\(NSApp.keyWindow?.title ?? "nothing") is) "
                + "— somebody is using this machine, and a click sent to a window that is not "
                + "key is dropped"
    }

    @MainActor
    static func describeResponder(_ window: NSWindow) -> String {
        guard let responder = window.firstResponder else { return "nil" }
        return "\(type(of: responder))\(responder is NSTextView ? " (NSTextView)" : "")"
    }

    /// A click delivered straight into `window` without moving the cursor.
    /// `AcceptanceRun.sendMouse` aims at the viewer window only.
    @MainActor
    static func clickShortcut(_ window: NSWindow, at point: CGPoint) {
        guard let view = window.contentView else { return }
        let location = NSPoint(x: point.x, y: view.bounds.height - point.y)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            shortcutEventNumber += 1
            return NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: shortcutEventNumber, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // The release is **queued first**. `NSTextView.mouseDown:` runs its own
        // modal tracking loop and blocks in `nextEventMatchingMask:` until the
        // release arrives, so a `sendEvent(up)` written after `sendEvent(down)`
        // never executes and the whole run wedges — measured, by sampling a
        // hung harness inside `_bellerophonTrackMouseWithMouseDownEvent:`.
        NSApp.postEvent(up, atStart: false)
        // `NSApp.sendEvent`, **not** `window.sendEvent`: local event monitors
        // run inside the former and are skipped entirely by the latter, and the
        // focus rule under test is a local monitor. Driven the short way, this
        // check measured the window and not the app — the click never reached
        // `ShortcutFocusMonitor` at all.
        NSApp.sendEvent(down)
    }

    @MainActor private static var shortcutEventNumber = 4000

    /// The view that actually edits text. SwiftUI's `TextField` is backed by a
    /// private class on macOS, so this matches on kind — it is an `NSTextField`
    /// subclass, measured — rather than on a name.
    @MainActor
    static func textInput(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSTextView || view is NSTextField { return view }
        for subview in view.subviews {
            if let found = textInput(in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func inWindow(_ view: NSView) -> CGRect {
        guard let content = view.superview?.convert(view.frame, to: nil),
            let height = view.window?.contentView?.bounds.height
        else { return view.frame }
        return CGRect(
            x: content.minX, y: height - content.maxY, width: content.width, height: content.height)
    }
}

/// The three things every pasteboard check needs, as one value: SwiftLint caps
/// a parameter list at five and the alternative was to drop one of them.
@MainActor
struct FilterTarget {
    let model: ViewerModel
    let window: NSWindow
    /// The middle of the filter field, in window content coordinates.
    let fieldPoint: CGPoint
}

/// The harness's own copy of the rule the app applies, so a check reads the
/// first responder for itself rather than asking the code under test.
@MainActor
enum TextFocusProbe {
    static func editor(in window: NSWindow?) -> NSTextView? {
        window?.firstResponder as? NSTextView
    }

    static var isEditingText: Bool { editor(in: NSApp.keyWindow) != nil }
}
