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
/// A `Timer` would be the easy substitute and is the wrong answer for the normal
/// case: it runs at an arbitrary rate unrelated to when the screen actually
/// redraws, so the playhead either judders or burns work nobody sees. It is kept
/// as a stand-in for the two cases where no display link is ticking.
///
/// ## The link stops when the display sleeps, and that used to stop everything
///
/// A `CADisplayLink` stops firing while the display is asleep. Audio carries on
/// rendering perfectly — it is on CoreAudio threads and knows nothing about
/// screens — so the effect is that the *only* upward path goes quiet while the
/// music plays on.
///
/// The visible consequences were mild: a frozen position readout, auto-scroll
/// that stopped following. The invisible one was not. `ViewerModel+Practice`
/// advances the speed ramp by observing polled playhead positions through
/// `LoopWrapTracker`, so no polling meant **no observed wraps, and a ramp that
/// never advanced**. Set a phrase on a ten-minute ramp, let the screen sleep,
/// come back to find it still on the first repetition at the starting speed —
/// which is precisely the feature you set up and walk away from.
///
/// It also cost two investigations of the acceptance suite, where it appears as
/// eleven to thirteen position checks failing against a completely healthy
/// engine ("0 frames", "0 wraps observed over 18 s").
///
/// So the class now watches its own pulse. A link that goes quiet for longer
/// than `PlayheadClockPolicy.stallThreshold` is stood down in favour of the
/// timer, and the moment a real tick arrives the timer is stood down again. The
/// choice is continuous rather than made once at `start`, which is what the
/// previous version got wrong: it picked correctly for "no screen at launch" and
/// had no answer for "screen went away later".
@MainActor
final class PlayheadClock: NSObject {
    private var link: CADisplayLink?
    /// The 60 Hz stand-in, running whenever the link is not.
    private var standbyTimer: Timer?
    /// Watches for the link going quiet. Low frequency — it only has to notice.
    private var watchdog: Timer?
    private var tick: (() -> Void)?

    /// When the *display link* last fired. Not updated by the standby timer:
    /// that would make the watchdog conclude the link had recovered because its
    /// own replacement was working.
    private var lastLinkTick: CFTimeInterval = 0

    /// Non-`nil` when no display link could be created at all and the timer is
    /// standing in permanently. Surfaced rather than swallowed: the playhead is
    /// then no longer synchronised to the display, which is a real (if mild)
    /// degradation, and spec §8 forbids degrading silently.
    ///
    /// **The transient case — a link that stalls because the display slept —
    /// deliberately does not set this.** It reverses itself the instant the
    /// screen wakes, audio is unaffected throughout, and a banner that appeared
    /// every time a Mac's display went to sleep would be noise that teaches the
    /// user to ignore notices. It is observable through `isUsingStandbyClock`
    /// for anything that needs to know.
    private(set) var fallbackNotice: String?

    /// Whether ticks are currently coming from the timer rather than the display.
    private(set) var isUsingStandbyClock = false

    /// Whether the playhead is being polled at all.
    ///
    /// Now means what it says. It previously answered `link != nil`, which stays
    /// true for a link that has not fired in ten minutes — so the standing
    /// advice to "assert `isRunning` and skip the position checks" would have
    /// skipped nothing. With the standby clock there is no longer a state where
    /// this is true and no ticks are arriving.
    var isRunning: Bool { link != nil || standbyTimer != nil }

    func start(_ tick: @escaping () -> Void) {
        guard !isRunning else { return }
        self.tick = tick
        lastLinkTick = CACurrentMediaTime()

        guard let link = Self.makeDisplayLink(target: self, selector: #selector(fire)) else {
            fallbackNotice =
                "No display is available, so the playhead is being polled on a 60 Hz timer "
                + "instead of the display refresh. Audio is unaffected."
            startStandbyClock()
            return
        }
        link.add(to: .main, forMode: .common)
        self.link = link
        fallbackNotice = nil
        startWatchdog()
    }

    func stop() {
        link?.invalidate()
        link = nil
        stopStandbyClock()
        watchdog?.invalidate()
        watchdog = nil
        tick = nil
        isUsingStandbyClock = false
    }

    /// A real display tick. Also the signal that the display is back.
    @objc private func fire() {
        lastLinkTick = CACurrentMediaTime()
        // Hand back immediately. Running both would poll twice per frame, and
        // the link is the better clock whenever it is available.
        if standbyTimer != nil, fallbackNotice == nil { stopStandbyClock() }
        tick?()
    }

    // MARK: - Standing in for a quiet link

    private func startWatchdog() {
        watchdog?.invalidate()
        // Four times a second: this only has to *notice*, and a watchdog that
        // costs measurable power to guard against a mild degradation would be a
        // poor trade.
        let watchdog = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForStall() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    private func checkForStall() {
        guard link != nil, standbyTimer == nil else { return }
        guard
            PlayheadClockPolicy.isStalled(
                now: CACurrentMediaTime(), lastTick: lastLinkTick)
        else { return }
        startStandbyClock()
    }

    private func startStandbyClock() {
        guard standbyTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            // Deliberately does not touch `lastLinkTick`: the watchdog must keep
            // measuring the *link's* silence, not this timer's activity.
            MainActor.assumeIsolated { self?.tick?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        standbyTimer = timer
        isUsingStandbyClock = true
    }

    private func stopStandbyClock() {
        standbyTimer?.invalidate()
        standbyTimer = nil
        isUsingStandbyClock = false
    }

    /// A display link for whichever platform this is.
    ///
    /// macOS hangs it off an `NSScreen`, and there may be none — a headless
    /// session, or a run before any screen is attached — which is what the
    /// permanent timer fallback exists for. iOS always has a display, so
    /// `CADisplayLink`'s own initialiser is used directly; the fallback is
    /// unreachable there and is left in place rather than `#if`-ed away because
    /// "no display link" is a state the class already models honestly.
    private static func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
        #if os(macOS)
        guard let screen = NSScreen.main else { return nil }
        return screen.displayLink(target: target, selector: selector)
        #else
        return CADisplayLink(target: target, selector: selector)
        #endif
    }
}
