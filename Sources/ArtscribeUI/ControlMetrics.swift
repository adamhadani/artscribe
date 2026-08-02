import SwiftUI

/// How big a control has to be **to be hit**, per input device.
///
/// The header's overflow menu was a 15 pt glyph with no frame around it, which
/// is a 15 × 15 pt target on a device operated by a fingertip. Apple's number
/// for that is **44 × 44 pt** and has been for as long as there has been a
/// touchscreen; the transport's buttons were 30 × 24, which is a comfortable
/// *pointer* target and half the height a thumb needs.
///
/// ## What the guidance actually says, and the part that matters here
///
/// > a button needs a hit region of at least 44x44 pt … in visionOS, 60x60 pt
///
/// **Hit region, not drawn size.** The visible chrome may be smaller than the
/// region that responds to it, and in a dense row it has to be: fourteen
/// transport buttons at 55 pt do not fit across an iPhone in landscape, and the
/// most-tapped control Apple ships — the system keyboard — puts its keys at
/// roughly 32 pt wide by 42 pt tall for exactly this reason. Height is the axis
/// a thumb is actually short of, and it is the axis nothing here is competing
/// for.
///
/// macOS has no stated minimum; the number the platform's own controls sit at,
/// and what the developer forums settle on for an image-only button, is 24 pt.
///
/// ## What derives from the target and what does not
///
/// `target` is the one figure taken from the guidance, and the things that
/// belong to the *control* fall out of it as ratios — width, spacing, corner
/// radius. Those ratios were derived from the Mac layout this file replaces: at
/// `target = 24` they reproduce its 30 × 24 button, 3 pt spacing and 5 pt
/// radius to within a fifth of a point. That is the check that they are the
/// right ratios, since the desktop numbers were arrived at by eye over many
/// iterations and a formula that had to be bent to fit them would be the wrong
/// formula.
///
/// The **whitespace** does not derive, and that distinction is the one thing
/// here learned the hard way rather than reasoned — see `groupPadding`.
///
/// Keyed on `EmptyStatePrompt.Surface` rather than `#if`, like every other
/// platform decision here, so all three readings are assertable from one
/// `make check` run — see `ControlMetricsTests`, which checks the HIG invariant
/// itself rather than the numbers.
public struct ControlMetrics: Equatable, Sendable {

    /// The smallest region a control may claim in its constrained axis.
    /// **The one figure taken from the guidance**; everything below is a ratio
    /// of it.
    public let target: CGFloat

    /// The height a bordered control is **drawn** at, which is not `target`.
    ///
    /// This is the other half of "hit region, not drawn size", and leaving it
    /// out was visible immediately: drawing the Open… button at the full 44 pt
    /// inside a header with 5 pt of padding gave a tall pill holding one short
    /// word, its border almost touching the rules above and below. A control
    /// that fills its bar edge to edge reads as a mistake however easy it is to
    /// hit.
    ///
    /// So the chrome is drawn at this, and `hitRegion(target:drawn:)` grows what
    /// *responds* out to `target` without taking that height in the layout. The
    /// bar keeps a margin, the control keeps its proportions, and a fingertip
    /// still gets its 44 pt.
    public let chromeHeight: CGFloat

    /// SF Symbol point size. Not a ratio of `target`: legibility and
    /// reachability scale differently — a pointer wants a small target and a
    /// normal-sized glyph, a finger wants a large target and a glyph only
    /// somewhat larger.
    public let glyph: CGFloat

    /// Vertical padding in the header, whose tallest item is a line of text.
    ///
    /// Not a ratio, and the two padding fields are not one field, because they
    /// are answering different questions. Here the padding *is* the bar's
    /// height, so on the Mac it is generous; on touch the 44 pt targets already
    /// set the height and the padding's only job is to stop short of stealing
    /// waveform — **iPhone is landscape-only, so the short axis is 402 pt** and
    /// every point the chrome takes comes off the instrument.
    public let barPadding: CGFloat

    /// Vertical padding in a dense control row, where the controls carry the
    /// height themselves and this is only the gap to the rules above and below.
    public let rowPadding: CGFloat

    /// Around a group of buttons, separating it from its neighbours, and at the
    /// ends of the bar.
    ///
    /// **These deliberately do not scale with `target`, and that was measured
    /// rather than reasoned.** The first version derived them — `target * 0.3`
    /// and `target * 0.42` — which is defensible until you count: on an iPhone
    /// it turned 70 pt of group padding into 132 and 20 pt of bar inset into
    /// 37, and the transport row overflowed the safe area on both sides, drawn
    /// under the notch. Whitespace is not a target. Reach is what needs 44 pt;
    /// a gap needs to look right, and a gap that looks right is nearly the same
    /// number on every device.
    public let groupPadding: CGFloat

    /// Horizontal padding at the ends of a bar. See `groupPadding`.
    public let barInset: CGFloat

