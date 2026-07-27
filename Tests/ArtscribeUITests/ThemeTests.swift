import ArtscribeKit
import AudioDecode
import CoreGraphics
import Foundation
import Testing
import Waveform

@testable import ArtscribeUI

/// The theme, and the trap that comes with it.
///
/// `WaveformRenderer` writes colours straight into a cached bitmap, so a theme
/// change that does not invalidate the cache leaves the previous theme's
/// waveform sitting on the new background. The pixel tests below are the guard
/// against exactly that, and they check pixels rather than the key alone because
/// a key that changes but a render that never happens looks identical from the
/// key's side.
@MainActor
@Suite("Theme")
struct ThemeTests {

    private static let totalFrames: FrameIndex = 200_000

    /// A track with actual signal in it, so the lanes are more than a centre
    /// line and the colour counts below are decisive.
    private func makeModel() -> ViewerModel {
        let storage = AudioStorage(channels: 1, capacityFrames: Int(Self.totalFrames))
        let samples = storage.pointer(0)
        for frame in 0..<Int(Self.totalFrames) {
            samples[frame] = Float(sin(Double(frame) * 0.01)) * 0.8
        }
        let audio = DecodedAudio(
            channels: 1, sampleRate: 44100, frameCount: Self.totalFrames, storage: storage)
        let model = ViewerModel()
        model.loadForTesting(audio: audio, pyramid: PeakPyramid.build(audio), widthPixels: 400)
        model.setLaneSize(CGSize(width: 400, height: 200), scale: 1)
        model.setOverviewSize(CGSize(width: 400, height: 40))
        return model
    }

    /// Counts pixels of exactly `colour` in a bitmap the renderer produced. The
    /// renderer writes opaque words, so this is an exact match, not a distance.
    private func count(_ colour: RGB, in image: CGImage?) -> Int {
        guard let image, let data = image.dataProvider?.data as Data? else { return 0 }
        func byte(_ value: Double) -> UInt8 { UInt8((value * 255).rounded()) }
        let want = (byte(colour.red), byte(colour.green), byte(colour.blue))
        var found = 0
        let stride = image.bytesPerRow
        data.withUnsafeBytes { raw in
            for row in 0..<image.height {
                for column in 0..<image.width {
                    // premultipliedFirst + byteOrder32Little is BGRA in memory.
                    let base = row * stride + column * 4
                    let pixel = (raw[base + 2], raw[base + 1], raw[base])
                    if pixel == want { found += 1 }
                }
            }
        }
        return found
    }

    // MARK: - The cache key

    @Test("the render cache key changes with the theme")
    func keyIncludesAppearance() {
        let dark = WaveformRenderer.Key(
            generation: 1, appearance: .dark, startFrame: 0, framesPerPixel: 4, visibleFrames: 400,
            pixelWidth: 100, pixelHeight: 50)
        var light = dark
        light.appearance = .light
        #expect(dark != light)
    }

    @Test("a theme switch replaces the cached key")
    func modelKeyChanges() {
        let model = makeModel()
        model.setAppearance(.dark)
        let before = model.renderedKey
        let overviewBefore = model.overviewKey
        #expect(before != nil)

        model.setAppearance(.light)

        #expect(model.renderedKey != before)
        #expect(model.overviewKey != overviewBefore)
        #expect(model.renderedKey?.appearance == .light)
        #expect(model.overviewKey?.appearance == .light)
    }

    // MARK: - The pixels

