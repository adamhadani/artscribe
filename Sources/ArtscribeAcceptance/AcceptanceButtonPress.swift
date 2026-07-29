import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// How the harness presses a transport button, and how it decides whether a
/// press could have been delivered at all.
///
/// Split out of `AcceptanceTransportChecks` because the two answer different
/// questions: that file says what the bar must do, this one says how a
/// synthesised press reaches it. The distinction earned its own file after a
/// run in which every check in the group failed and not one of them was about
/// the buttons.
extension AcceptanceRun {

    // MARK: - Pressing a button

    /// Presses a transport button, by pointer if the pointer works and through
    /// accessibility if it does not, and says which.
    ///
    /// The pointer path is tried first because it is the real thing. It does not
    /// always reach a SwiftUI control here, for the reason `mouseDrag` already
    /// records for `DragGesture`: `NSWindow.sendEvent` refuses to deliver a
    /// click to a window that is not key, and no window can be key while the
    /// login session's screen is locked, so the harness has to call the view's
    /// `mouseDown`/`mouseUp` directly and SwiftUI does not always route those.
    ///
    /// The accessibility path is not a stand-in for a click: it is the same
    /// entry point VoiceOver uses, in-process, needing no permissions, and it
    /// runs the `Button`'s real action — including `restoreFocus`. What it does
    /// not exercise is AppKit's first-responder handling, which is why the focus
    /// check reads the first responder around the press rather than trusting it.
    ///
    /// - Returns: `"pointer"`, `"accessibility"`, or `"nothing landed"`.
    @MainActor
    static func activate(_ control: TransportControl, model: ViewerModel) async -> String {
        // Let SwiftUI catch up with whatever the harness just did to the model
        // before clicking anything. Without this the press races the render
        // pass, and a button whose *enablement* the harness has only just
        // arranged is still drawn disabled — a disabled SwiftUI button swallows
        // the click silently. That is exactly how the loop button read as broken
        // for a whole run: `selectAll()` and `loopFromSelection()` gave it a
        // region to toggle, and the click arrived before the view had been told.
        await settle(seconds: 0.3)
        let before = fingerprint(model)
        await clickPointer(control, model: model)
        if fingerprint(model) != before { return "pointer" }
        pressViaAccessibility(control, model: model)
        await settle(seconds: 0.25)
        return fingerprint(model) != before ? "accessibility" : "nothing landed"
    }

    /// Everything a transport button can change, as one comparable value.
    @MainActor
    private static func fingerprint(_ model: ViewerModel) -> String {
        // `prerollEnabled` belongs here as much as `loop` does: it is what the
        // preroll button changes, and leaving it out made every preroll press
        // read as "nothing landed" **while it was working**. That is not merely
        // a wrong label — `activate` treats "nothing landed" as licence to try
        // the next delivery path, so a press the fingerprint could not see was
        // silently delivered a second time.
        "\(model.playhead)|\(model.speed.ratio)|\(model.speed.engine)|"
            + "\(model.framesPerPixel)|\(model.loop)|\(model.isPlaying)|"
            + "\(model.prefs.prerollEnabled)"
    }

