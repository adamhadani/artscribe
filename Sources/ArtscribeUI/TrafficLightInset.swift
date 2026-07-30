#if os(macOS)
import AppKit
import Observation

/// How far the header has to start in from the leading edge to clear the
/// window's close/minimise/zoom buttons.
///
/// The app draws its own header across the full width of the window, and macOS
/// draws the traffic lights on top of it. Before this existed the wordmark sat
/// underneath them and read as `A ● ● ● IBE`.
///
/// ## Why it is measured rather than a constant
///
/// 78 pt is the usual answer and would be right almost always — but not in **full
/// screen**, where the buttons are removed entirely and a fixed inset leaves a
/// conspicuous gap where the wordmark should be. The same applies to any window
/// that has no title bar buttons at all.
///
/// So the number comes from the button itself. `standardWindowButton` returns
/// nil, or a hidden button, exactly in the cases where no inset is wanted, which
/// makes the fallback the honest answer rather than a guess.
@MainActor
@Observable
final class TrafficLightInset {
    static let shared = TrafficLightInset()

    /// Points to leave clear at the leading edge. Zero when there is nothing to
    /// clear.
    private(set) var leading: CGFloat = 0

    private var observers: [any NSObjectProtocol] = []

    /// Starts tracking `window`, and re-measures when it enters or leaves full
    /// screen — the only transitions that add or remove the buttons.
    func adopt(_ window: NSWindow?) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else {
            leading = 0
            return
        }
        for name: NSNotification.Name in [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.measure(window) }
            }
            observers.append(observer)
        }
        measure(window)
    }

    private func measure(_ window: NSWindow?) {
        guard
            let window,
            // **Only when the content actually draws under the title bar.** The
            // bundled app sets `.fullSizeContentView`, so its header shares a row
            // with the traffic lights and must get out of their way. An
            // unbundled `swift run` gets an ordinary title bar, where the lights
            // sit on their own row above the header — insetting there would
            // indent the wordmark for no reason, which is what the first version
            // of this did.
            window.styleMask.contains(.fullSizeContentView),
            let button = window.standardWindowButton(.closeButton),
            !button.isHidden,
            let container = button.superview
        else {
            // No buttons: full screen, or a window without them. Nothing to
            // clear, and an inset here would be a gap for no reason.
            if leading != 0 { leading = 0 }
            return
        }
        // The rightmost button, not the close button — the three are laid out
        // left to right and the zoom button is the one the header must clear.
        let rightEdge =
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: container).maxX }
            .max() ?? 0
        // The button's own leading offset again, so the gap after the lights
        // matches the gap before them.
        let next = rightEdge + button.frame.minX
        if abs(next - leading) > 0.5 { leading = next }
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
#endif