    @Test("the lane bitmap is re-rasterised in the new theme's colours")
    func lanesRepaint() {
        let model = makeModel()
        model.setAppearance(.dark)
        #expect(count(Palette.dark.waveform, in: model.waveformImage) > 0)
        #expect(count(Palette.light.waveform, in: model.waveformImage) == 0)

        model.setAppearance(.light)

        #expect(count(Palette.light.waveform, in: model.waveformImage) > 0)
        #expect(
            count(Palette.dark.waveform, in: model.waveformImage) == 0,
            "dark waveform pixels survived a switch to the light theme")
    }

    /// The overview's key deliberately omits the viewport, so it is the one most
    /// likely to be left behind by a change that is not a pan or a zoom.
    @Test("the overview bitmap is re-rasterised too")
    func overviewRepaints() {
        let model = makeModel()
        model.setAppearance(.dark)
        #expect(count(Palette.dark.waveform, in: model.overviewImage) > 0)

        model.setAppearance(.light)

        #expect(count(Palette.light.waveform, in: model.overviewImage) > 0)
        #expect(count(Palette.dark.waveform, in: model.overviewImage) == 0)
    }

    /// Switching theme must not disturb what you were doing.
    @Test("a theme switch leaves position, selection, loop and zoom alone")
    func switchingIsNonDisruptive() {
        let model = makeModel()
        model.seek(to: 90_000)
        model.selection.begin(at: 10_000)
        model.selection.extend(to: 50_000)
        model.loopFromSelection()
        model.zoomIn()
        let viewport = model.viewport
        let selection = model.selection.range
        let loop = model.loop
        let playhead = model.playhead

        model.setAppearance(.light)

        #expect(model.viewport == viewport)
        #expect(model.selection.range == selection)
        #expect(model.loop == loop)
        #expect(model.playhead == playhead)
    }

    @Test("setting the same theme again does not re-render")
    func idempotentSwitch() {
        let model = makeModel()
        model.setAppearance(.light)
        let image = model.waveformImage
        model.setAppearance(.light)
        #expect(model.waveformImage === image)
    }

    // MARK: - The preference

    @Test("the preference persists across launches")
    func preferencePersists() {
        let suite = "artscribe.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not make a defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ThemeController(defaults: defaults)
        #expect(first.preference == ThemeController.fallback)
        first.preference = .light

        let second = ThemeController(defaults: defaults)
        #expect(second.preference == .light)
    }

    /// A stored value that is not one of the three cases — a hand-edited plist,
    /// or a preference written by a later version — falls back rather than
    /// crashing on a force-unwrapped `init(rawValue:)`.
    @Test("an unrecognised stored preference falls back")
    func unknownStoredPreference() {
        let suite = "artscribe.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not make a defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("solarized", forKey: "theme")

        #expect(ThemeController(defaults: defaults).preference == ThemeController.fallback)
    }

    @Test("System defers to macOS, Light and Dark do not")
    func colorSchemes() {
        #expect(ThemePreference.system.colorScheme == nil)
        #expect(ThemePreference.light.colorScheme == .light)
        #expect(ThemePreference.dark.colorScheme == .dark)
    }

    // MARK: - The light palette is designed, not inverted

    /// Contrast is checked here rather than eyeballed, and against both surfaces
    /// a colour actually lands on. 4.5:1 is the WCAG AA threshold for text; 3:1
    /// is the threshold for a graphical object, which is what the waveform, the
    /// playhead and the loop markers are.
    @Test("every light-theme role clears its contrast threshold")
    func lightContrast() {
        let palette = Palette.light
        for surface in [palette.panel, palette.background] {
            #expect(contrast(palette.text, surface) >= 4.5)
            #expect(contrast(palette.dimmed, surface) >= 4.5)
            #expect(contrast(palette.danger, surface) >= 4.5)
            #expect(contrast(palette.emphasis, surface) >= 4.5)
            #expect(contrast(palette.waveform, surface) >= 3)
            #expect(contrast(palette.accent, surface) >= 3)
            #expect(contrast(palette.loop, surface) >= 3)
        }
    }

    @Test("the dark theme still clears the same thresholds")
    func darkContrast() {
        let palette = Palette.dark
        for surface in [palette.panel, palette.background] {
            #expect(contrast(palette.text, surface) >= 4.5)
            #expect(contrast(palette.waveform, surface) >= 3)
            #expect(contrast(palette.accent, surface) >= 3)
            #expect(contrast(palette.loop, surface) >= 3)
        }
    }

    /// The two themes must not accidentally converge on the same values, which
    /// is what "inverted" would look like in the one place it is measurable.
    @Test("the two themes are genuinely different palettes")
    func themesDiffer() {
        #expect(Palette.light != Palette.dark)
        #expect(Palette.of(.light) == Palette.light)
        #expect(Palette.of(.dark) == Palette.dark)
        #expect(Palette.light.waveform != Palette.dark.waveform)
        #expect(Palette.light.panel != Palette.dark.panel)
    }

    /// WCAG relative luminance and contrast ratio.
    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        func luminance(_ rgb: RGB) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green)
                + 0.0722 * channel(rgb.blue)
        }
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
