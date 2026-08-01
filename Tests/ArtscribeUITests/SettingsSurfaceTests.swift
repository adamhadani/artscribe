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
