import AppKit
import ArtscribeKit
import ArtscribeUI
import Foundation

/// The Task 13 polish checks: the speed emphasis, the File and View menus, and
/// the theme — including the cached-bitmap trap that theming is built around.
///
/// Split from `AcceptanceChecks` only to keep both files inside the project's
/// 400-line limit; it is the same run.
extension AcceptanceRun {

    /// P1: an altered speed is emphasised, and 100% is not.
    ///
    /// Counted in rendered pixels of the status-bar band, not read back off the
    /// model: the whole point of the item is that the emphasis reaches the
    /// screen. The amber appears nowhere else down there.
    @MainActor
    static func checkSpeedEmphasis(
        model: ViewerModel, log: inout Logger, outputDirectory: String
    ) async {
        let amber = colour(Palette.of(model.appearance).emphasis)
        let band = statusBarRect()
        model.setSpeedPreset(1.0)
        await settle(seconds: 0.3)
        let atNormal = pixelCount(near: amber, in: band)
        snapshot(to: "\(outputDirectory)/08-speed-100.png")

        model.setSpeedPreset(0.5)
        await settle(seconds: 0.3)
        let atHalf = pixelCount(near: amber, in: band)
        snapshot(to: "\(outputDirectory)/08-speed-50.png")

        log.note("status-bar accent pixels", "100%: \(atNormal), 50%: \(atHalf)")
        // Sampled on a 3x2 grid over anti-aliased 11 pt text, so the count is
        // small by construction; what matters is that it is decisively not zero.
        log.check("the speed readout is emphasised at 50%", atHalf > 15)
        log.check("the speed readout is plain at 100%", atNormal == 0)
        model.setSpeedPreset(1.0)
    }

    /// The File and View menus: Open Recent (populated by the file this run
    /// loaded) and the zoom and selection items, read back out of AppKit rather
    /// than assumed.
    ///
    /// Theme is no longer among them — Task 14 moved it into Settings, and
    /// `checkSettings` is what confirms it left. The theme's behaviour is
    /// checked through the controller the Settings control binds to, in
    /// `checkTheme`.
    @MainActor
    static func checkFileAndViewMenus(model: ViewerModel, log: inout Logger) async {
        await checkRecentMenu(model: model, log: &log)
        log.note(
            "menu bar", (NSApp.mainMenu?.items.map(\.title) ?? []).joined(separator: " | "))
        guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else {
            log.check("a View menu exists", false)
            return
        }
        await refreshMenu(view)
        let titles = view.items.map(\.title).filter { !$0.isEmpty }
        log.note("View menu", titles.joined(separator: " | "))
        let wanted = ["Fit Whole File", "Zoom to Selection", "Zoom In", "Zoom Out"]
        for expected in wanted {
            log.check(
                "the View menu carries \(expected)", titles.contains { $0.hasPrefix(expected) })
        }
        // Task 18 moved these to Edit, where macOS convention puts them. An
        // action left behind in two menus is one that can grey out in one place
        // and not the other.
        for moved in ["Select All", "Clear Selection"] {
            log.check(
                "\(moved) has left the View menu",
                !titles.contains { $0.hasPrefix(moved) })
        }
    }

    @MainActor
    private static func checkRecentMenu(model: ViewerModel, log: inout Logger) async {
        guard let file = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else {
            log.check("a File menu exists", false)
            return
        }
        await refreshMenu(file)
        guard let recent = file.items.first(where: { $0.title == "Open Recent" })?.submenu else {
            log.check("the File menu carries Open Recent", false)
            return
        }
        await refreshMenu(recent)
        let titles = recent.items.map(\.title).filter { !$0.isEmpty }
        log.note("Open Recent", titles.joined(separator: " | "))
        log.check(
            "the file this run loaded is in Open Recent",
            titles.contains { $0 == model.fileName })
        log.check("Open Recent carries Clear Menu", titles.contains("Clear Menu"))
    }

    /// The same populate-then-validate dance `AcceptanceMenuChecks` documents: a
    /// SwiftUI menu is filled in by its delegate when it is pulled down, so a
    /// plain `update()` measures the previous frame.
    @MainActor
    static func refreshMenu(_ menu: NSMenu) async {
        await settle(seconds: 0.2)
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        await settle(seconds: 0.05)
        menu.update()
    }

