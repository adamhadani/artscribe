import AppKit

/// **The shortcut window's filter is a two-way door.**
///
/// The keyboard goes *into* it with a click and comes back *out* of it with a
/// click elsewhere or with `⎋`. Both halves are needed together and the window
/// shipped twice with only one of them:
///
/// * Task 25 let SwiftUI focus the filter on open. `ModifierMonitor` reads a
///   focused field as "this ⇧ is a capital letter", so the layers the header
///   advertises — "Hold ⇧ ⌥ ⌘" — were dead from the instant the window appeared.
/// * The fix for that took the focus away on open and stopped there, so a
///   single click into the filter put the layers back in the state the first
///   defect had them in, permanently, with no way out. That is the report this
///   file exists to answer: *"once i do i cant seem to 'unfocus' it"*.
///
/// The policy is stated here as pure functions so it can be tested without a
/// window, and `ShortcutFocusMonitor` below is the thin AppKit shell that
/// applies it.
public enum FilterFocus {

    /// What a press or a click should do to the filter's focus.
    public enum Action: Equatable, Sendable {
        /// Empty the filter and keep the caret in it.
        case clearTheFilter
        /// Give the keyboard back to the window.
        case releaseTheKeyboard
        /// Not ours: leave the event to whatever wanted it.
        case passItOn
    }

    /// **`⎋` clears first and releases second.**
    ///
    /// The two-step is the convention every filter field on this platform uses
    /// — Xcode's jump bar filter, Safari's find bar, Finder's search — and it is
    /// the right one here for a reason specific to this window: the filter also
    /// quiets every key on the drawn keyboard that is not a match, so a filter
    /// with text in it is a *view* of the keymap and not merely a caret
    /// position. Releasing the keyboard while "loop" is still narrowing the
    /// board would leave the reader looking at a filtered reference with no
    /// visible reason why, and pressing `⎋` again — the reflex — would then
    /// clear the audio selection in the window behind.
    ///
    /// So: the first `⎋` undoes the filtering, the second gives the keyboard
    /// back. An empty filter releases on the first press, because there is
    /// nothing to undo.
    public static func escape(isFocused: Bool, text: String) -> Action {
        guard isFocused else { return .passItOn }
        return text.isEmpty ? .releaseTheKeyboard : .clearTheFilter
    }

    /// **A click that is not on the field takes the keyboard off it.**
    ///
    /// "Focus follows the click" is what the user asked for and what AppKit
    /// would already do if this window's panes were `NSView`s that accepted
    /// first responder. They are not — SwiftUI draws the whole window inside one
    /// hosting view — so clicking the drawn keyboard resigns nothing and the
    /// field editor keeps the keyboard forever.
    public static func click(isFocused: Bool, insideField: Bool) -> Action {
        isFocused && !insideField ? .releaseTheKeyboard : .passItOn
    }
}

/// Applies `FilterFocus` to one real window.
///
/// A **local event monitor**, following `TrackpadMonitor` and `ModifierMonitor`,
/// and for the same reason as both: the thing that has to be observed — a click
/// landing somewhere SwiftUI draws but does not make focusable — has no SwiftUI
/// vocabulary at all. A monitor sees the event before `NSWindow.sendEvent`
/// dispatches it, which is also what lets `⎋` be answered here rather than by
/// the Edit menu's `Clear Selection`, whose key equivalent it also is.
///
/// **Owned by `ShortcutWindowController`, not by the view.** The view's
/// `onAppear` runs once; the window is closed and reopened, and SwiftUI hands
/// the `TextField` first responder *every* time it reopens — measured, as a
/// window that opened unfocused the first time and focused every time after.
/// A monitor whose lifetime is the view's would have covered only the first.
@MainActor
final class ShortcutFocusMonitor {
    private weak var window: NSWindow?
    /// `nonisolated(unsafe)` for the reason `KeyWindowTracker`'s observer tokens
    /// are: `deinit` is not main-actor isolated and has to hand these back. They
    /// are only ever written on the main actor, and by the time `deinit` reads
    /// them no other reference survives, so there is nothing to race.
    private nonisolated(unsafe) var monitor: Any?
    private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []
    /// Emptied by whoever owns the filter's text. Returns what is in it.
    private var filter: (() -> String)?
    private var clearFilter: (() -> Void)?

