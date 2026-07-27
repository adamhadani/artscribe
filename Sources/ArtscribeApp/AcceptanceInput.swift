import AppKit
import Foundation

/// Event synthesis, window capture and reporting for `AcceptanceRun`.
extension AcceptanceRun {

    enum Key {
        case e, r, z, x, escape, zero, nine

        var code: UInt16 {
            switch self {
            case .e: return 14
            case .r: return 15
            case .z: return 6
            case .x: return 7
            case .escape: return 53
            case .zero: return 29
            case .nine: return 25
            }
        }

        var characters: String {
            switch self {
            case .e: return "e"
            case .r: return "r"
            case .z: return "z"
            case .x: return "x"
            case .escape: return "\u{1B}"
            case .zero: return "0"
            case .nine: return "9"
            }
        }

        /// `Cmd-0` and `Cmd-9` are menu key equivalents; the rest are plain.
        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .zero, .nine: return .command
            default: return []
            }
        }
    }

    @MainActor
    static func press(_ key: Key) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: key.characters,
                    charactersIgnoringModifiers: key.characters,
                    isARepeat: false,
                    keyCode: key.code)
            else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// Vertical position, in window coordinates, that lands inside the waveform
    /// lanes: above the status bar and below the ruler for the pinned 1280x800
    /// window this run uses.
    static let laneY: Double = 400

    /// Drives a pointer drag by hit-testing the window and calling the view's
    /// own `mouseDown`/`mouseDragged`/`mouseUp` — the exact methods AppKit would
    /// call, so SwiftUI's `DragGesture` is genuinely under test.
    ///
    /// `NSWindow.sendEvent` is deliberately bypassed. It refuses to deliver a
    /// click to a window that is not key, and while the login session's screen
    /// is locked no application can become active, so nothing here can ever be
    /// key. Skipping that one policy check is the only concession made.
    @MainActor
    static func mouseDrag(fromX: Double, toX: Double) async {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
            let content = window.contentView
        else { return }
        var number = 1
        func event(_ type: NSEvent.EventType, x: Double) -> NSEvent? {
            number += 1
            return NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: x, y: laneY),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown, x: fromX),
            let target = content.hitTest(NSPoint(x: fromX, y: laneY))
        else { return }
        target.mouseDown(with: down)
        await settle(seconds: 0.05)
        for step in 1...4 {
            let x = fromX + (toX - fromX) * Double(step) / 4
            if let dragged = event(.leftMouseDragged, x: x) { target.mouseDragged(with: dragged) }
            await settle(seconds: 0.03)
        }
        if let up = event(.leftMouseUp, x: toX) { target.mouseUp(with: up) }
        await settle(seconds: 0.1)
    }

    /// Posted rather than sent: local event monitors only see events that pass
    /// through the application's event queue.
    @MainActor
    static func scroll(deltaX: Int32) {
        guard
            let scroll = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0,
                wheel2: deltaX, wheel3: 0),
            let event = NSEvent(cgEvent: scroll)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    @MainActor
    static func normaliseWindow() async {
        guard let window = NSApp.windows.first else { return }
        window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 800), display: true)
        for _ in 0..<40 {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            await settle(seconds: 0.1)
            if NSApp.keyWindow != nil { return }
        }
    }

    @MainActor
    static func snapshot(to path: String) {
        guard let window = NSApp.windows.first, let view = window.contentView,
            let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    static func settle(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Reporting

    struct Logger {
        private(set) var failures = 0
        private var lines: [String] = []

        mutating func check(_ name: String, _ passed: Bool) {
            if !passed { failures += 1 }
            lines.append("\(passed ? "PASS" : "FAIL")  \(name)")
        }

        mutating func note(_ name: String, _ value: String) {
            lines.append("....  \(name): \(value)")
        }

        func report() {
            print("\n===== ACCEPTANCE =====")
            for line in lines { print(line) }
            print("===== \(failures) failure(s) =====\n")
        }
    }
}
