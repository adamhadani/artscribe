import CoreGraphics
import SwiftUI

/// One packed sRGB colour, usable both as a SwiftUI `Color` and as a `CGColor`
/// for the bitmap waveform renderer. Keeping a single source for both avoids the
/// two drawing paths drifting apart.
public struct RGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(_ packed: UInt32) {
        red = Double((packed >> 16) & 0xFF) / 255
        green = Double((packed >> 8) & 0xFF) / 255
        blue = Double(packed & 0xFF) / 255
    }

    public func color(opacity: Double = 1) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    public func cgColor(opacity: Double = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}

/// Which of the two designed looks is on screen. The *resolved* answer — the
/// user's preference may be `system`, but something always has to be drawn.
public enum Appearance: String, Equatable, Sendable, CaseIterable {
    case dark
    case light
}

/// The palette agreed in the design mockups (spec §7), in both appearances.
///
/// A value rather than a namespace of statics, reached through the environment,
/// so a view cannot accidentally read one theme's colour while the rest of the
/// window draws in the other. `ViewerModel` holds the resolved `Appearance`
/// because the cached waveform bitmap has its colours baked in and must be
/// re-rasterised when the theme changes.
///
/// **Light is designed, not inverted.** An inverted dark palette gives muddy
/// pastels on white; every light value below is its own choice, and every one of
/// them was measured against both surfaces rather than eyeballed. Contrast ratios
/// (WCAG, against `panel` / `background`):
///
/// | role      | dark        | light       |
/// |-----------|-------------|-------------|
/// | text      | 10.7 / 11.7 | 15.2 / 13.1 |
/// | dimmed    |  3.7 /  4.1 |  5.6 /  4.8 |
/// | waveform  |  4.7 /  5.1 |  5.7 /  4.9 |
/// | selection |  8.1 /  8.9 |  5.6 /  4.8 |
/// | accent    |  9.0 /  9.9 |  4.7 /  4.1 |
/// | loop      |  4.9 /  5.3 |  6.8 /  5.8 |
/// | danger    |  5.2 /  5.7 |  6.1 /  5.3 |
public struct Palette: Equatable, Sendable {
    public let appearance: Appearance

    public let background: RGB
    public let panel: RGB
    public let waveform: RGB
    public let selection: RGB
    public let accent: RGB
    public let text: RGB
    public let dimmed: RGB
    public let danger: RGB
    /// The loop region. Deliberately neither the selection amber nor the accent
    /// teal: the loop and the selection are shown at the same time and mean
    /// different things, so they must not be told apart by brightness alone.
    public let loop: RGB
    /// Cue-sheet track marks.
    ///
    /// **Not the yellow that was suggested**, and the reason is measurable. The
    /// three inks already drawn on the lane sit at hues 29° (selection amber),
    /// 174° (accent teal, which is also the playhead) and 250° (loop violet); a
    /// yellow lands around 50°, three weeks' worth of squinting away from the
    /// amber it would have to be told apart from in a 1pt hairline. The widest
    /// gap on the wheel runs from the violet round to the amber, and its middle
    /// is here. Magenta is also the one hue that stays itself in both themes
    /// without going muddy on near-white.
    public let marker: RGB
    /// Hairline between panels. Derived from `panel` so the chrome stays in family.
    public let rule: RGB
    /// The divider between stacked channel lanes. Darker than the lane in dark,
    /// lighter in light — a hairline that reads as a seam either way.
    public let laneRule: RGB
    /// A readout that is deliberately not at its default value — currently only
    /// the speed. Shares the selection amber on purpose: amber is already this
    /// palette's "you changed something" colour, and the two never appear in the
    /// same place (one is a wash over the waveform, the other one word of text).
    /// Not the accent teal, which is spoken for by the playhead and the playing
    /// position and would make an altered speed look like a transport state.
    public var emphasis: RGB { selection }

    /// How strongly the selection wash tints the lane. The light theme needs a
    /// little more: the same alpha of a dark amber over near-white reads fainter
    /// than a bright amber over near-black.
    public let selectionFillOpacity: Double
    /// How far the overview strip fades what is outside the lens.
    public let veilOpacity: Double

