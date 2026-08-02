import Foundation

/// What a key on the keyboard map says under its glyph.
///
/// ## Why the caption is shortened rather than shrunk
///
/// The cap used to carry `minimumScaleFactor(0.55)`, which fits anything — by
/// drawing it smaller. So `Loop` sat at full size beside `Move Selection Left`
/// at little over half of it, and a board of thirty keys had three or four type
/// sizes on it. Uniform and legible beats fitted: a reference you read at a
/// glance cannot have its longest entries be its least readable ones.
///
/// So the type size is fixed and the *words* give instead. Only where they have
/// to: a caption that already fits is returned untouched, which is nearly all of
/// them — `Selection → Loop` wraps to two lines and stays exactly as it is.
///
/// Pure and parameterised by how much room a cap has, so the rule is checkable
/// against every entry in the catalog at every plausible key size without
/// rendering a keyboard.
enum KeyCapCaption {

    /// **Short names for the keyboard map.**
    ///
    /// A handful of actions have menu titles that no key cap can hold at any
    /// readable size — `Move Loop Out Right (Far)` is five words. Mechanical
    /// abbreviation produces `Mv Loop Out Rt (Far)`, which is worse than small
    /// text; what a keyboard map wants is a *short name*, and the long one is
    /// still there in the list beside the board and in the menus.
    ///
    /// Keyed on the full title so the catalog stays the single source of what
    /// an action is called, and so an entry renamed without updating this shows
    /// up as a caption that no longer fits — which `theCatalogFits` turns into
    /// a failing test rather than a smear on a board.
    static let shortTitles = [
        "Play from Start": "From Start",
        "Nudge Back (Fine)": "Nudge ← fine",
        "Nudge Forward (Fine)": "Nudge → fine",
        "Move Selection Left": "Sel. ←",
        "Move Selection Right": "Sel. →",
        "Move Selection Left (Far)": "Sel. ← far",
        "Move Selection Right (Far)": "Sel. → far",
        "Move Loop In Left": "Loop In ←",
        "Move Loop In Right": "Loop In →",
        "Move Loop Out Left": "Loop Out ←",
        "Move Loop Out Right": "Loop Out →",
        "Move Loop In Left (Far)": "Loop In ← far",
        "Move Loop In Right (Far)": "Loop In → far",
        "Move Loop Out Left (Far)": "Loop Out ← far",
        "Move Loop Out Right (Far)": "Loop Out → far",
        "Move Loop Left": "Loop ←",
        "Move Loop Right": "Loop →",
        "Move Loop Left (Far)": "Loop ← far",
        "Move Loop Right (Far)": "Loop → far",
        "Volume Up (Fine)": "Vol. ↑ fine",
        "Volume Down (Fine)": "Vol. ↓ fine",
        "About Artscripture": "About"
    ]

    /// Words too long for a key cap, and what they become on one. Deliberately
    /// tiny: an abbreviation the reader has to decode is worse than a wrap, so
    /// this earns entries one at a time.
    static let abbreviations = ["Selection": "Sel."]

    /// The smallest a caption may be drawn relative to the board's own size.
    ///
    /// Shortening the words handles the base layer; a few modifier-layer
    /// titles — `Move Loop In Right (Far)` is the worst — are five words long
    /// and fit no two-line cap at any size, so something has to give. A fifth
    /// is a difference you have to look for, against 45% before this, and it
    /// is bounded: `captionFits` asserts every entry in the catalog lands
    /// inside it, so a new action that would truncate fails a test rather than
    /// a reader.
    static let minimumScale: Double = 0.8

    /// Roughly how wide a character of the caption font is, as a fraction of
    /// its point size. The system font at these sizes averages a little over
    /// half an em; erring high means erring toward abbreviating something that
    /// would just about have fitted, which is the harmless direction.
    static let characterWidthRatio: Double = 0.58

    /// How many characters of caption fit across a cap of `width`.
    static func charactersPerLine(width: Double, labelSize: Double) -> Int {
        guard labelSize > 0 else { return 0 }
        return max(1, Int(width / (labelSize * characterWidthRatio)))
    }

    /// Whether `text` can be broken across at most `lines` lines of
    /// `perLine` characters, breaking only at spaces — which is what the text
    /// engine will do with it.
    static func fits(_ text: String, perLine: Int, lines: Int) -> Bool {
        var used = 1
        var room = perLine
        for word in text.split(separator: " ") {
            let length = word.count
            // A word longer than the line can never be placed. Reporting that
            // as "does not fit" is what sends it to the abbreviations.
            if length > perLine { return false }
            if length <= room {
                room -= length + 1  // the space after it
            } else {
                used += 1
                room = perLine - length - 1
            }
        }
        return used <= lines
    }

    /// The caption for `title` on a cap with this much room.
    static func caption(for title: String, perLine: Int, lines: Int = 2) -> String {
        // The authored short name wins wherever there is one — including when
        // the full title happens to fit, so a cap does not change its wording
        // as the window is resized.
        if let short = shortTitles[title] { return short }
        if fits(title, perLine: perLine, lines: lines) { return title }
        return
            title
            .split(separator: " ")
            .map { abbreviations[String($0)] ?? String($0) }
            .joined(separator: " ")
    }
}
