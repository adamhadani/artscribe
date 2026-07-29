import AppKit
import Observation
import SwiftUI

/// Whether the document window is the one receiving keystrokes.
///
/// It exists because the menu carries **plain-letter key equivalents** (`Q`, `W`,
/// `A`–`G`, `1`–`4`, Space, `C`/`V`, `Esc`). AppKit offers a key event to the main menu
/// *before* the key window's first responder, so a live plain `Q` would step the
/// playback speed instead of typing a digit into Settings' nudge fields. A
/// disabled menu item claims nothing, so disabling the transport menus while
/// another window is key is what hands the keystroke back to the text field.
///
/// The condition is deliberately **permissive when nothing is key**: a menu key
/// equivalent still works with no key window at all, and a text field cannot
/// have focus without one, so there is nothing to protect in that state. Being
/// permissive there also keeps the app usable on a machine where no window can
/// become key — which is the state the acceptance harness runs in when the login
/// session's screen is locked.
@MainActor
@Observable
public final class KeyWindowTracker {

    /// Application-global because it tracks an application-global fact — which
    /// window `NSApp` is sending keys to. Following `OutputAudibility.shared`:
    /// one owner, no plumbing through four initialisers to reach the two menus
    /// that need it.
    public static let shared = KeyWindowTracker()

    /// True when a plain-letter menu key equivalent is safe to claim.
    public private(set) var documentIsKey = true

    /// Forces the answer, for the acceptance run only. Never set by the app.
    ///
    /// It exists because the state this guard protects against — *another*
    /// window holding the keyboard — cannot be produced on a machine whose login
    /// session is screen-locked: no window there can become key at all. Without
    /// a seam, the one remedy in this task would be the one thing in it that
    /// nothing ever exercised. With it, the run drives the guard into its "some
    /// other window is key" state and checks that the transport items really do
    /// go dead and really do stop firing.
    public var forcedDocumentIsKey: Bool? {
        didSet { refresh() }
    }

    @ObservationIgnored private weak var document: NSWindow?
    /// `nonisolated(unsafe)` for the same reason `ThemeController`'s observer
    /// token is: `deinit` is not main-actor isolated and has to hand these back.
    /// They are written once during `init` and read once during `deinit`, by
    /// which point no other reference survives, so there is nothing to race.
    @ObservationIgnored private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []

    public init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Told which window the transport belongs to, by the view that lives in it.
    public func adopt(document window: NSWindow?) {
        guard window !== document else { return }
        document = window
        refresh()
    }

    /// The document window itself, for the one caller that needs the object and
    /// not the verdict: `TrackpadMonitor`, whose anchor is hit-tested against
    /// this window's content view and so must resolve to it even for an event
    /// that arrived carrying no window of its own.
    public var documentWindow: NSWindow? { document }

    /// Whether an event that arrived in `window` belongs to the document.
    ///
    /// **Permissive before the first layout pass**, exactly as `documentIsKey`
    /// is and for the same reason: `adopt(document:)` is called by a
    /// `WindowReader` inside the view, so until it runs the app has one window
    /// and it is this one. A rule that refused there would make the scroll and
    /// pinch gestures dead for the first frames after launch.
    public func isDocument(_ window: NSWindow) -> Bool {
        guard let document else { return true }
        return window === document
    }

    /// Compared before assigning: this runs on every window activation in the
    /// process, and an unconditional write would invalidate both menus' items
    /// each time (see CLAUDE.md on `@Observable` and `_modify`).
    private func refresh() {
        let next =
            forcedDocumentIsKey
            ?? Self.documentIsKey(key: NSApp?.keyWindow, document: document)
        if next != documentIsKey { documentIsKey = next }
    }

    /// The rule, as a pure function so it can be tested without an `NSApp`.
    ///
    /// - `nil` key window: nothing is taking keystrokes, so nothing is at risk.
    /// - no document window adopted yet: the app has one window and it is this
    ///   one; refusing the shortcuts before the first layout pass would break
    ///   the keyboard at launch.
    /// - otherwise: only when the key window *is* the document window.
    public nonisolated static func documentIsKey(key: AnyObject?, document: AnyObject?) -> Bool {
        guard let key else { return true }
        guard let document else { return true }
        return key === document
    }
}

/// Reports the window a SwiftUI view ended up in.
///
/// `NSViewRepresentable` rather than anything in SwiftUI's own vocabulary
/// because there is none: a view cannot ask for its `NSWindow`, and the answer
/// is what `KeyWindowTracker` needs in order to tell this window from Settings.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReportingView(onWindow: onWindow) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReportingView: NSView {
        private let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