    @MainActor
    private static func clickPointer(_ control: TransportControl, model: ViewerModel) async {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
            let content = window.contentView,
            let frame = model.transportFrames[control]
        else { return }
        // The window has to be key before AppKit will route a click into it, and
        // the app has to be active before the window can be key. Both are cheap
        // and idempotent, so they are asserted per press rather than assumed
        // from whatever the previous check left behind.
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        // `transportFrames` is SwiftUI's global space: window content
        // coordinates with a top-left origin. AppKit hit-testing is bottom-up.
        let point = NSPoint(x: frame.midX, y: content.bounds.height - frame.midY)

        func events() -> [NSEvent] {
            [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap {
                NSEvent.mouseEvent(
                    with: $0, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: $0 == .leftMouseUp ? 0 : 1)
            }
        }

        // Through the window first — the route a real click takes, and the one
        // SwiftUI's gesture recognisers are attached to.
        let before = fingerprint(model)
        for event in events() {
            window.sendEvent(event)
            await settle(seconds: 0.05)
        }
        await settle(seconds: 0.25)
        // **Only if that did nothing.** Calling `mouseDown` on the hit-tested
        // view is a fallback, and running it unconditionally would press every
        // button twice — which on `loop`, the one toggle here, lands back where
        // it started and is indistinguishable from never having arrived.
        guard fingerprint(model) == before, let target = content.hitTest(point) else { return }
        for event in events() {
            if event.type == .leftMouseDown {
                target.mouseDown(with: event)
            } else {
                target.mouseUp(with: event)
            }
            await settle(seconds: 0.05)
        }
        await settle(seconds: 0.25)
    }

    /// Finds the button by its accessibility label — which is exactly
    /// `TransportControl.title(in:)`, so the search is against the same string
    /// the tooltip shows — and presses it.
    @MainActor
    @discardableResult
    private static func pressViaAccessibility(
        _ control: TransportControl, model: ViewerModel
    ) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
            let root = window.contentView
        else { return false }
        let wanted = control.title(in: model.transportState)
        // Hit-test first. A SwiftUI hierarchy builds its accessibility elements
        // lazily — with no assistive client attached, walking `accessibilityChildren`
        // from the hosting view returns nothing at all (measured: "none exposed") —
        // and a hit test is the request that makes AppKit produce them.
        let hit = model.transportFrames[control].flatMap {
            window.accessibilityHitTest(screenPoint(of: $0, in: root, window: window))
                as? any NSAccessibilityProtocol
        }
        if let hit, hit.accessibilityRole() == .button {
            return hit.accessibilityPerformPress()
        }
        guard let element = findButton(labelled: wanted, under: root, depth: 0) else {
            return false
        }
        return element.accessibilityPerformPress()
    }

    /// The centre of a SwiftUI-global rect, in the screen coordinates AppKit's
    /// accessibility hit test wants.
    @MainActor
    private static func screenPoint(
        of frame: CGRect, in view: NSView, window: NSWindow
    ) -> NSPoint {
        let inView = NSPoint(
            x: frame.midX, y: view.isFlipped ? frame.midY : view.bounds.height - frame.midY)
        return window.convertPoint(toScreen: view.convert(inView, to: nil))
    }

    /// Every button the accessibility tree exposes, for the log — so a press
    /// that finds nothing says whether the tree is empty or merely differently
    /// labelled, rather than leaving that to guesswork.
    @MainActor
    static func accessibilityButtons() -> String {
        guard let root = (NSApp.keyWindow ?? NSApp.windows.first)?.contentView else { return "—" }
        var found: [String] = []
        collectButtons(under: root, depth: 0, into: &found)
        return found.isEmpty ? "none exposed" : found.joined(separator: ", ")
    }

    @MainActor
    private static func collectButtons(under element: Any, depth: Int, into found: inout [String]) {
        guard depth < 40, found.count < 30, let node = element as? any NSAccessibilityProtocol
        else { return }
        if node.accessibilityRole() == .button {
            found.append(node.accessibilityLabel() ?? node.accessibilityTitle() ?? "unlabelled")
        }
        for child in node.accessibilityChildren() ?? [] {
            collectButtons(under: child, depth: depth + 1, into: &found)
        }
    }

    /// Depth-first walk of the accessibility tree. Bounded, because a SwiftUI
    /// hierarchy is deep and a cycle in an `NSAccessibility` implementation
    /// would otherwise hang the run.
    @MainActor
    private static func findButton(
        labelled label: String, under element: Any, depth: Int
    ) -> (any NSAccessibilityProtocol)? {
        guard depth < 40, let node = element as? any NSAccessibilityProtocol else { return nil }
        let matches =
            node.accessibilityLabel() == label || node.accessibilityTitle() == label
        if node.accessibilityRole() == .button, matches { return node }
        for child in node.accessibilityChildren() ?? [] {
            if let found = findButton(labelled: label, under: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}
