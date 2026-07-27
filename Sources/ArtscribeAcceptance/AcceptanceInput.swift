import AppKit
import Foundation

/// Event synthesis, window capture and reporting for `AcceptanceRun`.
extension AcceptanceRun {

    /// One synthesised keystroke.
    ///
    /// `characters` is what the keyboard would actually produce with the
    /// modifiers applied — including the dead-key composition for `⌥E`, which is
    /// the whole reason the window's handler reads `KeyPress.key` rather than
    /// `KeyPress.characters`. Getting that wrong here would test a keyboard
    /// nobody has.
    struct Key {
        let code: UInt16
        let characters: String
        let charactersIgnoringModifiers: String
        let modifiers: NSEvent.ModifierFlags

        init(
            _ code: UInt16, _ characters: String, ignoring: String? = nil,
            modifiers: NSEvent.ModifierFlags = []
        ) {
            self.code = code
            self.characters = characters
            self.charactersIgnoringModifiers = ignoring ?? characters
            self.modifiers = modifiers
        }

        static let e = Key(14, "e")
        static let r = Key(15, "r")
        static let z = Key(6, "z")
        static let x = Key(7, "x")
        static let escape = Key(53, "\u{1B}")
        /// `⌘0` and `⌘9` are menu key equivalents; the rest are plain.
        static let zero = Key(29, "0", modifiers: .command)
        static let nine = Key(25, "9", modifiers: .command)

        static let space = Key(49, " ")
        static let enter = Key(36, "\r")
        static let q = Key(12, "q")
        static let w = Key(13, "w")
        static let a = Key(0, "a")
        static let s = Key(1, "s")
        static let d = Key(2, "d")
        static let f = Key(3, "f")
        static let g = Key(5, "g")
        static let one = Key(18, "1")
        static let two = Key(19, "2")
        static let three = Key(20, "3")
        static let four = Key(21, "4")

        static let m = Key(46, "m")
        /// Arrow keys report a private-use character, not a printable one.
        static let up = Key(126, "\u{F700}")
        static let down = Key(125, "\u{F701}")
        static let shiftUp = Key(126, "\u{F700}", modifiers: .shift)
        static let shiftDown = Key(125, "\u{F701}", modifiers: .shift)

        static let shiftW = Key(13, "W", modifiers: .shift)
        static let shiftQ = Key(12, "Q", modifiers: .shift)
        /// On a US layout ⌥E is the acute-accent dead key, so `characters` is the
        /// combining accent and only `charactersIgnoringModifiers` says "e".
        static let optionE = Key(14, "\u{301}", ignoring: "e", modifiers: .option)
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
                    charactersIgnoringModifiers: key.charactersIgnoringModifiers,
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
