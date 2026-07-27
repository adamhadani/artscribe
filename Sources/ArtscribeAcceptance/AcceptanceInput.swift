import AppKit
import ArtscribeUI
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
    ///
    /// `units` is the whole point of the P0 checks: `.pixel` produces the
    /// precise deltas of a trackpad swipe, `.line` the coarse ones of a physical
    /// mouse wheel, and `hasPreciseScrollingDeltas` is how the viewer tells them
    /// apart. A synthesised event carries no window, so the viewer resolves its
    /// anchor from the live pointer — warp the cursor first with `warp(toX:y:)`.
    @MainActor
    static func scroll(
        deltaX: Int32 = 0,
        deltaY: Int32 = 0,
        units: CGScrollEventUnit = .pixel,
        flags: CGEventFlags = []
    ) {
        guard
            let scroll = CGEvent(
                scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: deltaY,
                wheel2: deltaX, wheel3: 0)
        else { return }
        scroll.flags = flags
        guard let event = NSEvent(cgEvent: scroll) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// Puts the real pointer somewhere in the window, in window content
    /// coordinates with a top-left origin — the space the viewer hit-tests in.
    ///
    /// `CGWarpMouseCursorPosition` needs no accessibility permission, unlike
    /// posting mouse events to the system, so this works on a machine where
    /// synthetic input from outside the process is refused.
    @MainActor
    static func warp(toX x: Double, y: Double) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
            let view = window.contentView,
            // The *primary* display, not the window's: CoreGraphics measures
            // global coordinates from that one's top-left corner.
            let screen = NSScreen.screens.first
        else { return }
        let inView = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        let inWindow = view.convert(inView, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        // Screen coordinates run bottom-up; `CGWarpMouseCursorPosition` is
        // top-down from the primary display's origin.
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: screen.frame.maxY - onScreen.y))
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

    /// Counts pixels close to `colour` inside `rect`, given in window content
    /// coordinates with a top-left origin — the same space `ViewerModel`
    /// reports its lane frames in.
    ///
    /// Used to prove a *rendered* colour rather than a declared one: the P1
    /// speed emphasis and the P2 theme both have to reach actual pixels, and
    /// reading the model back would prove neither. Sampled on a coarse grid,
    /// which is plenty for "how much of this colour is in there".
    @MainActor
    static func pixelCount(near colour: NSColor, in rect: CGRect) -> Int {
        guard let wanted = colour.usingColorSpace(.sRGB),
            let window = NSApp.windows.first, let view = window.contentView,
            view.bounds.height > 0,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The backing store is at the display scale, and `rect` is in points.
        let scale = Double(rep.pixelsHigh) / view.bounds.height
        let top = Swift.max(0, Int(rect.minY * scale))
        let bottom = Swift.min(rep.pixelsHigh, Int(rect.maxY * scale))
        let left = Swift.max(0, Int(rect.minX * scale))
        let right = Swift.min(rep.pixelsWide, Int(rect.maxX * scale))
        guard top < bottom, left < right else { return 0 }

        var count = 0
        for y in stride(from: top, to: bottom, by: 2) {
            for x in stride(from: left, to: right, by: 3) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let close =
                    abs(pixel.redComponent - wanted.redComponent) < 0.1
                    && abs(pixel.greenComponent - wanted.greenComponent) < 0.1
                    && abs(pixel.blueComponent - wanted.blueComponent) < 0.1
                if close { count += 1 }
            }
        }
        return count
    }

    /// Counts pixels of exactly `colour` in one of the renderer's bitmaps.
    ///
    /// Exact, not near: the renderer writes opaque words straight into an sRGB
    /// bitmap, so the value that went in is the value that comes out — no
    /// display profile in the way, unlike a screen capture.
    static func bitmapCount(_ colour: RGB, in image: CGImage?) -> Int {
        guard let image, let data = image.dataProvider?.data as Data? else { return 0 }
        func byte(_ value: Double) -> UInt8 { UInt8((value * 255).rounded()) }
        let want = (byte(colour.red), byte(colour.green), byte(colour.blue))
        var found = 0
        let stride = image.bytesPerRow
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for row in 0..<image.height {
                for column in 0..<image.width {
                    // premultipliedFirst + byteOrder32Little is BGRA in memory.
                    let base = row * stride + column * 4
                    if (raw[base + 2], raw[base + 1], raw[base]) == want { found += 1 }
                }
            }
        }
        return found
    }

    /// A palette colour as an `NSColor`, for the pixel counts above.
    static func colour(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// The status-bar band, in the same coordinates as the lane frames.
    @MainActor
    static func statusBarRect() -> CGRect {
        guard let window = NSApp.windows.first, let view = window.contentView else { return .zero }
        let height = 40.0
        return CGRect(
            x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
    }

    static func settle(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Reporting

    struct Logger {
        private(set) var failures = 0
        /// Checks the machine could not support. Counted apart from failures and
        /// from passes, because they are neither.
        private(set) var skipped = 0
        private var lines: [String] = []

        mutating func check(_ name: String, _ passed: Bool) {
            if !passed { failures += 1 }
            lines.append("\(passed ? "PASS" : "FAIL")  \(name)")
        }

        /// A check this session cannot support, with the reason it cannot.
        ///
        /// Spec §8 — never degrade silently — applies to the harness as much as
        /// to the app. The alternative that keeps suggesting itself, relaxing an
        /// assertion until the environment stops tripping it, is how a real
        /// defect becomes permanent; this records what was not checked instead.
        /// The reason must be established *independently* of the behaviour under
        /// test, or a skip is just a failure in a better mood.
        mutating func skip(_ name: String, because reason: String) {
            skipped += 1
            lines.append("SKIP  \(name) — \(reason)")
        }

        /// `check`, unless `reason` says the environment cannot support it.
        mutating func check(_ name: String, _ passed: Bool, unless reason: String?) {
            guard let reason else { return check(name, passed) }
            skip(name, because: reason)
        }

        mutating func note(_ name: String, _ value: String) {
            lines.append("....  \(name): \(value)")
        }

        /// 0 = everything was checked and passed, 1 = something failed,
        /// 2 = nothing failed but some checks could not run. A caller that reads
        /// only the exit status still cannot mistake a partly-run acceptance for
        /// a complete one.
        var exitCode: Int32 {
            if failures > 0 { return 1 }
            return skipped > 0 ? 2 : 0
        }

        func report() {
            print("\n===== ACCEPTANCE =====")
            for line in lines { print(line) }
            let summary =
                skipped > 0
                ? "\(failures) failure(s), \(skipped) NOT CHECKED"
                : "\(failures) failure(s)"
            print("===== \(summary) =====\n")
        }
    }
}
