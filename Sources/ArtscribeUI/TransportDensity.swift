import SwiftUI

/// How tightly the transport bar has to pack itself to fit the width it has.
///
/// ## Why this is arithmetic and not `ViewThatFits`
///
/// It *was* `ViewThatFits`, with four candidate rows laid out widest-first. That
/// is the idiomatic answer and it produced the right pixels — and it cost too
/// much to keep. Every candidate is a whole transport bar: fourteen buttons,
/// each with a `GeometryReader` publishing its frame into the model for the
/// acceptance harness. Four candidates is **fifty-six** geometry readers writing
/// into `@Observable` state on every layout pass, each write inviting the next
/// pass.
///
/// It showed up as a *playback* failure, which is the part worth remembering:
/// `the playhead tracks real time at 1.0x` went from 0.608 s of travel per 0.6 s
/// of wall clock to 0.757 s — the audio was fine, the main thread was not, and
/// the harness's wall-clock sampling drifted 26%. Two runs on this branch failed
/// it and two at the merge-base passed, which is what separated a regression
/// from the environmental flake it first looked like.
///
/// So the row is built once and the width is *computed*. One row, fourteen
/// readers, and the decision is a pure function that a test can drive at any
/// width without a window.
struct TransportDensity: Equatable {

    /// What each button is drawn at.
    let buttonWidth: CGFloat

    /// Whether the speed readout, the pitch slider and the pitch label drop to
    /// their floors. Only the tightest density does this.
    let readoutsAtFloor: Bool

    /// The fixed costs of a row, which every candidate pays whatever the buttons
    /// are doing. Passed in rather than reached for, so the formula below is a
    /// function of its arguments and nothing else.
    struct Row: Equatable {
        let buttons: Int
        let groups: Int
        /// Gaps *within* groups — one fewer than the buttons in each, summed.
        let gaps: Int
        let speedPreferred: CGFloat
        let speedFloor: CGFloat
        let sliderPreferred: CGFloat
        let sliderFloor: CGFloat
        let labelPreferred: CGFloat
        let labelFloor: CGFloat
        /// The gap between the pitch slider and its readout.
        let pitchGap: CGFloat
        /// The minimum trailing spacer.
        let slack: CGFloat
    }

    /// What a row of this shape occupies. **This is the layout's own
    /// arithmetic**, so it is the one place to correct if the bar gains a
    /// control — and the reason `TransportBarView` reads its widths from here
    /// rather than keeping a second copy.
    static func width(
        buttonWidth: CGFloat, readoutsAtFloor: Bool, row: Row, metrics: ControlMetrics
    ) -> CGFloat {
        let readouts =
            readoutsAtFloor
            ? row.speedFloor + row.sliderFloor + row.labelFloor
            : row.speedPreferred + row.sliderPreferred + row.labelPreferred
        return CGFloat(row.buttons) * buttonWidth
            + CGFloat(row.gaps) * metrics.spacing
            + CGFloat(row.groups) * 2 * metrics.groupPadding
            // One rule between each pair of groups, and one before the pitch
            // control — which is `groups` of them, not `groups - 1`.
            + CGFloat(row.groups)
            + readouts
            + row.pitchGap
            + 2 * metrics.barInset
            + row.slack
    }

    /// The roomiest packing that fits `available`, or the tightest one if none
    /// does.
    ///
    /// Falling back to the tightest rather than to nothing is deliberate: a bar
    /// that overflows a little is recoverable, and `available` is zero on the
    /// very first layout pass, before any geometry has been measured. Starting
    /// tight and widening on the next pass is the direction to be wrong in —
    /// the other way round draws a row out under the notch for one frame.
    static func fitting(available: CGFloat, row: Row, metrics: ControlMetrics) -> TransportDensity {
        let candidates: [TransportDensity] = [
            .init(buttonWidth: metrics.buttonWidth, readoutsAtFloor: false),
            .init(buttonWidth: metrics.target, readoutsAtFloor: false),
            .init(buttonWidth: metrics.compactWidth, readoutsAtFloor: false),
            .init(buttonWidth: metrics.compactWidth, readoutsAtFloor: true)
        ]
        for candidate in candidates {
            let needed = width(
                buttonWidth: candidate.buttonWidth,
                readoutsAtFloor: candidate.readoutsAtFloor,
                row: row, metrics: metrics)
            if needed <= available { return candidate }
        }
        return candidates[candidates.count - 1]
    }
}