    /// The dark look, unchanged — it is the one the app was designed around and
    /// the one that stays the default.
    public static let dark = Palette(
        appearance: .dark,
        background: RGB(0x13_1417),
        panel: RGB(0x1B_1D22),
        waveform: RGB(0x7A_889A),
        selection: RGB(0xF0_A35E),
        accent: RGB(0x4F_D1C5),
        text: RGB(0xC9_CED6),
        dimmed: RGB(0x6F_7783),
        danger: RGB(0xE0_6C63),
        loop: RGB(0x8C_7BE6),
        marker: RGB(0xE0_86C8),
        rule: RGB(0x2A_2D34),
        laneRule: RGB(0x13_1417),
        selectionFillOpacity: 0.13,
        veilOpacity: 0.62)

    /// Studio paper: a cool neutral chrome with a near-white lane, and inks deep
    /// enough to hold their own against it. The hues are the dark theme's —
    /// slate, amber, teal, violet — taken down rather than washed out, so the
    /// two themes are recognisably the same instrument.
    public static let light = Palette(
        appearance: .light,
        background: RGB(0xE4_E6EA),
        panel: RGB(0xF6_F7F9),
        waveform: RGB(0x56_637A),
        selection: RGB(0x96_5206),
        accent: RGB(0x0B_7C74),
        text: RGB(0x1C_2029),
        dimmed: RGB(0x5B_6472),
        danger: RGB(0xB0_2A22),
        loop: RGB(0x53_40C4),
        marker: RGB(0x9B_2C7A),
        rule: RGB(0xC9_CDD5),
        laneRule: RGB(0xC9_CDD5),
        selectionFillOpacity: 0.16,
        veilOpacity: 0.72)

    public static func of(_ appearance: Appearance) -> Palette {
        appearance == .light ? .light : .dark
    }

    // MARK: - Theme-independent geometry

    static let selectionEdgeWidth: Double = 2

    /// Height of the bar drawn along the top and bottom of the lanes to mark the
    /// loop region. A bar, not a full-height wash: the selection already owns
    /// the full height, and two overlapping washes are unreadable.
    static let loopBarHeight: Double = 4
    /// A loop region that exists but is switched off is still shown, because
    /// having set it is worth remembering — just visibly inert.
    static let loopDisabledOpacity: Double = 0.3
}

extension EnvironmentValues {
    /// The palette every view draws from. Set once, at the root of the window, so
    /// a theme switch repaints the whole tree in one move.
    @Entry public var palette: Palette = .dark
}

/// Type roles. Every number in this app is monospaced so digits do not jitter as
/// the playhead or zoom changes; only the file name is set in the prose face.
enum Typography {
    static let readout = Font.system(size: 11, weight: .medium, design: .monospaced)
    /// A readout that is not at its default value. Bold as well as coloured:
    /// colour alone is not a signal everyone can read.
    static let readoutEmphasis = Font.system(size: 11, weight: .bold, design: .monospaced)
    static let readoutSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let tick = Font.system(size: 9, weight: .medium, design: .monospaced)
    static let laneLabel = Font.system(size: 9, weight: .semibold, design: .monospaced)
    static let eyebrow = Font.system(size: 9, weight: .semibold, design: .monospaced)
    static let fileName = Font.system(size: 13, weight: .medium)
    static let bannerBody = Font.system(size: 12, weight: .regular)
    /// A shortcut drawn as a key cap. Monospaced so `⇧Space` and `⌥⇧A` line up
    /// down the right-hand edge of the list the way they do in a menu.
    static let keyCap = Font.system(size: 10.5, weight: .semibold, design: .monospaced)
    /// The name of an action in the shortcut window. Proportional, unlike
    /// almost everything else here: this is prose to be read, not a value to be
    /// compared against the one above it.
    static let actionName = Font.system(size: 12, weight: .regular)
}

/// A short uppercase field label, spaced out like the legend on a piece of studio
/// hardware. Used for every readout in the status bar.
struct Eyebrow: View {
    @Environment(\.palette) private var palette
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Typography.eyebrow)
            .tracking(0.9)
            // Never wraps. A label squeezed narrow used to break one character
            // per line into a tall invisible column — the status bar's trailing
            // field is the only one without a fixed width, so at a narrow window
            // "LOADED IN" became a nine-line stack off the right edge and set the
            // whole bar's height. The visible symptom was a band of dead space
            // under the readouts with nothing in it.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(palette.dimmed.color())
    }
}
