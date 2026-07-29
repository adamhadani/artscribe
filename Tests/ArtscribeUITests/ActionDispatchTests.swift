import Testing

@testable import ArtscribeUI

/// The dispatch table behind every action, and the shortcut window's state.
///
/// Views are not snapshot-tested here, so what the window *decides* is
/// extracted and checked instead — the keyboard, the layers and the filter in
/// `ShortcutWindowTests`, and here the table every route into an action goes
/// through.
///
/// This suite was `InspectorTests` until Task 25 removed the inspector. Its
/// inspector-state tests went with it; its dispatch tests are the reason the
/// file survived under a truer name.
@Suite("Action dispatch")
struct ActionDispatchTests {

    /// The exhaustiveness a `switch` would have given, bought back at test time:
    /// the table is a dictionary because a sixty-case `switch` is a SwiftLint
    /// complexity error here.
    @MainActor
    @Test("every action is invocable")
    func everyActionIsInvocable() {
        for id in ActionID.allCases where !ActionInvoker.handledElsewhere.contains(id) {
            #expect(ActionInvoker.table[id] != nil, "\(id.rawValue) has no implementation")
        }
        for id in ActionInvoker.handledElsewhere {
            #expect(ActionInvoker.table[id] == nil, "\(id.rawValue) is claimed to be elsewhere")
        }
    }

    /// The four preset ids and the four ratios are two lists, and a menu item
    /// titled "50% Speed" that set 0.75 would be the worst kind of quiet wrong.
    @MainActor
    @Test("the speed presets line up with their ratios and their titles")
    func presetsLineUpWithTheirRatios() {
        #expect(ActionInvoker.presetIDs.count == SpeedStepping.presets.count)
        for (index, id) in ActionInvoker.presetIDs.enumerated() {
            let ratio = SpeedStepping.presets[index]
            #expect(ActionInvoker.presetRatio(id) == ratio)
            #expect(ActionCatalog.entry(id).title == "\(SpeedStepping.percentLabel(ratio)) Speed")
        }
    }

    // MARK: - The shortcut window's controller

    /// `⌘/` opens the window, through the closure the scene installs. With none
    /// installed it must not crash — the action is live from launch, and the
    /// scene has not necessarily appeared yet.
    @MainActor
    @Test("⌘/ opens the shortcut window, and does nothing before the scene is ready")
    func showingTheWindow() {
        let shortcuts = ShortcutWindowController()
        shortcuts.show()

        let counter = OpenCounter()
        shortcuts.present = { counter.count += 1 }
        shortcuts.show()
        shortcuts.show()
        #expect(counter.count == 2)
        // `toggle` with no window yet is `show` — it cannot close what has
        // never been opened, and it must still work before the scene has
        // reported its `NSWindow` back.
        shortcuts.toggle()
        #expect(counter.count == 3)
    }

    /// A box for the count, because `present` is an escaping `@MainActor`
    /// closure and a captured local `var` will not do.
    @MainActor
    final class OpenCounter {
        var count = 0
    }

    @MainActor
    @Test("the window opens on the base layer with no filter")
    func startsUnfiltered() {
        let shortcuts = ShortcutWindowController()
        #expect(shortcuts.pinnedLayer == [])
        #expect(shortcuts.query.isEmpty)
        shortcuts.pin([.option, .shift])
        #expect(shortcuts.pinnedLayer == [.option, .shift])
        shortcuts.pin([])
        #expect(shortcuts.pinnedLayer == [])
    }

    /// The inspector's `⌥⌘I`, its catalog row and its menu item are gone, and
    /// this is what stops them being reintroduced by a merge or a half-reverted
    /// branch. Stated as its own test because "we deleted it" is not something
    /// the suite would otherwise notice.
    @Test("nothing in the app still offers an inspector")
    func theInspectorIsGone() {
        #expect(
            !ActionID.allCases.contains {
                $0.rawValue.localizedCaseInsensitiveContains("inspector")
            })
        #expect(!ActionCatalog.entries.contains { $0.title.contains("Inspector") })
        let chords = ActionCatalog.entries.flatMap(\.chords).map(\.display)
        #expect(!chords.contains("⌥⌘I"), "⌥⌘I is bound again")
    }
}
