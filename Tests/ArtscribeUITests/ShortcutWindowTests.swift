import AppKit
import Testing

@testable import ArtscribeUI

/// **The shortcut window's logic**, which is all of it that is not drawing.
///
/// The window is three things — a keyboard with the bindings drawn on it, a
/// modifier layer that follows the keys you are holding, and a filter that
/// narrows both it and the list beside it. Every one of those is a pure
/// function over `ActionCatalog`, and every one is tested here; the view is
/// not snapshot-tested, following this project's convention.
///
/// The load-bearing test is `everyActionInTheCatalogIsReachableInTheWindow`.
/// This project's characteristic failure is that a feature exists in one place
/// and not another and the user finds it, so an action must not be able to be
/// added to the catalog and silently left out of the window that claims to
/// list them all.
@Suite("Shortcut window")
struct ShortcutWindowTests {

    // MARK: - The physical layout

    /// A keyboard whose rows are different widths does not read as a keyboard.
    /// The rows are data, so this is checkable rather than a thing to notice.
    @Test("every row of the layout is exactly one keyboard wide")
    func everyRowIsTheSameWidth() {
        for (index, row) in KeyboardLayout.rows.enumerated() {
            let width = row.reduce(0) { $0 + $1.width }
            #expect(
                abs(width - KeyboardLayout.unitsPerRow) < 0.001,
                "row \(index) is \(width) units, expected \(KeyboardLayout.unitsPerRow)")
        }
    }

    /// The half of the drift guard that belongs to this window: a chord in the
    /// catalog whose key has no cap on the drawn keyboard would be a shortcut
    /// the reference silently cannot show.
    @Test("every key the catalog binds has a cap on the keyboard")
    func everyBoundKeyHasACap() {
        for entry in ActionCatalog.entries {
            for chord in entry.chords {
                #expect(
                    KeyboardLayout.position(of: chord.key) != nil,
                    "\(chord.display) (\(entry.id.rawValue)) has no key on the layout")
            }
        }
    }

    /// Two caps claiming the same token would draw one binding twice and leave
    /// the lookup's answer down to ordering.
    @Test("no token appears on two caps")
    func noTokenAppearsTwice() {
        var seen: Set<KeyToken> = []
        for row in KeyboardLayout.rows {
            for cap in row {
                guard let token = cap.token else { continue }
                #expect(!seen.contains(token), "\(token.display) is on the layout twice")
                seen.insert(token)
            }
        }
    }

    /// Every modifier that makes a layer is a key you can physically hold, or
    /// the "hold it and watch" half of this window is a promise it cannot keep.
    @Test("every layer's modifiers are caps on the keyboard")
    func everyLayerModifierHasACap() {
        let onTheBoard = KeyboardLayout.rows.flatMap { $0 }.compactMap(\.modifier)
        for layer in ShortcutLayers.available where !layer.isEmpty {
            for single in [KeyModifiers.shift, .option, .command, .control]
            where layer.contains(single) {
                #expect(
                    onTheBoard.contains { $0 == single },
                    "\(ShortcutLayers.title(layer)) needs a \(single.rawValue) key to hold")
            }
        }
    }

    // MARK: - Modifier layers

    /// Derived from the catalog rather than listed, so a chord on a modifier
    /// combination nobody thought of still gets a layer to be seen on.
    @Test("the layers are exactly the modifier combinations the catalog uses")
    func layersComeFromTheCatalog() {
        var expected = Set(ActionCatalog.entries.flatMap(\.chords).map(\.modifiers))
        expected.insert([])
        #expect(Set(ShortcutLayers.available) == expected)
        #expect(ShortcutLayers.available.first == [], "the base layer is not first")
        // Simplest first: one modifier before two, so the picker reads as a
        // progression rather than a set.
        let counts = ShortcutLayers.available.map { $0.rawValue.nonzeroBitCount }
        #expect(counts == counts.sorted(), "the layers are not ordered simplest first")
    }

    @Test("each layer's bindings are the catalog chords carrying exactly those modifiers")
    func bindingsPerLayer() {
        for layer in ShortcutLayers.available {
            let bindings = ShortcutLayers.bindings(on: layer)
            let expected = ActionCatalog.entries.flatMap { entry in
                entry.chords.filter { $0.modifiers == layer }.map { ($0.key, entry.id) }
            }
            #expect(bindings.count == expected.count, "\(ShortcutLayers.title(layer)) miscounts")
            for (token, id) in expected {
                #expect(
                    bindings[token]?.id == id,
                    "\(ShortcutLayers.title(layer)) ▸ \(token.display) is not \(id.rawValue)")
            }
        }
    }

    /// The base layer must not show a ⇧ or ⌥ chord: `Z` and `⇧Z` are different
    /// actions, and a keyboard that showed both on one cap would teach the
    /// wrong thing.
    @Test("the base layer holds no modified chord")
    func baseLayerIsUnmodified() {
        let base = ShortcutLayers.bindings(on: [])
        #expect(base[.character("z")]?.id == .nudgeBack)
        #expect(base[.character("a")]?.id == .loopSetIn)
        #expect(base[.space]?.id == .transportReturnToStart)
        let shifted = ShortcutLayers.bindings(on: .shift)
        #expect(shifted[.character("z")]?.id == .nudgeBackFine)
        #expect(shifted[.space]?.id == .transportPlayPause)
        let optioned = ShortcutLayers.bindings(on: .option)
        #expect(optioned[.character("z")]?.id == .nudgeBackCoarse)
        let both = ShortcutLayers.bindings(on: [.option, .shift])
        #expect(both[.character("a")]?.id == .loopMoveInLeftFar)
    }

    /// Holding a modifier wins, because that is the gesture that has to feel
    /// live. Letting go returns to whatever layer was pinned, which is the
    /// half that makes the window usable by someone who cannot hold two keys.
    @Test("a held modifier wins over the pinned layer, and letting go returns to it")
    func heldBeatsPinned() {
        #expect(ShortcutLayers.effective(held: .shift, pinned: []) == .shift)
        #expect(
            ShortcutLayers.effective(held: [.option, .shift], pinned: .command)
                == [.option, .shift])
        #expect(ShortcutLayers.effective(held: [], pinned: .option) == .option)
        #expect(ShortcutLayers.effective(held: [], pinned: []) == [])
        // Pinning is what someone who cannot hold ⌥ and ⇧ at once uses instead,
        // so a pinned layer must survive a press that carries no modifier.
        #expect(ShortcutLayers.effective(held: [], pinned: [.option, .shift]) == [.option, .shift])
    }

    /// What a real `.flagsChanged` carries, turned into a layer.
    ///
    /// The reason this is not a one-line cast: macOS sets `.capsLock` on
    /// **everything** while Caps Lock is down and `.function` on every arrow, so
    /// a raw mask compared against a layer would never match one — and the
    /// keyboard would sit on the base layer for anyone who leaves Caps Lock on.
    @Test("held modifier flags are read as a layer, ignoring the ones nothing binds")
    func flagsBecomeALayer() {
        #expect(KeyModifiers.fromFlags([]) == [])
        #expect(KeyModifiers.fromFlags([.shift]) == .shift)
        #expect(KeyModifiers.fromFlags([.option, .shift]) == [.option, .shift])
        #expect(KeyModifiers.fromFlags([.command, .shift]) == [.command, .shift])
        #expect(KeyModifiers.fromFlags([.capsLock]) == [])
        #expect(KeyModifiers.fromFlags([.shift, .capsLock, .function]) == .shift)
        #expect(KeyModifiers.fromFlags([.numericPad]) == [])
        // `⌃` is kept here, unlike in `fromEvent`: this mask is a question about
        // which layer is on screen, and answering `⌃` with the base layer would
        // claim `Z` nudges when `⌃Z` does nothing.
        #expect(KeyModifiers.fromFlags([.control]) == .control)
    }

    // MARK: - The filter

    @Test("the filter narrows by title, by category and by chord")
    func filterMatchesTheThreeThingsPeopleType() {
        let restart = ActionCatalog.entry(.loopRestart)
        #expect(ShortcutSearch.matches(restart, query: "restart"))
        #expect(ShortcutSearch.matches(restart, query: "RESTART"))
        #expect(ShortcutSearch.matches(restart, query: "loop"))
        #expect(ShortcutSearch.matches(restart, query: "F"))
        #expect(!ShortcutSearch.matches(restart, query: "volume"))
        // The chord as it is written, and as it is spoken.
        let far = ActionCatalog.entry(.loopMoveInLeftFar)
        #expect(ShortcutSearch.matches(far, query: "⌥⇧A"))
        #expect(ShortcutSearch.matches(far, query: "shift"))
        #expect(ShortcutSearch.matches(far, query: "option"))
        // And the identifier, which is what a bug report quotes.
        #expect(ShortcutSearch.matches(far, query: "loop.moveIn"))
        // An empty or whitespace query hides nothing.
        #expect(ShortcutSearch.matches(far, query: ""))
        #expect(ShortcutSearch.matches(far, query: "   "))
    }

    @Test("the filtered list is grouped in category order with no empty group")
    func groupingIsOrdered() {
        let groups = ShortcutSearch.grouped(query: "loop")
        let categories = groups.map(\.category)
        #expect(categories == ActionCategory.allCases.filter { categories.contains($0) })
        #expect(groups.allSatisfy { !$0.entries.isEmpty })
        #expect(ShortcutSearch.grouped(query: "zzzzz").isEmpty)
    }

    /// A keyboard picture answers "what can I press"; it cannot answer "what is
    /// the shortcut for Stop", because there is not one. The list has to.
    @Test("an action with no shortcut is still findable in the list")
    func unboundActionsAreListed() {
        for id in [ActionID.transportStop, .loopClear, .viewScrollLeft, .viewScrollRight] {
            let entry = ActionCatalog.entry(id)
            #expect(entry.chords.isEmpty, "\(id.rawValue) was expected to have no chord")
            let found = ShortcutSearch.grouped(query: entry.title).flatMap(\.entries).map(\.id)
            #expect(found.contains(id), "\(id.rawValue) cannot be found by its own title")
        }
    }

    // MARK: - The guard

    /// **The one that must never be deleted.** Five features on this project
    /// have been found missing by the user rather than by a review; an action
    /// added to the catalog and left out of the window that documents the
    /// catalog would be the sixth.
    @Test("every action in the catalog is reachable in the window")
    func everyActionInTheCatalogIsReachableInTheWindow() {
        let listed = Set(ShortcutSearch.grouped(query: "").flatMap(\.entries).map(\.id))
        for id in ActionID.allCases {
            #expect(listed.contains(id), "\(id.rawValue) is in no list group")
        }
        #expect(listed.count == ActionID.allCases.count, "an action is listed twice")

        // And every action that *has* a chord is also drawn on the keyboard, on
        // the layer its modifiers name and on a cap that exists.
        for entry in ActionCatalog.entries where !entry.chords.isEmpty {
            for chord in entry.chords {
                #expect(
                    ShortcutLayers.available.contains(chord.modifiers),
                    "\(chord.display) is on no layer")
                #expect(
                    ShortcutLayers.bindings(on: chord.modifiers)[chord.key]?.id == entry.id,
                    "\(chord.display) is not drawn for \(entry.id.rawValue)")
                #expect(
                    KeyboardLayout.position(of: chord.key) != nil,
                    "\(chord.display) has no cap to be drawn on")
            }
        }
    }

    /// Every action, found by typing its own name — the other half of
    /// reachability, and the one a user actually performs.
    @Test("every action can be found by typing its title")
    func everyActionIsFindableByTitle() {
        for entry in ActionCatalog.entries {
            let found = ShortcutSearch.grouped(query: entry.title).flatMap(\.entries).map(\.id)
            #expect(found.contains(entry.id), "\(entry.id.rawValue) is not findable by its title")
        }
    }

    // MARK: - The split between the two panes

    /// The divider must not be draggable into a state the window cannot draw.
    ///
    /// This is the testable half of the rebalance: a stored width from a wide
    /// window arriving at a narrow one is exactly the case that would otherwise
    /// crush the keyboard to nothing, and it happens on the next launch rather
    /// than under anyone's hand.
    @Test("the divider cannot crush either pane")
    func theSplitKeepsBothPanesUsable() {
        for total in [760.0, 900, 1100, 1320, 1600, 2400] {
            for asked in [-500.0, 0, 100, 260, 340, 900, 5000] {
                let list = ShortcutSplit.listWidth(preferred: asked, totalWidth: total)
                let keyboard = total - ShortcutSplit.dividerWidth - list
                #expect(
                    list >= ShortcutSplit.minimumListWidth,
                    "\(asked) at \(total) left the list \(list) pt wide")
                #expect(
                    keyboard >= ShortcutSplit.minimumKeyboardWidth,
                    "\(asked) at \(total) left the keyboard \(keyboard) pt wide")
            }
        }
    }

    /// Inside the range, what was asked for is what is given — otherwise the
    /// divider would not follow the pointer.
    @Test("a width both panes can afford is honoured exactly")
    func theSplitHonoursAnAffordableWidth() {
        #expect(ShortcutSplit.listWidth(preferred: 340, totalWidth: 1320) == 340)
        #expect(ShortcutSplit.listWidth(preferred: 520, totalWidth: 1320) == 520)
        #expect(ShortcutSplit.listWidth(preferred: 260, totalWidth: 760) == 260)
        // And clamped, not ignored, when it is not affordable: 760 − 1 − 430.
        #expect(ShortcutSplit.listWidth(preferred: 520, totalWidth: 760) == 329)
    }

    /// A layout pass can propose a width of zero on the way to the real one. A
    /// negative frame is a crash, so the degenerate case is shared out rather
    /// than clamped into a contradiction.
    @Test("a width too small for both minimums never produces a negative pane")
    func theSplitSurvivesAWidthTooSmallForIt() {
        for total in [0.0, 1, 120, 400, 690] {
            let list = ShortcutSplit.listWidth(preferred: 340, totalWidth: total)
            #expect(list >= 0, "\(total) gave the list \(list) pt")
            #expect(list <= max(0, total - ShortcutSplit.dividerWidth), "\(total) overflowed")
        }
    }

    /// The window's own minimum has to leave room for both pane minimums, or
    /// the clamp above would be unsatisfiable at the smallest size a user can
    /// actually drag the window to. Three constants in two files that have to
    /// agree, which is precisely what nobody re-checks after changing one.
    @Test("the window's minimum width leaves room for both pane minimums")
    @MainActor
    func theWindowMinimumFitsBothPanes() {
        #expect(
            ShortcutSplit.minimumKeyboardWidth + ShortcutSplit.minimumListWidth
                + ShortcutSplit.dividerWidth <= ShortcutWindow.minimumWidth)
        #expect(ShortcutSplit.defaultListWidth >= ShortcutSplit.minimumListWidth)
    }

    // MARK: - Knowing there is more list below

    /// The fault this fixes: the list was already in a bounded, scrollable
    /// `ScrollView` and gave no sign of it. These are the two edges the fade is
    /// drawn from.
    @Test("a list taller than its pane says so at the bottom, and only there")
    func theListReportsMoreBelowWhenItOverflows() {
        let atTop = ShortcutListEdges(
            offset: 0, topInset: 0, bottomInset: 0, containerHeight: 617, contentHeight: 2160)
        #expect(atTop.hasMoreBelow)
        #expect(!atTop.hasMoreAbove)

        let midway = ShortcutListEdges(
            offset: 900, topInset: 0, bottomInset: 0, containerHeight: 617, contentHeight: 2160)
        #expect(midway.hasMoreBelow)
        #expect(midway.hasMoreAbove)

        let atBottom = ShortcutListEdges(
            offset: 1543, topInset: 0, bottomInset: 0, containerHeight: 617, contentHeight: 2160)
        #expect(!atBottom.hasMoreBelow)
        #expect(atBottom.hasMoreAbove)
    }

    /// A two-item filter result must not sit under a fade for ever. The
    /// exactly-fits case is the one floating point makes awkward.
    @Test("a list that fits its pane claims neither edge")
    func theListReportsNothingWhenItFits() {
        let exact = ShortcutListEdges(
            offset: 0, topInset: 0, bottomInset: 0, containerHeight: 617, contentHeight: 617)
        #expect(!exact.hasMoreAbove)
        #expect(!exact.hasMoreBelow)

        let short = ShortcutListEdges(
            offset: 0, topInset: 0, bottomInset: 0, containerHeight: 617, contentHeight: 120)
        #expect(!short.hasMoreAbove)
        #expect(!short.hasMoreBelow)
    }

    // MARK: - What ⌘/ does the second time

    /// The defect: `openWindow(id:)` brings a backgrounded window forward, but
    /// does nothing at all for one that is already in front — so `⌘/` at the
    /// window you are looking at was a dead key.
    @Test("⌘/ at the window in front of you puts it away")
    func toggleClosesFromTheFront() {
        #expect(ShortcutWindowController.action(isOpen: true, isFrontmost: true) == .close)
    }

    /// The decision worth stating: **behind is not closed**. The key was pressed
    /// to see the reference; raising it is the answer, and closing a window you
    /// cannot see would discard the filter and the divider you set in it with no
    /// visible cause.
    @Test("⌘/ at a window that is open but behind raises it rather than closing it")
    func toggleRaisesFromBehind() {
        #expect(ShortcutWindowController.action(isOpen: true, isFrontmost: false) == .present)
    }

    @Test("⌘/ with the window closed opens it")
    func toggleOpensWhenClosed() {
        #expect(ShortcutWindowController.action(isOpen: false, isFrontmost: false) == .present)
        // A window that is not open cannot be the frontmost one; the rule must
        // not be able to answer "close" for a window that does not exist.
        #expect(ShortcutWindowController.action(isOpen: false, isFrontmost: true) == .present)
    }

    // MARK: - Colour

    /// Colour is how the keyboard is read at a glance, so a category with no
    /// tint of its own would collapse two groups into one.
    @Test("every category has its own tint, in both themes")
    func categoryTintsAreDistinct() {
        for appearance in Appearance.allCases {
            let tints = ActionCategory.allCases.map { $0.tint(appearance) }
            #expect(
                Set(tints.map { "\($0.red),\($0.green),\($0.blue)" }).count
                    == ActionCategory.allCases.count,
                "two categories share a tint in \(appearance.rawValue)")
        }
    }
}
