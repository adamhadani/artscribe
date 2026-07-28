import Foundation
import Testing

@testable import ArtscribeUI

/// The inspector's state, the dispatch table behind every action, and the
/// grouping the shortcut reference is drawn from.
///
/// Views are not snapshot-tested here, so what the panel *decides* is extracted
/// and checked instead: which rows it shows, in what order, and what the two
/// shortcuts that open it do.
@Suite("Inspector")
struct InspectorTests {

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "artscribe.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not make a defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @MainActor
    @Test("the inspector starts closed and ⌥⌘I toggles it")
    func toggling() {
        withDefaults { defaults in
            let inspector = InspectorController(defaults: defaults)
            #expect(!inspector.isPresented)
            inspector.toggle()
            #expect(inspector.isPresented)
            inspector.toggle()
            #expect(!inspector.isPresented)
        }
    }

    /// `⌘/` opens the panel *to a page*, and closes it again if that page is
    /// already the one showing — a key that only ever opened would leave you
    /// reaching for a different one to put it away.
    @MainActor
    @Test("⌘/ opens to the shortcuts page, and closes it when already there")
    func showingAPage() {
        withDefaults { defaults in
            let inspector = InspectorController(defaults: defaults)
            inspector.show(.shortcuts)
            #expect(inspector.isPresented)
            #expect(inspector.page == .shortcuts)
            inspector.show(.shortcuts)
            #expect(!inspector.isPresented)
            // And it opens again rather than toggling itself shut twice.
            inspector.show(.shortcuts)
            #expect(inspector.isPresented)
        }
    }

    @MainActor
    @Test("an open inspector is still open next launch")
    func presentationPersists() {
        withDefaults { defaults in
            let first = InspectorController(defaults: defaults)
            first.toggle()
            #expect(InspectorController(defaults: defaults).isPresented)
            first.toggle()
            #expect(!InspectorController(defaults: defaults).isPresented)
        }
    }

    /// A stored page that is not one of the cases — a hand-edited plist, or one
    /// written by a later version that had a Practice page — falls back rather
    /// than crashing on a force-unwrapped `init(rawValue:)`.
    @MainActor
    @Test("an unrecognised stored page falls back")
    func unknownStoredPage() {
        withDefaults { defaults in
            defaults.set("practice", forKey: "inspector.page")
            #expect(InspectorController(defaults: defaults).page == .shortcuts)
        }
    }

    // MARK: - The reference the panel draws

    @Test("the reference lists every action that has a shortcut, exactly once")
    func referenceCoversEveryBoundAction() {
        let listed = ActionCatalog.reference.flatMap(\.entries).map(\.id)
        let bound = ActionCatalog.entries.filter { !$0.chords.isEmpty }.map(\.id)
        #expect(Set(listed) == Set(bound))
        #expect(listed.count == bound.count, "an action is listed twice")
    }

    /// Stop, Clear Loop and the two scroll items are menu items with no chord.
    /// A reference headed "Shortcuts" that listed them with a blank where the
    /// key should be would be a lie about what is available.
    @Test("an action with no shortcut is not in the reference")
    func unboundActionsAreNotListed() {
        let listed = Set(ActionCatalog.reference.flatMap(\.entries).map(\.id))
        for id in [ActionID.transportStop, .loopClear, .viewScrollLeft, .viewScrollRight] {
            #expect(!listed.contains(id), "\(id.rawValue) has no chord and must not be listed")
        }
    }

    @Test("the reference is grouped in category order, with no empty group")
    func referenceIsGroupedInOrder() {
        let categories = ActionCatalog.reference.map(\.category)
        #expect(categories == ActionCategory.allCases.filter { categories.contains($0) })
        #expect(ActionCatalog.reference.allSatisfy { !$0.entries.isEmpty })
    }

    // MARK: - Dispatch

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
}