    /// **Whether the reader has touched this window since it opened.**
    ///
    /// Until they have, the filter is not allowed to hold the keyboard: SwiftUI
    /// gives a `TextField` first responder as soon as the scene appears, and
    /// this window is a thing you *read* far more often than a thing you type
    /// into. After the first click or keystroke the reader is driving and
    /// nothing here takes focus away from them again.
    private var readerHasActed = false

    /// **How many times the opening release may fire before it gives up.**
    ///
    /// The budget is the whole safety of that mechanism and is not a tidiness
    /// measure. `makeFirstResponder(nil)` dirties the window, a dirty window
    /// posts another `didUpdate`, and if a future SwiftUI ever re-focused the
    /// field after each release the pair would spin at event-loop speed — a
    /// hang, not a bug you would see. One release is what a measured run
    /// actually needs; eight is room for the layout to settle, and running out
    /// degrades to a window that opens focused, which is what shipped before.
    private var releasesLeft = 0
    private static let releaseBudget = 8

    /// - Parameters:
    ///   - filter: what the filter currently holds, read at the moment `⎋` is
    ///     pressed rather than cached.
    ///   - clearFilter: empties it.
    func start(
        window: NSWindow, filter: @escaping () -> String, clearFilter: @escaping () -> Void
    ) {
        stop()
        self.window = window
        self.filter = filter
        self.clearFilter = clearFilter
        rearm()

        // Re-armed on every close, because the next open is a fresh window as
        // far as the reader is concerned even when AppKit reuses the object.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rearm()
                    window.makeFirstResponder(nil)
                }
            })
        // `didUpdate` is posted once per pass of the event loop for a window on
        // screen, which is the only hook that fires *after* SwiftUI has assigned
        // its initial focus without guessing at how long that takes. It stops
        // costing anything the moment the reader clicks.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseUntouchedFilter() }
            })

        let matching: NSEvent.EventTypeMask = [.leftMouseDown, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: matching) { [weak self] event in
            // A `Bool` crosses back out rather than the event, which is not
            // `Sendable` and so cannot be the result of `assumeIsolated` —
            // exactly as `TrackpadMonitor` records. AppKit dispatches local
            // monitors on the main thread.
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                self?.handle(event) ?? false
            }
            return swallowed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        window = nil
        filter = nil
        clearFilter = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// `true` swallows the event; `false` passes it on.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        readerHasActed = true
        let isFocused = TextFocus.editor(in: window) != nil
        switch event.type {
        case .keyDown where event.keyCode == Self.escapeKeyCode:
            return apply(FilterFocus.escape(isFocused: isFocused, text: filter?() ?? ""), to: event)
        case .leftMouseDown:
            let inside = TextFocus.editedField(in: window).map {
                TextFocus.isInside(event.locationInWindow, of: $0)
            }
            return apply(
                FilterFocus.click(isFocused: isFocused, insideField: inside ?? false), to: event)
        default:
            return false
        }
    }

    private func apply(_ action: FilterFocus.Action, to event: NSEvent) -> Bool {
        switch action {
        case .passItOn:
            return false
        case .clearTheFilter:
            clearFilter?()
            return true
        case .releaseTheKeyboard:
            window?.makeFirstResponder(nil)
            // A click still has to reach the window: it may be the start of a
            // divider drag or a press on the layer picker, and swallowing it
            // would make the first click after typing do nothing at all. `⎋` is
            // swallowed, because it has been answered.
            return event.type != .leftMouseDown
        }
    }

    private func rearm() {
        readerHasActed = false
        releasesLeft = Self.releaseBudget
    }

    private func releaseUntouchedFilter() {
        guard !readerHasActed, releasesLeft > 0, let window,
            TextFocus.editor(in: window) != nil
        else { return }
        releasesLeft -= 1
        window.makeFirstResponder(nil)
    }

    private static let escapeKeyCode: UInt16 = 53
}
