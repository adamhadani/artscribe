import AppKit
import Foundation
import QuartzCore

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
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(fire))
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
}
