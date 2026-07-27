import CoreGraphics
import SwiftUI

/// One packed sRGB colour, usable both as a SwiftUI `Color` and as a `CGColor`
/// for the bitmap waveform renderer. Keeping a single source for both avoids the
/// two drawing paths drifting apart.
struct RGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ packed: UInt32) {
        red = Double((packed >> 16) & 0xFF) / 255
        green = Double((packed >> 8) & 0xFF) / 255
        blue = Double(packed & 0xFF) / 255
    }

    func color(opacity: Double = 1) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    func cgColor(opacity: Double = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}

/// The palette agreed in the design mockups (spec §7). Dark-first; there is no
/// light variant yet, so nothing here reads the environment colour scheme.
enum Palette {
    static let background = RGB(0x13_1417)
    static let panel = RGB(0x1B_1D22)
    static let waveform = RGB(0x7A_889A)
    static let selection = RGB(0xF0_A35E)
    static let accent = RGB(0x4F_D1C5)
    static let text = RGB(0xC9_CED6)
    static let dimmed = RGB(0x6F_7783)
    static let danger = RGB(0xE0_6C63)
    /// The loop region. Deliberately neither the selection amber nor the accent
    /// teal: the loop and the selection are shown at the same time and mean
    /// different things, so they must not be told apart by brightness alone.
    static let loop = RGB(0x8C_7BE6)

    /// Hairline between panels. Derived from `panel` so the chrome stays in family.
    static let rule = RGB(0x2A_2D34)

    /// A readout that is deliberately not at its default value — currently only
    /// the speed. Shares the selection's amber on purpose: amber is already this
    /// palette's "you changed something" colour, and the two never appear in the
    /// same place (one is a wash over the waveform, the other one word of text).
    /// Not the accent teal, which is spoken for by the playhead and the playing
    /// position and would make an altered speed look like a transport state.
    static let emphasis = selection

    static let selectionFillOpacity: Double = 0.13
    static let selectionEdgeWidth: Double = 2

    /// Height of the bar drawn along the top and bottom of the lanes to mark the
    /// loop region. A bar, not a full-height wash: the selection already owns
    /// the full height, and two overlapping washes are unreadable.
    static let loopBarHeight: Double = 4
    /// A loop region that exists but is switched off is still shown, because
    /// having set it is worth remembering — just visibly inert.
    static let loopDisabledOpacity: Double = 0.3
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
}

/// A short uppercase field label, spaced out like the legend on a piece of studio
/// hardware. Used for every readout in the status bar.
struct Eyebrow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Typography.eyebrow)
            .tracking(0.9)
            .foregroundStyle(Palette.dimmed.color())
    }
}
