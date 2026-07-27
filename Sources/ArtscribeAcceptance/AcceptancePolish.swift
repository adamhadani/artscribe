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
    /// loaded) and Theme, both read back out of AppKit rather than assumed.
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
        log.note("View menu", view.items.map(\.title).joined(separator: " | "))
        guard let theme = view.items.first(where: { $0.title == "Theme" })?.submenu else {
            log.check("the View menu carries Theme", false)
            return
        }
        await refreshMenu(theme)
        let options = theme.items.map(\.title)
        log.note("Theme menu", options.joined(separator: " | "))
        log.check("Theme offers System, Light and Dark", options == ["System", "Light", "Dark"])
        log.check(
            "the current theme is checked",
            theme.items.first { $0.state == .on }?.title == "Dark")

        // Driven through AppKit, not by setting the preference: this is the
        // path a user takes, and it is the one where a `Commands` body that
        // failed to re-evaluate would leave a dead menu item behind.
        if let light = theme.items.firstIndex(where: { $0.title == "Light" }) {
            theme.performActionForItem(at: light)
            await settle(seconds: 0.6)
            log.check("choosing Light from the menu switches the theme", model.appearance == .light)
            // Re-fetched, not reused: SwiftUI is free to hand AppKit a whole new
            // submenu, and a held reference would then report the old one.
            await refreshMenu(view)
            let reopened = view.items.first { $0.title == "Theme" }?.submenu
            if let reopened { await refreshMenu(reopened) }
            log.note(
                "Theme states after choosing Light",
                (reopened?.items.map { "\($0.title)=\($0.state.rawValue)" } ?? []).joined(
                    separator: " | "))
            log.check(
                "the checkmark follows the choice",
                reopened?.items.first { $0.state == .on }?.title == "Light")
        }
        if let dark = theme.items.firstIndex(where: { $0.title == "Dark" }) {
            theme.performActionForItem(at: dark)
            await settle(seconds: 0.6)
            log.check("choosing Dark from the menu switches back", model.appearance == .dark)
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

        theme.preference = .system
        await settle(seconds: 0.6)
        log.note("System resolves to", "\(model.appearance)")
        log.check(
            "System resolves to whatever macOS is set to",
            model.appearance == systemAppearance())
        theme.preference = .dark
        if model.isPlaying { press(.space) }
        model.setSpeedPreset(1.0)
        await settle(seconds: 0.3)
    }

    /// What macOS itself is set to, asked of AppKit rather than of the app.
    @MainActor
    static func systemAppearance() -> Appearance {
        let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return name == .darkAqua ? .dark : .light
    }
}
