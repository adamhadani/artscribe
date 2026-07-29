import Testing

@testable import ArtscribeUI

/// The open/raise/close rule both auxiliary windows now share.
///
/// It lived on `ShortcutWindowController` until the Practice window was found
/// to have the two defects that controller had already been fixed for — no
/// keyboard focus, and a key that could open the window but never close it —
/// because it had been written as a near-copy *before* either fix existed.
/// Copying the fixes would have left a third window to get wrong.
@MainActor
@Suite("Auxiliary window")
struct AuxiliaryWindowTests {

    @Test("pressing the key while the window is in front puts it away")
    func frontmostCloses() {
        #expect(AuxiliaryWindow.action(isOpen: true, isFrontmost: true) == .close)
    }

    @Test("pressing it while the window is behind raises rather than closes")
    func behindRaises() {
        // Closing here would discard a window the reader cannot see, along with
        // whatever they set up in it, for a key they pressed meaning "show me".
        #expect(AuxiliaryWindow.action(isOpen: true, isFrontmost: false) == .present)
    }

    @Test("a closed window always opens, whatever the frontmost flag claims")
    func closedAlwaysOpens() {
        #expect(AuxiliaryWindow.action(isOpen: false, isFrontmost: false) == .present)
        #expect(AuxiliaryWindow.action(isOpen: false, isFrontmost: true) == .present)
    }

    @Test("the shortcut window's alias still resolves to the shared rule")
    func shortcutControllerDelegates() {
        #expect(ShortcutWindowController.action(isOpen: true, isFrontmost: true) == .close)
        #expect(ShortcutWindowController.action(isOpen: true, isFrontmost: false) == .present)
    }

    @Test("both controllers report not-open before a window exists")
    func noWindowIsNotOpen() {
        #expect(!PracticeWindowController().windowState.isOpen)
        #expect(!ShortcutWindowController(defaults: .standard).windowState.isOpen)
    }
}
