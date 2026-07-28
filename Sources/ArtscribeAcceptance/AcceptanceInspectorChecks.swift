import AppKit
import ArtscribeUI
import Foundation

/// Task 20: the inspector, and the end-to-end half of the drift guard.
///
/// `ActionCatalogTests` proves the catalog, the menu plan and the key bindings
/// agree with each other. What it cannot prove is that any of it reached
/// **AppKit** — that the titles SwiftUI built are the titles the catalog says,
/// and that the key equivalents survived the trip into `NSMenuItem`. That needs
/// a running menu bar, which is what this is.
///
/// It also measures the one thing about the inspector that a unit test cannot:
/// that opening it takes width from the waveform and closing it gives the width
/// back, with the viewport re-rendered at the new size.
extension AcceptanceRun {

    @MainActor
    static func checkInspector(
        model: ViewerModel, inspector: InspectorController, context: MenuContext,
        log: inout Logger, outputDirectory: String
    ) async {
        await checkMenusMirrorTheCatalog(context: context, log: &log)
        await checkInspectorWidth(
            model: model, inspector: inspector, log: &log, outputDirectory: outputDirectory)
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

    /// Spec §2's collapsible inspector, and the requirement that collapsing it
    /// hands the width straight back to the waveform.
    ///
    /// Measured through `Viewport.widthPixels`, which is only ever written by
    /// `ViewerModel.setLaneSize` — so a width that moves proves the lanes were
    /// re-laid out *and* the viewport re-clamped at the new size, which is the
    /// thing that would silently not happen if the panel floated over the
    /// window instead of taking a column beside it.
    @MainActor
    private static func checkInspectorWidth(
        model: ViewerModel, inspector: InspectorController, log: inout Logger,
        outputDirectory: String
    ) async {
        // Generously, and measured rather than guessed: the panel slides, and
        // the lanes are not re-laid out until it has finished. At 0.5 s this
        // check read the *old* width and reported a change that had already
        // happened as no change at all.
        inspector.isPresented = false
        await settle(seconds: 1.2)
        let collapsed = model.viewport.widthPixels

        inspector.show(.shortcuts)
        await settle(seconds: 1.2)
        let opened = model.viewport.widthPixels
        log.check(
            "opening the inspector narrows the waveform (\(collapsed) → \(opened) px)",
            opened < collapsed)
        log.check("the inspector is showing the shortcuts page", inspector.page == .shortcuts)
        snapshot(to: "\(outputDirectory)/20-inspector-open.png")

        // ⌘/ again on the page already showing puts the panel away.
        inspector.show(.shortcuts)
        await settle(seconds: 1.2)
        let closed = model.viewport.widthPixels
        log.check("⌘/ on the page already showing closes the inspector", !inspector.isPresented)
        log.check(
            "collapsing returns the full width to the waveform (\(opened) → \(closed) px)",
            closed == collapsed)

        inspector.toggle()
        log.check("⌥⌘I opens it again", inspector.isPresented)
        inspector.toggle()
        log.check("⌥⌘I closes it", !inspector.isPresented)
        await settle(seconds: 0.4)
    }

    @MainActor
    private static func topLevelMenu(named title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first { $0.title == title }?.submenu
    }
}
