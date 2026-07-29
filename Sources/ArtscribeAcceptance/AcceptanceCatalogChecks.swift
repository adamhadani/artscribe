import AppKit
import ArtscribeUI
import Foundation

/// The end-to-end half of the drift guard, and Task 25's shortcut window.
///
/// `ActionCatalogTests` proves the catalog, the menu plan and the key bindings
/// agree with each other. What it cannot prove is that any of it reached
/// **AppKit** — that the titles SwiftUI built are the titles the catalog says,
/// and that the key equivalents survived the trip into `NSMenuItem`. That needs
/// a running menu bar, which is what this is.
///
/// It also measures the two things about the shortcut window a unit test
/// cannot: that `⌘/` puts a real, visible, resizable `NSWindow` on screen, and
/// that it is a *separate* one — closing it leaves the document window alone,
/// and opening it costs the waveform no width. The second half is the whole
/// reason Task 25 exists, and it was measured the other way round in Task 20:
/// the inspector's check asserted the waveform got *narrower*.
extension AcceptanceRun {

    @MainActor
    static func checkCatalogAndShortcutWindow(
        model: ViewerModel, theme: ThemeController, context: MenuContext, log: inout Logger,
        outputDirectory: String
    ) async {
        await checkMenusMirrorTheCatalog(context: context, log: &log)
        await checkShortcutWindow(
            model: model, theme: theme, shortcuts: context.shortcuts, log: &log,
            outputDirectory: outputDirectory)
    }

    /// Every item in every menu, against the catalog — in both directions.
    @MainActor
    private static func checkMenusMirrorTheCatalog(context: MenuContext, log: inout Logger) async {
        for section in MenuSection.allCases {
            guard let menu = topLevelMenu(named: section.menuTitle) else {
                log.check("a \(section.menuTitle) menu exists in the menu bar", false)
                continue
            }
            await refreshMenu(menu)
            let placed = MenuPlan.placements.filter { $0.section == section }.map(\.id)
            for id in placed {
                let expected = ActionTitle.display(id, context)
                guard let item = menu.items.first(where: { $0.title == expected }) else {
                    log.check("\(section.menuTitle) ▸ \(expected) is in the menu bar", false)
                    continue
                }
                log.check("\(section.menuTitle) ▸ \(expected) is in the menu bar", true)
                checkKeyEquivalent(item, id: id, expected: expected, log: &log)
            }
        }
        // The inspector is gone, and a menu item that opens an empty panel is
        // worse than no menu item. Stated as a check so its removal is measured
        // in the running app rather than assumed from a deleted source file.
        let view = topLevelMenu(named: "View")
        log.check(
            "the View menu no longer offers an inspector",
            view?.items.contains { $0.title.contains("Inspector") } != true)
    }

    /// The catalog's chord, as AppKit ended up holding it.
    ///
    /// The modifier mask is compared bit for bit; the key character is only
    /// checked for presence, because AppKit stores the arrows and Escape as
    /// private-use characters that are not worth re-deriving here — an item
    /// carrying *a* key equivalent when the catalog says it should, and none
    /// when it says it should not, is what a drifted shortcut would break.
    @MainActor
    private static func checkKeyEquivalent(
        _ item: NSMenuItem, id: ActionID, expected: String, log: inout Logger
    ) {
        guard let chord = ActionCatalog.chord(id) else {
            log.check("\(expected) carries no key equivalent", item.keyEquivalent.isEmpty)
            return
        }
        log.check("\(expected) carries a key equivalent", !item.keyEquivalent.isEmpty)
        let mask = item.keyEquivalentModifierMask
        var drawn: KeyModifiers = []
        if mask.contains(.shift) { drawn.insert(.shift) }
        if mask.contains(.option) { drawn.insert(.option) }
        if mask.contains(.command) { drawn.insert(.command) }
        log.check(
            "\(expected) draws \(chord.display) (mask \(mask.rawValue))",
            drawn == chord.modifiers.subtracting(.control))
    }

