import Testing

@testable import ArtscribeUI

/// Where Settings lives, per platform.
///
/// The failure this guards is the one that shipped: on iPad `⌘,` reached
/// nothing, the system's own Settings item went to an empty page in the Settings
/// app, and every preference the Mac has was unreachable. Nothing errored, so
/// nothing said so.
///
/// **What is not covered here.** `AuxiliaryWindow` has two implementations, and
/// the sheet half — `isPresented`, which is what `⌘,` toggles on iPad — exists
/// only on iOS. A test of it would compile out of `make check` and would not run
/// in `make ios-test` either, since `ArtscribeUITests` is not in the portable
/// bundle. A test that never executes is worse than none, so the toggle
/// behaviour is left to `AuxiliaryWindowTests` (which covers the shared state
/// machine) and to testing on a device.
@Suite("Settings surface")
@MainActor
struct SettingsSurfaceTests {

    /// macOS must **not** have an entry: SwiftUI's `Settings` scene owns the
    /// menu item and `⌘,` there, and a second opener in this table would be a
    /// rival to it. iOS must have one, because no such scene exists.
    ///
    /// Only the macOS half of this assertion actually runs today, and it is
    /// still the more valuable half — it is the one that would catch somebody
    /// "fixing" the missing entry by adding it unconditionally.
    @Test("the action is wired on iOS and left to the Settings scene on macOS")
    func wiredOnlyWhereThereIsNoSettingsScene() {
        let entry = ActionInvoker.applicationActions[.appSettings]
        #if os(macOS)
        #expect(entry == nil, "macOS should leave ⌘, to the Settings scene")
        #else
        #expect(entry != nil, "iPad has no Settings scene, so nothing would open")
        #endif
    }

    /// In the catalog on **both** platforms regardless of who opens it: the
    /// shortcut reference is generated from the catalog, and an action missing
    /// from it is missing from the reference.
    @Test("the action is in the catalog on both platforms")
    func alwaysInTheCatalog() {
        #expect(ActionCatalog.entries.contains { $0.id == .appSettings })
    }
}

/// The iPad answer to `KeyWindowTracker`: while a sheet is up, the document
/// stops claiming the menu's plain-letter key equivalents.
///
/// The bug this guards shipped and came back from TestFlight: with Settings
/// open, typing `1` into a nudge field set the speed to 100% instead. Almost
/// every digit and letter is bound, so numeric entry was impossible.
///
/// Written against `SheetFocus` rather than the live controllers so it **runs**:
/// the sheet state it stands in for exists only on iOS, and this suite is not in
/// the portable bundle, so a test of the objects would execute on no platform
/// at all.
@Suite("Sheets take the keyboard")
struct SheetFocusTests {

    @Test("with nothing presented the document keeps the keyboard")
    func documentKeepsItWhenNothingIsUp() {
        #expect(
            SheetFocus.documentHasKeyboard(
                shortcutsPresented: false, practicePresented: false,
                aboutPresented: false, settingsPresented: false))
    }

    /// **Each surface independently.** The failure this catches is a new sheet
    /// being added to `DocumentView` and not to the aggregate, which
    /// reintroduces the bug silently and for that sheet only.
    @Test("every auxiliary sheet suppresses the document on its own")
    func eachSheetSuppressesTheDocument() {
        // One flag raised at a time, named so a failure says which surface.
        let raised: [(name: String, index: Int)] = [
            ("shortcuts", 0), ("practice", 1), ("about", 2), ("settings", 3)
        ]
        for surface in raised {
            var flags = [false, false, false, false]
            flags[surface.index] = true
            #expect(
                !SheetFocus.documentHasKeyboard(
                    shortcutsPresented: flags[0], practicePresented: flags[1],
                    aboutPresented: flags[2], settingsPresented: flags[3]),
                "\(surface.name) did not take the keyboard")
        }
    }

}
