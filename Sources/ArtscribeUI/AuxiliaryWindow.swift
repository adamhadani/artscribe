import Foundation

#if os(macOS)
import AppKit
#endif

/// Opening, raising, focusing and closing an auxiliary window — the behaviour
/// the shortcut window and the Practice window share.
///
/// **Extracted rather than copied a second time.** `PracticeWindowController`
/// was written as a deliberate near-copy of `ShortcutWindowController`, and
/// then the shortcut window was fixed twice — once because `openWindow(id:)`
/// alone never gives the window the keyboard, so its text field could not take
/// `⌘C`/`⌘V`, and once because `⌘/` could open the window and never close it.
/// The Practice window still had both defects. Copying the fixes across would
/// have made it a near-copy of a bug fix, and left a third window to get wrong.
///
/// Each controller keeps its own state — the shortcut window's filter, pinned
/// layer and divider width have no counterpart here — and holds one of these
/// for the window itself.
@MainActor
public final class AuxiliaryWindow {

    /// What a toggle key should do, as a pure function of the two facts it
    /// turns on. Split out because the interesting case — open but *behind* —
    /// cannot be produced on a screen-locked login session, where no window can
    /// become key at all.
    public enum Action: Equatable, Sendable {
        case present
        case close
    }

    /// **Show it if you cannot use it; put it away if you can.**
    ///
    /// Measured, not assumed: `openWindow(id:)` *does* raise an already-open
    /// window, so the only state where the key did nothing was the one where the
    /// window was already frontmost — which is exactly the state a user presses
    /// it in. Closing a window that is *behind* would be the surprising reading:
    /// the key was pressed to see the thing, the thing is not what you are
    /// looking at, and the natural answer is to raise it.
    public nonisolated static func action(isOpen: Bool, isFrontmost: Bool) -> Action {
        isOpen && isFrontmost ? .close : .present
    }

    /// Installed by the scene, because `openWindow(id:)` is an
    /// `EnvironmentValues` member reachable only from inside a `View` body while
    /// `ActionInvoker`'s table is deliberately not a view.
    public var present: (@MainActor () -> Void)?

    #if os(macOS)

    /// The `NSWindow`, reported by the view once it is in one. Held rather than
    /// looked up by title, because a title is not an identity. Weak: the window
    /// is owned by its scene and closing it must not be prevented by this.
    public weak var window: NSWindow?

    public init() {}

    public var isOpen: Bool { window?.isVisible == true }

    /// Opens it, brings it forward, and **gives it the keyboard**.
    ///
    /// The last of those is what `openWindow(id:)` alone does not do: without a
    /// key window a text field cannot take a keystroke, and `⌘C`/`⌘V` — which
    /// this app sends down the *key* window's responder chain, having replaced
    /// the standard pasteboard group — reach nothing.
    public func show() {
        present?()
        // `ignoringOtherApps` because a plain `activate()` silently does nothing
        // when the caller is not already the active app — which is how every
        // agent-driven run reaches this, and why the focus defects went
        // unverified for so long.
        NSApp?.activate(ignoringOtherApps: true)
        guard let window else {
            // `present?()` creates the window, but the view inside it does not
            // report the `NSWindow` back until it has been laid out.
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        window.makeKeyAndOrderFront(nil)
    }

    public func toggle() {
        switch Self.action(isOpen: isOpen, isFrontmost: isFrontmost) {
        case .close:
            // `performClose`, not `close`: it is what the close button and ⌘W
            // do, so every route out of the window is one path.
            window?.performClose(nil)
        case .present:
            show()
        }
    }

    /// Whether this window is the one in front of the reader.
    ///
    /// `isKeyWindow` is the honest test. The fallback exists because agents
    /// drive this app on a screen-locked login session where **no** window can
    /// become key, and without it the toggle would there be a key that opens the
    /// window and never closes it — the defect this type exists to fix.
    public var isFrontmost: Bool {
        guard let window, window.isVisible else { return false }
        if window.isKeyWindow { return true }
        guard NSApp?.keyWindow == nil else { return false }
        return NSApp?.orderedWindows.first { $0.isVisible } === window
    }

    #else

    // MARK: - iOS: the same behaviour, presented as a sheet
    //
    // Everything above is one idea — *is this thing in front of the reader, and
    // what should the toggle key do about it* — expressed in the only vocabulary
    // macOS has for it. On iPad a sheet is the whole answer: it is either
    // presented or it is not, and a presented sheet is by definition the thing in
    // front of you. So `isFrontmost` collapses into `isOpen`, and with it the
    // entire screen-locked fallback that exists on macOS because no window can
    // become key there.
    //
    // `action(isOpen:isFrontmost:)` above is shared and unchanged, which is the
    // point of it having been a pure function: the *rule* — show it if you cannot
    // use it, put it away if you can — is not platform-specific, only the two
    // facts it reads are.

    /// Whether the sheet is up. The view binds a `.sheet(isPresented:)` to this.
    ///
    /// Not yet observed by anything: the sheets themselves are the next piece of
    /// work, and until a view binds to it this is state with no reader. Wiring
    /// that up needs it to be observable — see the note in `#58`.
    public var isPresented = false

    public init() {}

    public var isOpen: Bool { isPresented }

    /// No activation, no key window, no ordering: presenting a sheet is the whole
    /// of "show it" on iPad, and it comes with the keyboard for free.
    public func show() {
        present?()
        isPresented = true
    }

    public func toggle() {
        switch Self.action(isOpen: isOpen, isFrontmost: isFrontmost) {
        case .close: isPresented = false
        case .present: show()
        }
    }

    /// A presented sheet is always the frontmost thing. See the note above.
    public var isFrontmost: Bool { isPresented }

    #endif
}
