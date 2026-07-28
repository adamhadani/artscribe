/// Where the shortcut window divides between the keyboard and the list, and
/// what stops either side being crushed.
///
/// Pure arithmetic on purpose. The window's two panes want opposite things —
/// the keyboard is *width*-bound (fifteen units across, six rows of 0.92 down,
/// so it is a 2.7:1 object that can only grow taller by growing wider) while the
/// list wants a column it can read a chord in — and the only honest way to
/// settle that is to let the reader move the divider. Everything about where it
/// may go lives here, where it can be tested, rather than in a gesture.
public enum ShortcutSplit {

    /// The hairline, in layout terms. The *hit* area is wider (see
    /// `ShortcutWindow.divider`); this is the width the panes lose to it.
    public static let dividerWidth: Double = 1

    /// Narrow enough to still be a keyboard: below this the caps stop carrying
    /// their labels (`KeyboardMetrics.showsLabels`) and the board is a row of
    /// coloured tiles.
    public static let minimumKeyboardWidth: Double = 430

    /// Narrow enough to still be a list: an action title and its key cap on one
    /// line, which is the whole point of the right-hand pane.
    public static let minimumListWidth: Double = 260

    /// What the list gets when nobody has moved anything.
    ///
    /// Wider than the 310 the first cut used. The list is the pane that has to
    /// hold "Move Loop Out Right (Far)" and a two-cap chord on one line, and the
    /// width it does not take is width the keyboard turns into height — which is
    /// the trade the divider exists to let the reader make either way.
    public static let defaultListWidth: Double = 340

    /// The list's width, given the whole width available to both panes *and*
    /// the divider.
    ///
    /// - Parameters:
    ///   - preferred: what the reader last dragged it to.
    ///   - totalWidth: the content width of the window, divider included.
    ///
    /// Below `minimumKeyboardWidth + minimumListWidth + dividerWidth` neither
    /// minimum can be honoured — the window's own minimum size forbids it, but a
    /// layout pass can still propose a width of zero on the way to the real one,
    /// and a negative frame is a crash waiting for a resize. So the two minima
    /// are shared out in proportion rather than clamped into a contradiction.
    public static func listWidth(preferred: Double, totalWidth: Double) -> Double {
        let panes = max(0, totalWidth - dividerWidth)
        let floorSum = minimumKeyboardWidth + minimumListWidth
        guard panes >= floorSum else {
            return panes * (minimumListWidth / floorSum)
        }
        return min(max(preferred, minimumListWidth), panes - minimumKeyboardWidth)
    }
}
