import AppKit
import Foundation
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

    /// The `NSWindow`, reported by the view once it is in one.
    ///
    /// Held rather than looked up by title for the reason
    /// `AcceptanceCatalogChecks` records about the *document* window: a title is
    /// not an identity. Weak, because the window is owned by its scene and
    /// closing it must not be prevented by this reference.
    ///
    /// `@ObservationIgnored` for the same reason `present` is — it is plumbing,
    /// and a view that observed it would re-render every time the window was
    /// created.
    @ObservationIgnored public weak var window: NSWindow?

    private static let listWidthKey = "shortcutWindow.listWidth"

    @ObservationIgnored private let defaults: UserDefaults

    /// The width the reader dragged the divider to — **is** persisted, unlike
    /// the filter and the pinned layer above.
    ///
    /// The difference is deliberate rather than an inconsistency. Those two are
    /// a *view* of the keymap that should reset every time the window opens;
    /// this is furniture, in the same class as the window frame that
    /// `setFrameAutosaveName` already remembers a line away from here. A reader
    /// who widened the list to fit "Move Loop Out Right (Far) 2 s" on one line
    /// has to do it again on every launch otherwise.
    ///
    /// Stored raw and clamped at use (`ShortcutSplit.listWidth`), so a value
    /// saved against a wide window cannot crush the keyboard on a narrow one.
    public var listWidth: Double {
        didSet {
            guard listWidth != oldValue else { return }
            defaults.set(listWidth, forKey: Self.listWidthKey)
        }
    }

    /// - Parameter defaults: injectable for the same reason `ThemeController`'s
    ///   is — a test and the acceptance harness get their own suite instead of
    ///   rewriting the split the user left the real app in.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.listWidthKey) as? Double
        listWidth = stored ?? ShortcutSplit.defaultListWidth
    }

    /// `⌘/`, and **View ▸ Keyboard Shortcuts**.
    ///
    /// **Show it if you cannot use it; put it away if you can.** Measured, not
    /// assumed: `openWindow(id:)` *does* bring an already-open window forward
    /// (a run pushed the document in front and watched the shortcut window come
    /// back to the top on the next `show()`), so the only state where `⌘/` did
    /// nothing at all was the one where the window was already frontmost — and
    /// that is exactly the state the user pressed it in.
    ///
    /// So the third behaviour is closing, and only from the front. Closing a
    /// window that is *behind* the viewer would be the surprising reading: the
    /// key was pressed to see the reference, the reference is not what you are
    /// looking at, and the natural answer to "show me" is to raise it — while a
    /// close from there would throw away a window you cannot see, along with the
    /// filter and the divider you set in it, with no visible cause. Task 25's
    /// original argument against toggling — that the inspector had to close
    /// because it stole width from the waveform — was an argument against
    /// closing *reflexively*, and it still holds for the behind case.
    public func toggle() {
        switch Self.action(isOpen: window?.isVisible == true, isFrontmost: isFrontmost) {
        case .close:
            // `performClose`, not `close`: it is what the close button and ⌘W
            // do, so all three routes out of this window are one path.
            window?.performClose(nil)
        case .present:
            show()
        }
    }

    /// What `⌘/` should do, as a pure function of the two facts it turns on.
    ///
    /// Split out because the interesting half of it — a window that is open and
    /// *behind* — cannot be produced on a screen-locked login session, where no
    /// window can become key at all.
    public enum Action: Equatable, Sendable {
        case present
        case close
    }

    public nonisolated static func action(isOpen: Bool, isFrontmost: Bool) -> Action {
        isOpen && isFrontmost ? .close : .present
    }

    /// Opens it, brings it forward, and gives it the keyboard.
    ///
    /// The last of those is not what `openWindow(id:)` alone was doing for the
    /// user: without a key window the filter field cannot take a keystroke, so
    /// `⌘C` and `⌘V` — which this app sends down the *key* window's responder
    /// chain, having replaced the standard pasteboard group — reached nothing.
    /// Asking AppKit directly costs one line and removes the dependency on what
    /// SwiftUI happens to do about activation.
    public func show() {
        present?()
        focus()
    }

    /// `makeKeyAndOrderFront` on the next turn of the run loop when the window
    /// does not exist yet: `present?()` creates it, and the view inside it does
    /// not report the `NSWindow` back until it has been laid out.
    private func focus() {
        NSApp?.activate()
        guard let window else {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Whether this window is the one in front of the reader.
    ///
    /// `isKeyWindow` is the honest test and the one that runs on a real
    /// machine. The fallback exists because agents drive this app on a
    /// screen-locked login session where **no** window can become key — the
    /// same fact `KeyWindowTracker.forcedDocumentIsKey` was added for — and
    /// without it `⌘/` would there be a key that could open the window and never
    /// close it, which is the defect this method exists to fix.
    private var isFrontmost: Bool {
        guard let window, window.isVisible else { return false }
        if window.isKeyWindow { return true }
        guard NSApp?.keyWindow == nil else { return false }
        return NSApp?.orderedWindows.first { $0.isVisible } === window
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