    /// P2: the theme actually repaints, including the cached waveform bitmap,
    /// and does not disturb playback.
    ///
    /// The waveform colour is counted in the lane band before and after the
    /// switch. That is the trap this whole item is built around: the lanes are a
    /// cached bitmap with its colours baked in, so a switch that failed to
    /// invalidate the cache would leave the old theme's waveform pixels sitting
    /// there — visible here as a dark count that refuses to fall to nothing.
    @MainActor
    static func checkTheme(
        model: ViewerModel, theme: ThemeController, log: inout Logger, outputDirectory: String
    ) async {
        theme.preference = .dark
        await settle(seconds: 0.5)
        let lanes = model.laneFrame
        guard !lanes.isEmpty else {
            log.check("lane geometry is known to the model", false)
            return
        }
        // Two different questions, measured two different ways.
        //
        // The cached bitmap is checked in the bitmap itself, where the colours
        // are exactly the palette's: it is generated in sRGB and read back
        // without going near a display profile. That is the trap this item is
        // built around — a switch that failed to invalidate the cache would
        // leave the old theme's waveform pixels in there.
        //
        // Whether the *window* repainted is checked on screen, against the panel
        // colour. Deliberately not the ink: a screen capture round-trips through
        // this display's profile, which leaves near-white and near-black within
        // a unit or two but moves a mid-tone slate by ~20, so the ink is not a
        // colour to match against on screen.
        model.seek(to: model.totalFrames / 3)
        model.setSpeedPreset(0.5)
        press(.space)
        await settle(seconds: 0.4)
        let wasPlaying = model.isPlaying
        let position = model.playhead
        let viewport = model.viewport
        let inDark = bitmapCount(Palette.dark.waveform, in: model.waveformImage)
        let darkPanelOnScreen = pixelCount(near: colour(Palette.dark.panel), in: lanes)
        snapshot(to: "\(outputDirectory)/09-theme-dark.png")

        theme.preference = .light
        await settle(seconds: 0.8)
        let inLight = bitmapCount(Palette.light.waveform, in: model.waveformImage)
        let leftOver = bitmapCount(Palette.dark.waveform, in: model.waveformImage)
        let overviewLeftOver = bitmapCount(Palette.dark.waveform, in: model.overviewImage)
        let lightPanelOnScreen = pixelCount(near: colour(Palette.light.panel), in: lanes)
        snapshot(to: "\(outputDirectory)/09-theme-light.png")

        log.note(
            "waveform bitmap",
            "dark theme: \(inDark) dark px; after switching: \(inLight) light px, "
                + "\(leftOver) dark px (overview \(overviewLeftOver))")
        log.note(
            "panel on screen",
            "dark theme: \(darkPanelOnScreen), light theme: \(lightPanelOnScreen)"
        )
        log.check("the dark theme rasterises the dark waveform", inDark > 200)
        log.check("switching to light re-rasterises the waveform", inLight > 200)
        log.check("no dark waveform pixels survive in the lane bitmap", leftOver == 0)
        log.check("no dark waveform pixels survive in the overview bitmap", overviewLeftOver == 0)
        log.check("the window itself repainted (dark panel)", darkPanelOnScreen > 1000)
        log.check("the window itself repainted (light panel)", lightPanelOnScreen > 1000)
        log.check("the model followed the window into the light theme", model.appearance == .light)
        log.check("the switch did not stop playback", model.isPlaying == wasPlaying)
        log.check("the switch did not move the viewport", model.viewport == viewport)
        log.check(
            "the switch did not move the position (\(position) -> \(model.playhead))",
            model.playhead >= position)

        theme.preference = .dark
        await settle(seconds: 0.6)
        log.check(
            "switching back restores the dark waveform",
            bitmapCount(Palette.dark.waveform, in: model.waveformImage) > 200)

        // Ask AppKit what this Mac is set to — but only with `System` selected,
        // because `applyToApplication` sets `NSApp.appearance` for the explicit
        // themes and `effectiveAppearance` would then read the app's own choice
        // straight back.
        theme.preference = .system
        await settle(seconds: 0.6)
        let macOS = systemAppearance()

        // Then deliberately switch to the *opposite* of it before asking System
        // to resolve again, so the check below has something to prove. Comparing
        // the app's appearance against the system while the app already happens
        // to match it is vacuous — and that is not hypothetical: this check
        // passed review on a Mac in dark mode while `System` was broken, because
        // "stayed dark" and "followed a dark system" are the same pixels. See
        // `ThemeController` for what was actually wrong.
        let oppositeAppearance: Appearance = macOS == .dark ? .light : .dark
        let opposite: ThemePreference = macOS == .dark ? .light : .dark
        theme.preference = opposite
        await settle(seconds: 0.6)
        log.check(
            "the app is on \(opposite), the opposite of this Mac's \(macOS)",
            model.appearance == oppositeAppearance)

        theme.preference = .system
        await settle(seconds: 0.6)
        log.note("System resolves to", "\(model.appearance) (macOS is \(macOS))")
        log.check(
            "System resolves to whatever macOS is set to",
            model.appearance == macOS)
        // The seam the resolution rests on: `ThemeController` reads the global
        // `AppleInterfaceStyle` default rather than `NSApp.effectiveAppearance`,
        // because the latter reads back the app's own override. With `System`
        // selected there is no override, so the two must agree — which is what
        // makes reading the default the right substitute in the other modes.
        let fromDefault = ThemeController.macOSAppearance()
        log.check(
            "the global appearance default agrees with AppKit (\(fromDefault))",
            fromDefault == macOS)
        theme.preference = .dark
        if model.isPlaying { press(.space) }
        model.setSpeedPreset(1.0)
        await settle(seconds: 0.3)
    }

    /// What macOS itself is set to, asked of AppKit rather than of the app.
    ///
    /// Only truthful while the app is not overriding `NSApp.appearance`, which
    /// is why `ThemeController` reads the global default instead. Used here as
    /// the independent second opinion that pins that reading.
    @MainActor
    static func systemAppearance() -> Appearance {
        let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return name == .darkAqua ? .dark : .light
    }
}
