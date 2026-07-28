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

        // Closable independently: the document window survives it.
        let documentWasVisible = document?.isVisible == true
        window.performClose(nil)
        await settle(seconds: 0.8)
        log.check("the window closes on its own", shortcutWindow()?.isVisible != true)
        log.check("the document window was there to survive it", documentWasVisible)
        log.check("and the document window is untouched", document?.isVisible == true)
        log.check(
            "the waveform is still the width it was (\(model.viewport.widthPixels) px)",
            model.viewport.widthPixels == before)
    }

    @MainActor
    private static func shortcutWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Keyboard Shortcuts" }
    }

    @MainActor
    private static func topLevelMenu(named title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first { $0.title == title }?.submenu
    }
}
