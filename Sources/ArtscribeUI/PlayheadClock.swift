import Foundation
import QuartzCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Drives the playhead poll at the display's refresh rate.
///
/// Spec §5: the render thread → main actor direction is a single atomic frame
/// counter that the UI **polls** on a display-link tick. The audio thread never
/// pushes, never calls back and never touches the model, so this class — plus
/// `PlaybackEngine.currentFrame` — is the entire upward path.
///
/// A `Timer` would be the easy substitute and is the wrong answer: it runs at an
/// arbitrary rate unrelated to when the screen actually redraws, so the playhead
/// either judders or burns work nobody sees. It is kept only as an explicitly
/// announced fallback for the case where no screen can supply a display link.
@MainActor
final class PlayheadClock: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private var tick: (() -> Void)?

    /// Non-`nil` when the display link could not be created and the timer is
    /// standing in. Surfaced rather than swallowed: the playhead is then no
    /// longer synchronised to the display, which is a real (if mild) degradation.
    private(set) var fallbackNotice: String?

    var isRunning: Bool { link != nil || timer != nil }

    func start(_ tick: @escaping () -> Void) {
        guard !isRunning else { return }
        self.tick = tick
        if let link = Self.makeDisplayLink(target: self, selector: #selector(fire)) {
            link.add(to: .main, forMode: .common)
            self.link = link
            fallbackNotice = nil
            return
        }
        fallbackNotice =
            "No display is available, so the playhead is being polled on a 60 Hz timer "
            + "instead of the display refresh. Audio is unaffected."
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        tick = nil
    }

    @objc private func fire() {
        tick?()
    }

    /// A display link for whichever platform this is.
    ///
    /// macOS hangs it off an `NSScreen`, and there may be none — a headless
    /// session, or a run before any screen is attached — which is what the timer
    /// fallback above exists for. iOS always has a display, so `CADisplayLink`'s
    /// own initialiser is used directly and the fallback is unreachable there;
    /// it is left in place rather than `#if`-ed away because "no display link"
    /// is a state the class already models honestly.
    ///
    /// **This is the whole upward path for the playhead, and it stops when the
    /// display stops.** A sleeping display freezes `ViewerModel.playhead` while
    /// audio carries on rendering perfectly — which cost a day's investigation
    /// on 2026-07-30, when eleven position checks failed against a healthy
    /// engine. See `isRunning`, and prefer skipping a position check to failing
    /// it when this is not running.
    private static func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
        #if os(macOS)
        guard let screen = NSScreen.main else { return nil }
        return screen.displayLink(target: target, selector: selector)
        #else
        return CADisplayLink(target: target, selector: selector)
        #endif
    }
}
