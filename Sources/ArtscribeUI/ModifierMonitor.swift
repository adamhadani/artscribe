import AppKit

extension KeyModifiers {
    /// The four modifiers this app binds, taken out of an AppKit flags mask.
    ///
    /// The sibling of `fromEvent(_:)`, which does the same job for SwiftUI's
    /// `EventModifiers`, and it exists for the same reason: a real mask carries
    /// members nothing here binds. `.capsLock` is set on *everything* while
    /// Caps Lock is down and `.function` on every arrow, so a mask compared
    /// as-is against a layer would never match one.
    ///
    /// `⌃` is kept rather than dropped, unlike `fromEvent`: there it is dropped
    /// so a hand resting on the key cannot make the plain actions unreachable,
    /// but here the mask is a *question* — "which layer am I looking at" — and
    /// answering `⌃` with the base layer would claim `Z` nudges when `⌃Z` does
    /// nothing.
    static func fromFlags(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

/// Reports which modifiers are being **held right now**, so the drawn keyboard
/// can change layer as you press.
///
/// A *local* event monitor, following `TrackpadMonitor`: SwiftUI has no way to
/// observe a bare modifier press — `onKeyPress` needs a key, and `.onModifierKeysChanged`
/// only fires while a gesture is in flight — and an `NSView` wrapper would have
/// to be first responder, which the search field needs to be.
///
/// **A press that is being typed into a field is not a layer change.** Holding
/// ⇧ to type a capital `L` into the filter must not flip the keyboard to the
/// shifted layer; the field editor is an `NSTextView`, and its presence in the
/// responder chain is what tells the two apart. Without this the window
/// visibly strobes while you type, which was the first thing this got wrong.
///
/// **That rule is why the shortcut window's filter is a two-way door.** SwiftUI
/// hands the `TextField` first responder as soon as the window exists, and this
/// test cannot tell that apart from someone mid-word — so with the field focused
/// from the start, "Hold ⇧ ⌥ ⌘" was dead the whole time the window was key, and
/// with no way back out of the field it stayed dead after the first click. Both
/// halves are `ShortcutFocusMonitor`'s, and all three have to be read together:
/// narrow this and the strobe comes back; let the field keep the keyboard and
/// the layers go away again.
@MainActor
final class ModifierMonitor {
    private var monitor: Any?

    /// - Parameter onChange: called with the new set only when it actually
    ///   moves. AppKit sends `.flagsChanged` for keys this app does not read,
    ///   and re-reporting an unchanged value would invalidate the whole
    ///   keyboard on every Caps Lock press.
    func start(onChange: @escaping @MainActor (KeyModifiers) -> Void) {
        guard monitor == nil else { return }
        var last: KeyModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                let held = Self.isTyping(event) ? [] : KeyModifiers.fromFlags(event.modifierFlags)
                if held != last {
                    last = held
                    onChange(held)
                }
            }
            // Purely an observer. The event goes on to whatever wanted it —
            // swallowing it here would break every other modifier in the app.
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether this modifier press belongs to text being typed.
    ///
    /// One line, because the rule itself lives in `TextFocus` — the same rule
    /// `⌘A` and the shortcut window's click-to-unfocus turn on, and a rule
    /// spelled three ways is a rule that drifts.
    private static func isTyping(_ event: NSEvent) -> Bool {
        TextFocus.editor(in: event.window ?? NSApp?.keyWindow) != nil
    }
}
