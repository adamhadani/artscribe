/// One physical key cap on the drawn keyboard.
///
/// A cap is a *place*, not a binding. What is bound to it is looked up per
/// layer from `ActionCatalog`, which is why this type carries no action: the
/// keyboard has to be able to draw the same cap four different ways as the
/// modifiers change, and a cap that owned its action could not.
public struct KeyCapSpec: Hashable, Sendable {
    /// The catalog token this cap stands for, or `nil` for a key nothing in
    /// this app can be bound to — the function row, `⌫`, `⏎`, `⇥`, `⇪`, `fn`.
    /// Those are drawn so the keyboard reads as a keyboard, and are always
    /// dimmed.
    public let token: KeyToken?
    /// The modifier this cap *is*, for the two `⇧`s, `⌥`, `⌘` and `⌃`.
    ///
    /// It is what lets the keyboard light the key you would hold to reach the
    /// layer that is showing — the shortest possible instruction for how the
    /// window works, drawn on the thing it is about.
    public let modifier: KeyModifiers?
    /// What is engraved on it.
    public let glyph: String
    /// Width in **units**, one unit being a letter key.
    public let width: Double
}

/// **The macOS keyboard, as data**, in the layout the user was shown during
/// brainstorming and chose this project's keymap from
/// (`.superpowers/brainstorm/…/keyboard.html`).
///
/// Rows of caps with unit widths, exactly as that mockup had them, plus the
/// three things it left out and this app needs: an `esc` (`selection.clear` is
/// bound to it), the four arrows as separate caps rather than one `↑↓` (volume
/// binds `↑` and `↓` to different actions), and the punctuation `,` and `/`
/// that `⌘,` and `⌘/` land on.
///
/// Every row is exactly `unitsPerRow` wide so the rows line up under one
/// another the way a real keyboard's do — `everyRowIsTheSameWidth` is the
/// guard, because a row that is a quarter-unit out reads as a broken picture
/// long before anyone works out why.
public enum KeyboardLayout {
    /// Every row is this many units wide. One unit is a letter key.
    public static let unitsPerRow: Double = 15

    public static let rows: [[KeyCapSpec]] = [
        functionRow, numberRow, upperRow, homeRow, lowerRow, bottomRow
    ]

    /// Where a token sits, or `nil` if the layout has no cap for it.
    ///
    /// Used by `everyBoundKeyHasACap` to prove no catalog chord is unshowable,
    /// which is the drift this window could otherwise introduce: a shortcut
    /// that exists, works, and is invisible in the one place that claims to
    /// list them all.
    public static func position(of token: KeyToken) -> (row: Int, column: Int)? {
        for (row, caps) in rows.enumerated() {
            if let column = caps.firstIndex(where: { $0.token == token }) {
                return (row, column)
            }
        }
        return nil
    }

    // MARK: - The rows

    /// `esc` carries `selection.clear`; the function keys are drawn because a
    /// keyboard without them does not read as one, and are bound to nothing.
    private static let functionRow: [KeyCapSpec] =
        [special(.escape, "esc", 1.5)]
        + (1...12).map { dead("F\($0)") }
        + [dead("⏻", 1.5)]

    private static let numberRow: [KeyCapSpec] =
        [key("`")]
        + "1234567890".map { key($0) }
        + [key("-"), key("="), dead("⌫", 2)]

    private static let upperRow: [KeyCapSpec] =
        [dead("⇥", 1.5)]
        + "qwertyuiop".map { key($0) }
        + [key("["), key("]"), key("\\", 1.5)]

    private static let homeRow: [KeyCapSpec] =
        [dead("⇪", 1.75)]
        + "asdfghjkl".map { key($0) }
        + [key(";"), key("'"), dead("⏎", 2.25)]

    private static let lowerRow: [KeyCapSpec] =
        [modifierKey(.shift, "⇧", 2.25)]
        + "zxcvbnm".map { key($0) }
        + [key(","), key("."), key("/"), modifierKey(.shift, "⇧", 2.75)]

    /// The arrows are four separate caps rather than the mockup's single `↑↓`:
    /// `↑` and `↓` are bound to different actions here (volume up and down), so
    /// one cap could only show half the truth.
    private static let bottomRow: [KeyCapSpec] = [
        dead("fn"),
        modifierKey(.control, "⌃"),
        modifierKey(.option, "⌥"),
        modifierKey(.command, "⌘", 1.25),
        special(.space, "space", 5.5),
        modifierKey(.command, "⌘", 1.25),
        modifierKey(.option, "⌥"),
        special(.leftArrow, "←", 0.75),
        special(.upArrow, "↑", 0.75),
        special(.downArrow, "↓", 0.75),
        special(.rightArrow, "→", 0.75)
    ]

    // MARK: - Builders

    /// A printable key. The engraving is what a US keyboard has on it, which
    /// for a letter is the uppercase form.
    private static func key(_ character: Character, _ width: Double = 1) -> KeyCapSpec {
        KeyCapSpec(
            token: .character(character), modifier: nil,
            glyph: String(character).uppercased(), width: width)
    }

    private static func special(
        _ token: KeyToken, _ glyph: String, _ width: Double
    ) -> KeyCapSpec {
        KeyCapSpec(token: token, modifier: nil, glyph: glyph, width: width)
    }

    private static func modifierKey(
        _ modifier: KeyModifiers, _ glyph: String, _ width: Double = 1
    ) -> KeyCapSpec {
        KeyCapSpec(token: nil, modifier: modifier, glyph: glyph, width: width)
    }

    private static func dead(_ glyph: String, _ width: Double = 1) -> KeyCapSpec {
        KeyCapSpec(token: nil, modifier: nil, glyph: glyph, width: width)
    }
}