    /// The narrowest a button in a **dense row** may be squeezed to when the
    /// row cannot fit its preferred width — an iPhone in landscape has 762 pt
    /// for fourteen transport buttons, a speed readout and a pitch slider, and
    /// something has to give.
    ///
    /// It gives in width only. See the type's comment: the keyboard's own keys
    /// are narrower than 44 and full height, and that is the trade every dense
    /// touch row makes.
    public let compactWidth: CGFloat

    // MARK: - Derived

    /// The height a button is **drawn** at. What *responds* is `target`, which
    /// `hitRegion(target:drawn:)` adds without taking the space.
    public var buttonHeight: CGFloat { chromeHeight }

    /// Preferred width. Slightly wider than tall, so a row of them reads as a
    /// row of keys rather than a strip of squares.
    public var buttonWidth: CGFloat { target * 1.25 }

    /// Between buttons within a group. Small enough that the group reads as one
    /// object, large enough that two targets do not merge.
    public var spacing: CGFloat { target / 8 }

    public var cornerRadius: CGFloat { target / 5 }

    // MARK: - Per surface

    public static func metrics(for surface: EmptyStatePrompt.Surface) -> ControlMetrics {
        switch surface {
        case .desktop:
            // 24 reproduces the hand-tuned Mac layout exactly. Nothing on that
            // platform moves as a result of this file existing, which is the
            // point: the Mac was not the thing that was hard to hit.
            // A pointer's target and a pointer's chrome are the same size —
            // there is nothing to separate. Nothing on the Mac moves.
            return ControlMetrics(
                target: 24, chromeHeight: 24, glyph: 13, barPadding: 9, rowPadding: 5,
                groupPadding: 7, barInset: 10, compactWidth: 30)
        case .tabletWithDrop, .phone:
            // Both are 44: the guidance does not distinguish a finger on an
            // iPad from a finger on a phone, and neither does a finger. What
            // differs is how much room the row has, and that is settled by
            // layout rather than by a constant — an iPad reaches the full
            // preferred width, a phone in landscape compresses toward
            // `compactWidth`.
            // 32 pt of chrome inside a 44 pt region. The paddings are then
            // what put the difference *around* each control rather than inside
            // it: a header of 32 + 8 + 8 = 48, a transport row of 32 + 6 + 6 =
            // 44, and in both the region a thumb gets is the full 44.
            return ControlMetrics(
                target: 44, chromeHeight: 32, glyph: 18, barPadding: 8, rowPadding: 6,
                groupPadding: 6, barInset: 10, compactWidth: 30)
        }
    }

    /// This build's metrics, before Dynamic Type.
    @MainActor public static var current: ControlMetrics {
        metrics(for: EmptyStatePrompt.current)
    }

    // MARK: - Dynamic Type

    /// The largest Dynamic Type growth these bars will follow.
    ///
    /// Not unbounded, and the reason is the one place this app has no room:
    /// **iPhone is landscape-only**, so the short axis is 402 pt and every
    /// point the header and transport take is a point the waveform loses. At
    /// the accessibility text sizes an unclamped `@ScaledMetric` is past 2×,
    /// which would leave the waveform — the instrument — as a stripe. Growing
    /// by a third covers the ordinary range of the Larger Text slider, which is
    /// where nearly everyone who moves it at all ends up.
    public static let maximumTypeScale: CGFloat = 1.35

    /// Grown by the user's text-size preference, clamped.
    ///
    /// Only `target`, `glyph` and `compactWidth` scale. The padding does not:
    /// it is whitespace, and whitespace growing with the text is how a bar ends
    /// up taller than the control it holds.
    public func scaled(by factor: CGFloat) -> ControlMetrics {
        let clamped = min(max(factor, 1), Self.maximumTypeScale)
        return ControlMetrics(
            target: target * clamped,
            chromeHeight: chromeHeight * clamped,
            glyph: glyph * clamped,
            barPadding: barPadding,
            rowPadding: rowPadding,
            groupPadding: groupPadding,
            barInset: barInset,
            compactWidth: compactWidth * clamped)
    }
}

extension View {
    /// Grows the region that answers a touch to `target`, **without taking that
    /// height in the layout**.
    ///
    /// Pad out, claim the padding as the content shape, pad back in. The view
    /// occupies what it draws, and a fingertip lands anywhere in the 44 pt band
    /// around it — which is what lets a bar keep its margins and its controls
    /// keep their proportions while still meeting the guidance.
    ///
    /// A no-op where the chrome is already at least `target`, which is every
    /// control on a Mac.
    func hitRegion(target: CGFloat, drawn: CGFloat) -> some View {
        let inset = Swift.max(0, (target - drawn) / 2)
        return
            self
            .padding(.vertical, inset)
            .contentShape(.rect)
            .padding(.vertical, -inset)
    }
}
