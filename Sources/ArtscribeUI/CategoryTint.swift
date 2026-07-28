/// **How the keyboard is read at a glance**: one hue per category, drawn on the
/// key and repeated in the legend.
///
/// This is the mockup's device (`.superpowers/brainstorm/…/keyboard.html`) with
/// its three bands widened to the nine the catalog actually has. That mockup
/// tinted three groups — "reachable without looking", "speed & loop", "⌘ menu
/// commands" — and the user picked this project's keymap off it, so the design
/// language is kept and only the resolution changed.
///
/// **Both themes are designed, neither is inverted.** A tint bright enough to
/// glow on `0x22252C` is a pastel smear on white, so the light theme takes the
/// same nine hues down rather than washing them out. Every value below was
/// measured, not eyeballed: the glyph and its label are drawn *in* the tint on
/// a key filled with the same tint at low alpha, and every one of the eighteen
/// clears **4.5:1** against that fill — dark 4.75–6.00, light 5.51–7.04.
/// `categoryTintsAreDistinct` is the guard that no two categories collapse into
/// one colour.
extension ActionCategory {

    /// The category's hue in the appearance on screen.
    public func tint(_ appearance: Appearance) -> RGB {
        appearance == .light ? Self.lightTints[self] ?? .neutral : Self.darkTints[self] ?? .neutral
    }

    /// Bright inks for the dark theme, in the order the reference lists them.
    private static let darkTints: [ActionCategory: RGB] = [
        .transport: RGB(0x4F_D1C5),  // teal — the accent, and the transport is the app
        .navigation: RGB(0x5F_C2EE),  // sky
        .loop: RGB(0xB4_A6F8),  // violet, the loop's colour on the lanes
        .selection: RGB(0xF0_A35E),  // amber, the selection's colour on the lanes
        .speed: RGB(0xE9_CE6A),  // gold
        .volume: RGB(0x86_D992),  // green
        .view: RGB(0x9A_B2EE),  // periwinkle
        .file: RGB(0xE8_9BCE),  // pink
        .application: RGB(0xE8_A19B)  // clay
    ]

    /// Deep inks for the light theme. Same nine hues, taken down rather than
    /// washed out, so the two themes are recognisably the same instrument.
    private static let lightTints: [ActionCategory: RGB] = [
        .transport: RGB(0x08_6259),
        .navigation: RGB(0x0F_5C7E),
        .loop: RGB(0x53_40C4),
        .selection: RGB(0x8A_4B05),
        .speed: RGB(0x6B_5304),
        .volume: RGB(0x18_663A),
        .view: RGB(0x33_468F),
        .file: RGB(0x8A_2470),
        .application: RGB(0x9E_3A32)
    ]
}

extension RGB {
    /// The fallback a `nil` lookup can never actually reach —
    /// `categoryTintsAreDistinct` walks `allCases` — but which keeps the tint
    /// accessor total rather than optional at every call site.
    static let neutral = RGB(0x8B_939F)
}

/// The geometry and the two theme-dependent greys the drawn keyboard needs,
/// kept out of `Palette` because nothing else in the app draws a key cap.
enum KeyCapStyle {
    /// The surface of an unlit key. Deliberately *lighter* than `panel` in dark
    /// and pure white in light: a key is a raised thing, and the one shape has
    /// to read as raised over either background.
    static func surface(_ appearance: Appearance) -> RGB {
        appearance == .light ? RGB(0xFF_FFFF) : RGB(0x22_252C)
    }

    /// The engraving on a key that nothing is bound to. Its own value rather
    /// than `palette.dimmed`, which is tuned against `panel` and lands at
    /// 3.4:1 here; these clear 4.7:1 on the key surface, because "this key does
    /// nothing on this layer" is information and not decoration.
    static func unboundGlyph(_ appearance: Appearance) -> RGB {
        appearance == .light ? RGB(0x6B_7382) : RGB(0x8B_939F)
    }

    /// How strongly a bound key is washed with its category's tint. The light
    /// theme takes less: the same alpha of a deep ink over white reads heavier
    /// than a bright one over near-black.
    static func fillOpacity(_ appearance: Appearance) -> Double {
        appearance == .light ? 0.13 : 0.20
    }

    /// The mockup's `.dead` opacity, kept: it is what makes the bound keys read
    /// as a shape rather than as scattered colour.
    static let unboundOpacity: Double = 0.45
    /// A bound key the filter has excluded. Not as far down as an unbound one —
    /// it still does something, it just is not what was typed.
    static let filteredOpacity: Double = 0.28
}
