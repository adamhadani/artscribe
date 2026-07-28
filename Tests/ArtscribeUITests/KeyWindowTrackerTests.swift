import AppKit
import Testing

@testable import ArtscribeUI

/// The rule that makes the menu's plain-letter key equivalents safe: they stand
/// down while some *other* window is taking keystrokes, because AppKit offers a
/// key equivalent to the menu before it offers the event to a focused text
/// field.
///
/// Tested as a pure function against plain objects rather than through
/// `NSApp.keyWindow`, so it can be driven into all four states — including the
/// two the acceptance run cannot reach on a machine where no window can become
/// key.
@Suite("Plain-letter shortcut guard")
struct KeyWindowTrackerTests {

    private final class Window {}

    @Test("the shortcuts are ours while the document window is taking keys")
    func documentKey() {
        let document = Window()
        #expect(KeyWindowTracker.documentIsKey(key: document, document: document))
    }

    @Test("they stand down while another window is taking keys")
    func otherWindowKey() {
        // The case that matters: Settings, whose numeric fields must receive the
        // digits and letters typed into them.
        #expect(!KeyWindowTracker.documentIsKey(key: Window(), document: Window()))
    }

    @Test("with nothing taking keys there is nothing to protect")
    func noKeyWindow() {
        // A menu key equivalent still fires with no key window, and a text field
        // cannot hold focus without one — so refusing here would only break the
        // keyboard on a machine where no window can become key.
        #expect(KeyWindowTracker.documentIsKey(key: nil, document: Window()))
        #expect(KeyWindowTracker.documentIsKey(key: nil, document: nil))
    }

    @Test("before the first layout pass the shortcuts still work")
    func noDocumentAdoptedYet() {
        // The app has exactly one window at launch and it is the document; a
        // guard that refused until `WindowReader` had run would make the
        // keyboard dead for the first frames.
        #expect(KeyWindowTracker.documentIsKey(key: Window(), document: nil))
    }
}
