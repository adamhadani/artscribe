#if os(macOS)

import AppKit

/// **Where the keyboard is going: into text, or into the app.**
///
/// One rule, in one place, because three separate things turn on it and they
/// were each spelling it out for themselves:
///
/// * `ModifierMonitor` — a held ⇧ is a capital letter, not a layer change.
/// * `ActionInvokerTable` — `⌘A` means *this field's text* while a field is
///   being edited, and *the whole track* otherwise.
/// * `ShortcutFocusMonitor` — a click outside the field being edited gives the
///   keyboard back to the window.
///
/// The test is the **field editor**, not SwiftUI's `@FocusState`. They are not
/// the same mechanism and only one of them is observable from outside the view
/// that declares it: a `TextField` on macOS is drawn by an `NSTextField`, and
/// while it is being edited AppKit installs a shared `NSTextView` — the field
/// editor — as the window's first responder. Measured in this app: the shortcut
/// window's first responder while its filter is focused is
/// `_SystemTextFieldFieldEditor`, an `NSTextView`, whose `delegate` is the
/// `NSTextField` it is editing.
@MainActor
enum TextFocus {

    /// The field editor holding the keyboard in `window`, if one is.
    static func editor(in window: NSWindow?) -> NSTextView? {
        window?.firstResponder as? NSTextView
    }

    /// The control that field editor is editing.
    ///
    /// `delegate`, not a walk up `superview`: AppKit sets the edited
    /// `NSTextField` as its field editor's delegate for exactly the duration of
    /// the editing session, so this is `nil` the moment editing ends and is not
    /// a guess about view nesting. Measured against SwiftUI's own text field,
    /// whose editor's delegate is an `NSTextField` subclass.
    static func editedField(in window: NSWindow?) -> NSView? {
        editor(in: window)?.delegate as? NSView
    }

    /// Whether the application's keystrokes are currently going into text.
    ///
    /// Reads the **key** window, which is the one AppKit is sending keys to. A
    /// field left focused in a window that is no longer key is not typing.
    static var isEditingText: Bool {
        editor(in: NSApp?.keyWindow) != nil
    }

    /// Whether a click at `point` (window coordinates) landed on `field`.
    ///
    /// A frame comparison rather than a `hitTest` ancestry check, and that is
    /// not a shortcut: SwiftUI draws a whole window inside **one**
    /// `NSHostingView`, so `hitTest` over the drawn keyboard returns a view the
    /// field editor is a descendant of — measured — and every click would read
    /// as a click on the field.
    static func isInside(_ point: NSPoint, of field: NSView) -> Bool {
        guard let container = field.superview else { return false }
        return container.convert(field.frame, to: nil).contains(point)
    }
}

#endif
