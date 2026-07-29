import AppKit
import ArtscribeUI
import Foundation

/// **Scrolling the reference list must not wedge the app.**
///
/// The user reported exactly that during manual QA — "scrolling with the
/// keyboard shortcuts window open starts scrolling the sidebar (good) but then
/// freezes the app" — and an earlier session recorded a one-off freeze in the
/// same window while audio was playing.
///
/// **This check has caught it once, and the wedge is real.** A sweep on
/// 2026-07-29 stopped returning to the event loop entirely: 100% of one core for
/// over nine minutes, sampled repeatedly in
/// `GraphHost.flushTransactions` → `AG::Subgraph::update` →
/// `LazySubviewPlacements.placeSubviews` → `LazyStack.place(subviews:)`, from
/// there into deeply recursive `StackLayout.sizeChildren…` /
/// `ViewLayoutEngine.sizeThatFits` over the rows. So it is **SwiftUI laying out
/// this list**, not a deadlock, not the audio graph and not a background thread:
/// the process is busy, not blocked.
///
/// It is also **intermittent** — one wedge in five sweeps of the same 480
/// notches — so a sweep that passes is not evidence that a change fixed it. One
/// candidate was tried and withdrawn for exactly that reason; see the report.
/// The check earns its place by being the only thing that has caught it at all.
///
/// What it drives: 480 real wheel notches posted at the window server, reversing
/// direction six times so the list is pushed against both ends, with the
/// transport running. What it measures: the **main thread's** responsiveness, as
/// the wall-clock cost of an `await settle(0.12)` between bursts. A wedged main
/// thread cannot service that timer, so a gap far larger than the sleep is what
/// a freeze looks like from inside the process.
///
/// It also checks that the list really moved. A sweep whose notches never
/// reached the `ScrollView` would report a very calm main thread and mean
/// nothing — the first version of this check did exactly that, moving the list
/// 48 px of 2255 while claiming a clean bill of health.
extension AcceptanceRun {

    /// How far past the sleep a burst may run before it counts as a stall.
    /// Generous on purpose: this is looking for a freeze, not for a dropped
    /// frame, and a run shares the machine with whoever is sitting at it.
    private static let stallThreshold: Double = 2.0

    @MainActor
    static func checkScrollingTheListNeverWedges(
        model: ViewerModel, shortcuts: ShortcutWindowController, log: inout Logger
    ) async {
        shortcuts.show()
        await settle(seconds: 1.0)
        guard let window = shortcuts.window, let content = window.contentView,
            let screen = NSScreen.screens.first
        else {
            log.check("the shortcut window exists to scroll", false)
            return
        }
        for _ in 0..<20 where NSApp.keyWindow !== window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await settle(seconds: 0.15)
        }

        // Over the list: the right-hand pane, vertically centred.
        let point = NSPoint(x: content.bounds.width * 0.86, y: content.bounds.height * 0.5)
        let onScreen = window.convertPoint(toScreen: content.convert(point, to: nil))
        let target = CGPoint(x: onScreen.x, y: screen.frame.maxY - onScreen.y)
        CGWarpMouseCursorPosition(target)
        await settle(seconds: 0.3)

        let scroll = firstScroll(in: content)
        model.togglePlayPause()
        await settle(seconds: 0.4)
        let wasPlaying = model.isPlaying

        var worst = 0.0
        var stalledAt: Int?
        var offsets: Set<Int> = []
        for pass in 0..<60 {
            // Ten passes down, ten up, and so on: the list is driven into both
            // ends repeatedly, which is where a scroll-geometry feedback loop
            // would live if there were one.
            let direction: Int32 = (pass / 10).isMultiple(of: 2) ? -6 : 6
            for _ in 0..<8 {
                CGWarpMouseCursorPosition(target)
                let event = CGEvent(
                    scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: direction,
                    wheel2: 0, wheel3: 0)
                event?.location = target
                event?.post(tap: .cghidEventTap)
            }
            let before = Date()
            await settle(seconds: 0.12)
            let elapsed = Date().timeIntervalSince(before)
            worst = max(worst, elapsed)
            if let scroll { offsets.insert(Int(scroll.documentVisibleRect.origin.y)) }
            if elapsed > Self.stallThreshold {
                stalledAt = pass
                break
            }
        }
        if model.isPlaying { model.pause() }

        let travelled = (offsets.max() ?? 0) - (offsets.min() ?? 0)
        log.note(
            "480 wheel notches over the shortcut list",
            "worst main-thread gap \(String(format: "%.3f", worst)) s, playing \(wasPlaying), "
                + "list travelled \(travelled) px of "
                + "\(Int(scroll?.documentView?.frame.height ?? 0)) over \(offsets.count) samples")
        let unreachable =
            travelled > 200
            ? nil
            : "the synthesised notches never reached the list (it moved \(travelled) px), so a "
                + "calm main thread here would be measuring nothing"
        log.check(
            "scrolling the list with the transport running never stalls the main thread"
                + (stalledAt.map { " (stalled at pass \($0))" } ?? ""),
            stalledAt == nil, unless: unreachable)

        window.performClose(nil)
        await settle(seconds: 0.5)
    }

    @MainActor
    private static func firstScroll(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScroll(in: subview) { return found }
        }
        return nil
    }
}
