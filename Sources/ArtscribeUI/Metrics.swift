import SwiftUI

/// **The third leg of this app's design tokens.**
///
/// `Palette` already centralises colour and `Typography` centralises type;
/// spacing and size were the one axis still written as literals at the point of
/// use — 45 `.padding`s, 64 `spacing:`es and 16 corner radii across fifteen
/// files, so that "make the gaps in the shortcut list a little tighter" meant
/// finding every one of them and hoping. This is where they live now.
///
/// ## What is here and what is not
///
/// The rule, and it is the one most codebases converge on: **a value shared
/// across views is a token; a value used once stays a named constant in the
/// view that uses it.** A global called `practiceRepetitionColumnWidth` used in
/// exactly one file is not centralisation, it is indirection — the reader has
/// to jump to another file to learn a number that was only ever relevant where
/// they were standing. So the sheet paddings, the readout column widths and the
/// drop-zone insets stay put, as `private static let`s with names.
///
/// Three neighbours own their own numbers and are deliberately not folded in:
///
/// * `ControlMetrics` — hit targets. Those are not a matter of taste, they come
///   from Apple's guidance and vary by input device.
/// * `Typography` — type sizes.
/// * `StatusBarFields` — the status bar's column widths, which are a function
///   of the widest string each field can hold.
///
/// ## The scale
///
/// A **2 pt grid**, because that is what the hand-tuned values were already
/// nearly on: of the 125 spacing literals this replaced, all but a handful were
/// even, and snapping the rest moved them by at most one point. Anything
/// coarser would have meant real visual change to a layout that had been
/// iterated on by eye; anything finer is not a scale.
///
/// Named for size rather than for role. Role names (`cardGap`, `chipGap`,
/// `sectionGap`) sound more principled and are worse here: three quarters of
/// them would have exactly one caller, and a reader who wants to know whether
/// two gaps match should be able to see it without resolving two names.
enum Metrics {

    /// A rule, a stroke, a divider. The one value that is not on the grid,
    /// because it is not spacing — it is the thinnest line that draws.
    static let hairline: CGFloat = 1

    /// A label sitting directly over the value it names, or the inside of a
    /// key cap. Deliberately almost touching.
    static let xxs: CGFloat = 2

    /// Chips in a row, a stack of two lines that belong together.
    static let xs: CGFloat = 4

    /// A symbol and the word beside it.
    static let sm: CGFloat = 6

    /// Two related items in a row.
    static let md: CGFloat = 8

    /// Two rows, or two items that merely share a line.
    static let lg: CGFloat = 10

    /// Separate controls in a panel.
    static let xl: CGFloat = 12

    /// Blocks of a page.
    static let xxl: CGFloat = 16

    /// **The app's standard margin.** The horizontal inset of every bar — the
    /// header, the status bar, the banners, the shortcut window's footer — and
    /// the gap between top-level items inside them. Twelve call sites before
    /// this existed, which is what makes it a token rather than a constant.
    static let gutter: CGFloat = 14

    /// The widest a column of prose is allowed to get.
    ///
    /// A measure, not a layout: past roughly this width the eye loses the start
    /// of the next line, which is why the empty state, the welcome pages and
    /// the settings panes all stop here rather than filling the window.
    static let readingWidth: CGFloat = 460

    /// The coloured dot that stands for an action's category.
    static let swatch: CGFloat = 9

    /// The coloured stripe down the leading edge of a banner.
    static let accentBar: CGFloat = 2

    /// Corner radii, by the kind of thing being rounded rather than by size —
    /// here the role names earn their keep, because the question a reader has
    /// is "is this rounded like the other buttons?" and not "is this 5".
    enum Radius {
        /// A shortcut chip, a key cap in the list, a track-marker label.
        static let chip: CGFloat = 4
        /// A button, a text field, a key cap on the keyboard map.
        static let control: CGFloat = 5
        /// A category swatch — barely rounded, so it reads as a square.
        static let swatch: CGFloat = 2
        /// A recent-file row, an inline badge.
        static let badge: CGFloat = 6
        /// A card, a dashed drop zone.
        static let panel: CGFloat = 10
    }

    /// The padding inside a chip: a key cap, a shortcut badge, a marker label.
    /// One value rather than two call sites per chip, because a chip that is
    /// tight vertically and loose horizontally is the whole look and the two
    /// numbers only make sense together.
    static let chipInsets = EdgeInsets(top: xxs, leading: sm, bottom: xxs, trailing: sm)
}