    /// `⌘/` opens a window of its own, and the waveform does not pay for it.
    ///
    /// The width is measured through `Viewport.widthPixels`, which is only ever
    /// written by `ViewerModel.setLaneSize` — so a width that *moved* would
    /// prove the reference had taken a column out of the document window, which
    /// is exactly what a separate window must not do.
    @MainActor
    private static func checkShortcutWindow(
        model: ViewerModel, theme: ThemeController, shortcuts: ShortcutWindowController,
        log: inout Logger, outputDirectory: String
    ) async {
        let before = model.viewport.widthPixels
        // Held from before the second window exists. Looked up by title it is
        // not: `navigationTitle` renames the document window after the loaded
        // track, so "the window called Artscribe" stops existing the moment a
        // file is open — which is how this check first reported the document
        // window missing when it was on screen the whole time.
        let document = NSApp.keyWindow ?? NSApp.windows.first
        shortcuts.show()
        // Generously: a new window is created, laid out and ordered front, and
        // the lanes are not re-measured until that has settled. The inspector's
        // equivalent check read a stale width at 0.5 s.
        await settle(seconds: 1.2)

        guard let window = shortcutWindow() else {
            log.check("⌘/ opens a Keyboard Shortcuts window", false)
            return
        }
        log.check("⌘/ opens a Keyboard Shortcuts window", true)
        log.check("it is visible", window.isVisible)
        log.check(
            "it is resizable (styleMask \(window.styleMask.rawValue))",
            window.styleMask.contains(.resizable))
        log.check("it has a close button of its own", window.styleMask.contains(.closable))
        log.note("its frame", "\(window.frame)")
        log.check(
            "it is big enough to draw a keyboard on (\(Int(window.frame.width)) px wide)",
            window.frame.width >= 760)

        let during = model.viewport.widthPixels
        log.check(
            "the waveform keeps its full width (\(before) → \(during) px)", during == before)
        snapshot(window, to: "\(outputDirectory)/20-shortcut-window.png")

        checkTheWindowIsItsOwn(window, document: document, shortcuts: shortcuts, log: &log)
        checkListScrolls(window, log: &log, outputDirectory: outputDirectory)

        // The layers, driven for real: pinning ⌥⇧ must change what the keyboard
        // is asked to draw, and the resolution rule must prefer a held modifier.
        shortcuts.pin([.option, .shift])
        await settle(seconds: 0.4)
        log.check(
            "a layer can be pinned without holding anything",
            shortcuts.pinnedLayer == [.option, .shift])
        log.check(
            "the pinned layer draws the far loop moves",
            ShortcutLayers.bindings(on: shortcuts.pinnedLayer)[.character("a")]?.id
                == .loopMoveInLeftFar)
        log.check(
            "a held modifier overrides the pin",
            ShortcutLayers.effective(held: .shift, pinned: shortcuts.pinnedLayer) == .shift)
        snapshot(window, to: "\(outputDirectory)/21-shortcut-layer.png")
        shortcuts.pin([])

        // The filter narrows the list, and the same predicate quiets the keys.
        shortcuts.query = "loop"
        await settle(seconds: 0.4)
        let matched = ShortcutSearch.grouped(query: shortcuts.query).flatMap(\.entries)
        log.check(
            "the filter narrows the list (\(matched.count) of \(ActionCatalog.entries.count))",
            !matched.isEmpty && matched.count < ActionCatalog.entries.count)
        snapshot(window, to: "\(outputDirectory)/22-shortcut-filtered.png")
        shortcuts.query = ""
        await settle(seconds: 0.3)

        // Both themes, because the nine category tints are two designed sets
        // and not one inverted one — see `ActionCategory.tint`. Captured rather
        // than asserted: the contrast ratios are computed and recorded in that
        // file, and what a run can add is that the light set actually reaches
        // the screen.
        let wasTheme = theme.preference
        theme.preference = .light
        await settle(seconds: 0.8)
        snapshot(window, to: "\(outputDirectory)/23-shortcut-light.png")
        theme.preference = wasTheme
        await settle(seconds: 0.5)

        // Closing and reopening the scene gives SwiftUI leave to build a *new*
        // `NSWindow`, so the checks below work from the one on screen now rather
        // than from the object this function opened.
        await checkToggle(window, document: document, shortcuts: shortcuts, log: &log)
        guard let current = visibleShortcutWindow() else {
            log.check("the window is still on screen after ⌘/ was pressed four times", false)
            return
        }

        // Closable independently: the document window survives it.
        let documentWasVisible = document?.isVisible == true
        current.performClose(nil)
        await settle(seconds: 0.8)
        log.check("the window closes on its own", shortcutWindow()?.isVisible != true)
        log.check("the document window was there to survive it", documentWasVisible)
        log.check("and the document window is untouched", document?.isVisible == true)
        log.check(
            "the waveform is still the width it was (\(model.viewport.widthPixels) px)",
            model.viewport.widthPixels == before)
    }

