import SwiftUI

/// The **Loop** menu — the app's signature feature, given its own place in the
/// menu bar.
///
/// It was the last block of a 36-item Playback menu, which is where a feature
/// goes to be undiscoverable: looping a passage is the reason this app exists,
/// and `A`/`S`/`D`/`F`/`G` are the five keys a new user most needs to find. It
/// is also where the Practice hub (speed-ramping repetitions) lands later, so
/// the menu has somewhere to grow that is not "the bottom of Playback".
///
/// A `CommandMenu`, unlike `EditCommands`: macOS builds no Loop menu of its
/// own, so there is nothing to merge with and nothing to duplicate.
///
/// **The keys, and why they are these.** `A S D F` is the loop row and already
/// reads left to right: the *left* pair drives the loop's *left* (in) edge and
/// the *right* pair its *right* (out) edge, and within each pair the left key
/// moves left. `⇧` is what turns "set this edge at the playhead" into "nudge it
/// from where it is". `⇧C`/`⇧V` then move the whole loop, on the very keys that
/// already move the whole selection — the keyboard equivalent of the loop body
/// Task 23 made draggable, and of the selection body it deliberately did not.
/// `⌥` still means "the bigger step", exactly as it does for `⌥Z`/`⌥X`,
/// `⌥←`/`⌥→` and `⌥C`/`⌥V`, so it *adds* to the chord rather than replacing the
/// `⇧`.
///
/// The twelve move items are declared for the menu's sake — the right-aligned,
/// system-drawn shortcut is how a user finds them — but `NSMenu` matches a key
/// equivalent against a **lowercase** `charactersIgnoringModifiers`, so a `⇧A`
/// arriving as "A" is not claimed by the menu at all. `KeyBindings` answers for
/// every one of them from the window, exactly as it does for `⇧Z`/`⇧X` and
/// `⇧Q`/`⇧W`.
public struct LoopCommands: Commands {
    private let context: MenuContext

    public init(context: MenuContext) {
        self.context = context
    }

    public var body: some Commands {
        CommandMenu("Loop") {
            MenuItems(section: .loop, context: context)
        }
    }
}
