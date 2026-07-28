import Observation

/// The shortcut window's state, and the one way to open it.
///
/// A small standalone `@Observable`, following `ThemeController`: the window is
/// a property of the *application* rather than of the loaded track, and the View
/// menu, the `⌘/` binding and the window itself all have to reach the same one.
///
/// **Why it holds a closure.** Opening a SwiftUI `Window` scene means calling
/// `openWindow(id:)`, which is an `EnvironmentValues` member and therefore only
/// reachable from inside a `View` body — and `ActionInvoker`'s table is not a
/// view, on purpose (it is the one place every action is implemented, reached
/// identically from a menu item, a key press and later a MIDI note). So the
/// scene hands its `openWindow` over once, on appear, and the action calls it.
/// The alternative — a `Bool` the scene watches — cannot open a `Window` scene
/// at all, and hunting for the `NSWindow` by title would break the moment the
/// window has never been opened.
@MainActor
@Observable
public final class ShortcutWindowController {
    /// The scene id, and the `NSWindow` frame-autosave name. One constant so
    /// the scene, the opener and the harness cannot disagree about which window
    /// is meant.
    public static let windowID = "shortcuts"

    /// The filter over both the keyboard and the list. Not persisted: a filter
    /// left in from last week would open the window showing four actions and no
    /// obvious reason why.
    public var query: String = ""

    /// The layer shown when no modifier is being held.
    ///
    /// This is the accessibility half of the modifier layers: holding `⌥⇧` to
    /// see the far-move bindings is not something everyone can do, so a layer
    /// can be chosen from the picker and stays chosen. Also not persisted — the
    /// window opens on the base layer, which is what "what do the keys do"
    /// means with nothing held.
    public var pinnedLayer: KeyModifiers = []

    /// Installed by the scene. `@ObservationIgnored` because nothing observes
    /// it: it is plumbing written once at launch, and tracking it would make
    /// every view that can open the window depend on the act of installing it.
    @ObservationIgnored public var present: (@MainActor () -> Void)?

    public init() {}

    /// `⌘/`, and **View ▸ Keyboard Shortcuts**.
    ///
    /// Opens, and brings forward if it is already open — which is what
    /// `openWindow(id:)` does for an existing `Window` scene. Deliberately
    /// *not* a toggle: the inspector's `⌘/` closed itself again because it took
    /// width from the waveform and there was no other way to put it back. A
    /// separate window costs the document nothing, has a close button and
    /// answers ⌘W, so a key that also closed it would be a third behaviour for
    /// no gain.
    public func show() {
        present?()
    }

    /// Pins a layer, comparing first.
    ///
    /// The comparison is not decoration: this is called from a `Picker`'s
    /// binding, and assigning an `@Observable` property the value it already
    /// holds is compared and stays silent — but only because this is a plain
    /// assignment. See the `_modify` note in `CLAUDE.md` for the case where it
    /// is not.
    public func pin(_ layer: KeyModifiers) {
        guard layer != pinnedLayer else { return }
        pinnedLayer = layer
    }
}