    /// **The reference is a window of its own, and the app knows it.**
    ///
    /// The P0 behind this: `TrackpadMonitor` is a *local* event monitor, so it
    /// sees every scroll the application receives and returns `nil` for whatever
    /// it handles — which meant a wheel notch over this window's list was eaten
    /// here and spent panning the waveform behind. The rule that fixed it asks
    /// `KeyWindowTracker` whether the event's window is the document's, so what
    /// a run can add to the unit tests is that the wiring is real: that
    /// `adopt(document:)` ran against the window on screen, and that this window
    /// is not it.
    ///
    /// Driven this way rather than by posting a scroll, deliberately: a
    /// synthesised `NSEvent(cgEvent:)` carries **no window at all**, so there is
    /// no way from inside the process to post a scroll that AppKit would say
    /// arrived in the shortcut window. The identity is the whole of the rule.
    @MainActor
    private static func checkTheWindowIsItsOwn(
        _ window: NSWindow, document: NSWindow?, shortcuts: ShortcutWindowController,
        log: inout Logger
    ) {
        log.check("the controller holds the window it opened", shortcuts.window === window)
        log.check("it is not the document window", window !== document)
        log.check(
            "the trackpad monitor does not take this window's scrolls",
            !KeyWindowTracker.shared.isDocument(window))
        guard let document else {
            log.check("the document window was adopted", false)
            return
        }
        log.check("the document window was adopted", KeyWindowTracker.shared.isDocument(document))

        // The other half of symptom 1: the filter must not open holding the
        // keyboard, or `ModifierMonitor` reads every modifier press as text
        // being typed and the header's "Hold ⇧ ⌥ ⌘" is dead on arrival.
        log.check(
            "the filter does not open holding the keyboard "
                + "(\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"))",
            !(window.firstResponder is NSTextView))
        log.check(
            "so a held modifier is read as a layer, not as typing",
            ShortcutLayers.effective(held: .shift, pinned: []) == .shift)
    }

    /// `⌘/` a second time.
    ///
    /// The user's report was that it "does nothing", and what a run can settle
    /// is which of the two halves was true: `openWindow(id:)` *does* raise a
    /// backgrounded window — measured here — and does nothing only for one
    /// already in front. So the toggle has to close from the front and raise
    /// from behind, and both are driven.
    @MainActor
    private static func checkToggle(
        _ window: NSWindow, document: NSWindow?, shortcuts: ShortcutWindowController,
        log: inout Logger
    ) async {
        window.makeKeyAndOrderFront(nil)
        await settle(seconds: 0.5)
        log.check("the window is in front before ⌘/ is pressed again", isFront(window))

        shortcuts.toggle()
        await settle(seconds: 0.8)
        log.check("⌘/ at the window in front of you closes it", window.isVisible == false)

        shortcuts.toggle()
        await settle(seconds: 1.0)
        let reopened = visibleShortcutWindow()
        log.check("⌘/ opens it again", reopened != nil)
        log.check("and it comes back in front", reopened.map(isFront) == true)

        // Open, but behind: raised rather than closed. The decision this task
        // had to make, and the one a unit test cannot drive.
        document?.makeKeyAndOrderFront(nil)
        await settle(seconds: 0.6)
        let wasBehind = reopened.map { !isFront($0) } == true
        log.check("the document window can be brought in front of it", wasBehind)
        shortcuts.toggle()
        await settle(seconds: 0.8)
        log.check(
            "⌘/ at a window that is behind does not close it",
            visibleShortcutWindow() != nil)
        log.check("it raises it instead", visibleShortcutWindow().map(isFront) == true)
    }

    /// Frontmost, on a machine where nothing can become key.
    ///
    /// The same fallback `ShortcutWindowController` uses, and it is here for the
    /// same reason: this run happens on a screen-locked login session, where
    /// `isKeyWindow` is false for every window in the process.
    @MainActor
    private static func isFront(_ window: NSWindow) -> Bool {
        if window.isKeyWindow { return true }
        guard NSApp.keyWindow == nil else { return false }
        return NSApp.orderedWindows.first { $0.isVisible } === window
    }

    /// The right-hand list, at a deliberately small window, measured rather
    /// than looked at.
    ///
    /// The user's report was that the list "overflows and just cuts off", and
    /// the fix turned on what that actually was: the list was *already* in a
    /// `ScrollView` bounded to its pane, and the only thing missing was any sign
    /// of it. So the check that matters is the pair — the clip is the height of
    /// the pane (not of the content, which would be a real overflow), **and**
    /// the document really moves when it is scrolled. A single "there is an
    /// NSScrollView" assertion would have passed before the fix too.
    ///
    /// The window is shrunk to 820×470 first, near its 760×460 minimum, because
    /// that is where a clipping bug lives and it is not far off the size the
    /// user hit this at.
    @MainActor
    private static func checkListScrolls(
        _ window: NSWindow, log: inout Logger, outputDirectory: String
    ) {
        let restore = window.frame
        window.setContentSize(NSSize(width: 820, height: 470))
        window.layoutIfNeeded()
        guard let scroll = firstScrollView(in: window.contentView) else {
            log.check("the list is in a scroll view", false)
            window.setFrame(restore, display: true)
            return
        }
        let content = scroll.documentView?.frame.height ?? 0
        let visible = scroll.documentVisibleRect.height
        log.check("the list is in a scroll view", true)
        log.check(
            "at 820×470 the list is clipped to the pane, not to the window "
                + "(\(Int(visible)) px of \(Int(content)))",
            visible > 0 && visible < content && visible <= window.frame.height)
        snapshot(window, to: "\(outputDirectory)/24-shortcut-small.png")

        // Driven to the end three times rather than once. The list is a
        // `LazyVStack`, so the document's height is an *estimate* that firms up
        // as rows are realised — a single scroll to the height read beforehand
        // stopped 265 px short of the real end, and reported a failure that was
        // the harness's arithmetic rather than the window's.
        for _ in 0..<3 {
            let end = (scroll.documentView?.frame.height ?? 0) - scroll.documentVisibleRect.height
            scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, end)))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.layoutIfNeeded()
        }
        let settled = scroll.documentVisibleRect
        let settledContent = scroll.documentView?.frame.height ?? 0
        log.check(
            "its last row can be reached without resizing the window "
                + "(\(Int(settled.maxY)) px of \(Int(settledContent)))",
            settled.origin.y > 0 && settled.maxY >= settledContent - 1)
        snapshot(window, to: "\(outputDirectory)/25-shortcut-small-scrolled.png")

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        window.setFrame(restore, display: true)
        window.layoutIfNeeded()
    }

    /// The first `NSScrollView` in a view tree. SwiftUI's `ScrollView` is backed
    /// by one on macOS, and the list is the only scrolling thing in this window.
    @MainActor
    private static func firstScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func shortcutWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Keyboard Shortcuts" }
    }

    /// The one **on screen**. Reopening a `Window` scene gives SwiftUI leave to
    /// build a second `NSWindow`, and a closed one stays in `NSApp.windows`, so
    /// "the first window with that title" can be the corpse of the last.
    @MainActor
    private static func visibleShortcutWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Keyboard Shortcuts" && $0.isVisible }
    }

    @MainActor
    private static func topLevelMenu(named title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first { $0.title == title }?.submenu
    }
}
