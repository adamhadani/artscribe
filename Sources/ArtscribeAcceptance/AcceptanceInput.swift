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
        /// Play from the selection start since Task 18. `Return` is deliberately
        /// bound to nothing now, and `enter` stays defined so the run can prove
        /// that.
        static let shiftSpace = Key(49, " ", modifiers: .shift)
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
        /// The selection-move cluster (Task 18), sitting beside `Z`/`X` on the
        /// bottom row. ⌥C is "ç" and ⌥V is "√" on a US layout, so — exactly as
        /// for `⌥Z`/`⌥X` — only `charactersIgnoringModifiers` names the key.
        static let c = Key(8, "c")
        static let v = Key(9, "v")
        static let optionC = Key(8, "ç", ignoring: "c", modifiers: .option)
        static let optionV = Key(9, "√", ignoring: "v", modifiers: .option)
        /// Bound to nothing, anywhere. The control for "did the menu bar really
        /// claim that chord, or does `performKeyEquivalent` say yes to anything?"
        static let unbound = Key(38, "j")
        /// Arrow keys report a private-use character, not a printable one.
        static let up = Key(126, "\u{F700}")
        static let down = Key(125, "\u{F701}")
        static let shiftUp = Key(126, "\u{F700}", modifiers: .shift)
        static let shiftDown = Key(125, "\u{F701}", modifiers: .shift)

        static let left = Key(123, "\u{F702}")
        static let right = Key(124, "\u{F703}")
        static let optionLeft = Key(123, "\u{F702}", modifiers: .option)
        static let optionRight = Key(124, "\u{F703}", modifiers: .option)
        static let shiftLeft = Key(123, "\u{F702}", modifiers: .shift)
        static let shiftRight = Key(124, "\u{F703}", modifiers: .shift)

        static let shiftW = Key(13, "W", modifiers: .shift)
        static let shiftQ = Key(12, "Q", modifiers: .shift)
        static let shiftZ = Key(6, "Z", modifiers: .shift)
        static let shiftX = Key(7, "X", modifiers: .shift)
        /// On a US layout ⌥E is the acute-accent dead key, so `characters` is the
        /// combining accent and only `charactersIgnoringModifiers` says "e".
        static let optionE = Key(14, "\u{301}", ignoring: "e", modifiers: .option)
        /// Same shape as `optionE`: ⌥Z is Ω and ⌥X is ≈ on a US layout, and only
        /// `charactersIgnoringModifiers` names the key that was pressed.
        static let optionZ = Key(6, "Ω", ignoring: "z", modifiers: .option)
        static let optionX = Key(7, "≈", ignoring: "x", modifiers: .option)

        /// The loop-move cluster (Task 24). `⇧` + the loop row moves an edge —
        /// `A S` the in point, `D F` the out point — and `⇧C`/`⇧V` move the
        /// whole region on the keys that already move the whole selection.
        ///
        /// With ⇧ held, `charactersIgnoringModifiers` is the **uppercase**
        /// letter, which is exactly why `NSMenu` never claims these and
        /// `DocumentView` has to. Adding ⌥ gives the US layout's accented
        /// forms, so — as for `⌥Z`/`⌥X` — only `charactersIgnoringModifiers`
        /// names the key that was pressed.
        static let shiftA = Key(0, "A", modifiers: .shift)
        static let shiftS = Key(1, "S", modifiers: .shift)
        static let shiftD = Key(2, "D", modifiers: .shift)
        static let shiftF = Key(3, "F", modifiers: .shift)
        static let shiftC = Key(8, "C", modifiers: .shift)
        static let shiftV = Key(9, "V", modifiers: .shift)
        static let optionShiftA = Key(0, "Å", ignoring: "A", modifiers: [.option, .shift])
        static let optionShiftS = Key(1, "Í", ignoring: "S", modifiers: [.option, .shift])
        static let optionShiftD = Key(2, "Î", ignoring: "D", modifiers: [.option, .shift])
        static let optionShiftF = Key(3, "Ï", ignoring: "F", modifiers: [.option, .shift])
        static let optionShiftC = Key(8, "Ç", ignoring: "C", modifiers: [.option, .shift])
        static let optionShiftV = Key(9, "◊", ignoring: "V", modifiers: [.option, .shift])
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

    /// The same chord as `NSMenu` wants to see it: key-equivalent matching is
    /// case-sensitive against `charactersIgnoringModifiers`, and SwiftUI stores
    /// a shifted letter shortcut as the *lowercase* letter plus a shift mask.
    static func lowercased(_ key: Key) -> Key {
        Key(
            key.code, key.characters,
            ignoring: key.charactersIgnoringModifiers.lowercased(), modifiers: key.modifiers)
    }

    /// Offers a chord to the menu bar exactly as `NSApplication` does on a real
    /// keystroke, and answers whether a menu item claimed it.
    ///
    /// Needed because a *synthesised* event does not reach a non-`⌘` menu key
    /// equivalent in this harness. `⌘9` and `⌘0` fire through `press(…)`;
    /// `⇧Z`, `⌥Z` and friends do not, and nothing about the app decides that —
    /// no application here can become active or key (the login session's screen
    /// is locked), and the routing `sendEvent` does for those chords depends on
    /// it. The pre-existing `⇧W`/`⌥E` checks never noticed because both of those
    /// are *also* handled by the window, so one path or the other always fired.
    /// The nudge cluster's modified chords are menu-only by design, so they need
    /// the menu asked directly.
    @MainActor
    static func offerToMenuBar(_ key: Key) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: key.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: key.code)
        else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
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
        snapshot(NSApp.windows.first, to: path)
    }

    /// Captures one named window rather than the viewer. `cacheDisplay` draws
    /// the view itself, so this works with the login session's screen locked —
    /// a screen grab would not.
    @MainActor
    static func snapshot(_ window: NSWindow?, to path: String) {
        guard let window, let view = window.contentView,
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
    /// - Parameter tolerance: per-channel distance, 0…1. The default 0.1 suits a
    ///   near-saturated ink like the emphasis amber. A mid-tone moves further
    ///   through this display's profile on the way back out of the capture:
    ///   measured, the loop violet arrives as `9A96E7` against a declared
    ///   `8C7BE6` in dark and `6160CA` against `5340C4` in light — 0.125 on the
    ///   green channel. Nothing else in the status bar is within 0.15 of it, so
    ///   a wider window there costs no discrimination; see
    ///   `checkLoopProminence`, which keeps a loop-off control at exactly zero.
    @MainActor
    static func pixelCount(near colour: NSColor, in rect: CGRect, tolerance: Double = 0.1) -> Int {
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
                    abs(pixel.redComponent - wanted.redComponent) < tolerance
                    && abs(pixel.greenComponent - wanted.greenComponent) < tolerance
                    && abs(pixel.blueComponent - wanted.blueComponent) < tolerance
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
}
