import Testing

@testable import ArtscribeUI

/// **The drift guard.**
///
/// This project's characteristic failure is that documentation and code
/// disagree, and that the user finds it rather than a review: the nudge tiers,
/// `⇧←`/`⇧→`, the `.artscribe` sidecar, the inspector and the help sheet all
/// shipped that way. A shortcut reference that lies would be the worst of them,
/// because its whole purpose is to be believed.
///
/// So the reference is generated from `ActionCatalog`, the menu bar is
/// generated from `MenuPlan`, and these tests are what makes the two impossible
/// to change apart. Between them they catch:
///
/// * a shortcut changed in the catalog but not the menu — impossible now, since
///   the menu has no shortcut of its own to change;
/// * a menu item added without a catalog row — `noMenuItemIsOutsideTheCatalog`;
/// * a catalog row that no menu places, so it appears in the reference and
///   nowhere else — `everyCatalogActionAppearsInExactlyOneMenu`;
/// * the same action placed in two menus, which can fire twice or grey out in
///   one place and not the other — the same test;
/// * two actions given the same chord, so one of them is unreachable —
///   `noTwoActionsShareAChord`.
@Suite("Action catalog")
struct ActionCatalogTests {

    @Test("every ActionID has exactly one catalog entry")
    func everyActionHasExactlyOneEntry() {
        for id in ActionID.allCases {
            let matches = ActionCatalog.entries.filter { $0.id == id }
            #expect(matches.count == 1, "\(id.rawValue) has \(matches.count) catalog entries")
        }
        #expect(ActionCatalog.entries.count == ActionID.allCases.count)
    }

    /// The half of the guard that catches a *catalog* row nothing places: an
    /// action that the shortcut reference advertises and no menu offers.
    @Test("every catalog action appears in exactly one menu")
    func everyCatalogActionAppearsInExactlyOneMenu() {
        let placements = MenuPlan.placements
        for entry in ActionCatalog.entries {
            let placed = placements.filter { $0.id == entry.id }
            guard let section = entry.menu else {
                #expect(
                    ActionCatalog.notInOurMenus.contains(entry.id),
                    "\(entry.id.rawValue) names no menu and is not a declared exception")
                #expect(placed.isEmpty, "\(entry.id.rawValue) names no menu yet a menu places it")
                continue
            }
            #expect(
                placed.count == 1,
                "\(entry.id.rawValue) is placed \(placed.count) times, expected once")
            #expect(
                placed.first?.section == section,
                "\(entry.id.rawValue) says \(section.rawValue) but is placed elsewhere")
        }
    }

    /// The other half: a *menu* entry with no catalog row behind it. Nothing can
    /// reach the menu bar that the shortcut reference does not know about.
    @Test("no menu item exists outside the catalog")
    func noMenuItemIsOutsideTheCatalog() {
        for placement in MenuPlan.placements {
            let entry = ActionCatalog.entry(placement.id)
            let says = entry.menu?.rawValue ?? "no menu"
            #expect(
                entry.menu == placement.section,
                "\(placement.id.rawValue) is in \(placement.section.rawValue), catalog says \(says)"
            )
        }
    }

    @Test("no two actions share a chord")
    func noTwoActionsShareAChord() {
        var owners: [KeyChord: [ActionID]] = [:]
        for entry in ActionCatalog.entries {
            for chord in entry.chords { owners[chord, default: []].append(entry.id) }
        }
        for (chord, ids) in owners where ids.count > 1 {
            Issue.record(
                "\(chord.display) is bound to \(ids.map(\.rawValue).joined(separator: ", "))")
        }
        #expect(owners.values.allSatisfy { $0.count == 1 })
    }

    @Test("every entry has a title, and every menu section has entries")
    func theCatalogIsWellFormed() {
        for entry in ActionCatalog.entries {
            #expect(!entry.title.isEmpty, "\(entry.id.rawValue) has no title")
        }
        for section in MenuSection.allCases {
            #expect(!MenuPlan.entries(for: section).isEmpty, "\(section.rawValue) is empty")
        }
    }

    /// A menu that opens with a separator, ends with one, or draws two in a row
    /// looks broken. The plan is data, so this is checkable rather than a thing
    /// to notice by eye.
    @Test("no menu section has a leading, trailing or doubled separator")
    func separatorsAreWellPlaced() {
        for section in MenuSection.allCases {
            let entries = MenuPlan.entries(for: section)
            #expect(entries.first != .separator, "\(section.rawValue) opens with a separator")
            #expect(entries.last != .separator, "\(section.rawValue) ends with a separator")
            for pair in zip(entries, entries.dropFirst()) {
                #expect(
                    !(pair.0 == .separator && pair.1 == .separator),
                    "\(section.rawValue) has two separators in a row")
            }
        }
    }

    /// Spec §6.2's own table, checked against the catalog for the bindings that
    /// have to survive: the ones a user has in their fingers.
    @Test("the spec's headline bindings are what the catalog says")
    func theSpecsBindingsAreHonoured() {
        let expected: [ActionID: String] = [
            // Swapped from §6.2's original pair on the user's instruction: the
            // bare Space is play-from-start, ⇧Space is play/pause.
            .transportPlayPause: "⇧Space",
            .transportReturnToStart: "Space",
            .loopSetIn: "A", .loopSetOut: "S", .loopToggle: "D", .loopRestart: "F",
            .loopFromSelection: "G",
            .nudgeBack: "Z", .nudgeForward: "X",
            .nudgeBackFine: "⇧Z", .nudgeForwardFine: "⇧X",
            .nudgeBackCoarse: "⌥Z", .nudgeForwardCoarse: "⌥X",
            .speedDown: "Q", .speedUp: "W",
            .speedEngineToggle: "⌥E",
            .zoomOut: "E", .zoomIn: "R", .zoomFit: "⌘0", .zoomToSelection: "⌘9",
            .selectionExtendLeft: "⇧←", .selectionExtendRight: "⇧→",
            .selectionSelectAll: "⌘A", .selectionClear: "⎋",
            .selectionMoveLeft: "C", .selectionMoveRight: "V",
            .loopMoveInLeft: "⇧A", .loopMoveOutRight: "⇧F", .loopMoveLeftFar: "⌥⇧C",
            .volumeMute: "M", .fileOpen: "⌘O",
            // Spec §6.2's own. `view.toggleInspector` sat beside it until Task
            // 25 cut the inspector; §6.2 no longer lists it either.
            .helpShortcuts: "⌘/",
            .appSettings: "⌘,"
        ]
        for (id, display) in expected {
            let actual = ActionCatalog.chord(id)?.display ?? "unbound"
            #expect(actual == display, "\(id.rawValue) is \(actual), spec §6.2 says \(display)")
        }
    }
}
