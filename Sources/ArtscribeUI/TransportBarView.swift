import ArtscribeKit
import SwiftUI

/// The transport: a row of control-surface buttons directly above the status
/// bar.
///
/// It is a **second front-end**, not a second implementation. Every button calls
/// `ViewerModel.perform(_:)` with its `TransportControl` and nothing else, and
/// every one of those cases is a single call to the method the keyboard already
/// invokes. Presentation — symbol, title, enablement, on-state — comes from
/// `TransportControl`, which is a pure value and is unit-tested; nothing in this
/// file decides anything.
///
/// ## Why it must not take focus
///
/// The window's keyboard handling lives on a `.focusable()` `DocumentView` with
/// a `@FocusState`. macOS moves first-responder status to a control when it is
/// clicked, and SwiftUI's default `Button` participates; after one click, Space
/// would go to the button — "play" would become "press whatever I clicked last",
/// which in a keyboard-first app is the whole product.
///
/// Two defences, both needed:
/// * `.buttonStyle(.plain)` with `.focusable(false)` on the row, so the buttons
///   are not in the focus chain to begin with.
/// * `restoreFocus`, called after **every** press, which puts the `@FocusState`
///   back on the document. Belt and braces: whether the first defence is enough
///   depends on SwiftUI's control implementation, which is not ours to rely on,
///   and the cost of being wrong is that the app stops responding to Space.
struct TransportBarView: View {
    let model: ViewerModel
    /// Hands the keyboard back to the document view after a press. See above —
    /// this is not optional politeness.
    let restoreFocus: () -> Void
    @Environment(\.palette) private var palette

    /// Big enough to hit without aiming, which is what "control surface rather
    /// than toolbar afterthought" means in points — and on touch that phrase
    /// has an actual number behind it. See `ControlMetrics`.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1
    private var metrics: ControlMetrics { ControlMetrics.current.scaled(by: typeScale) }

    /// The three readouts in this bar are **text**, not targets, so they take
    /// `@ScaledMetric` directly rather than going through `ControlMetrics` — a
    /// readout has to fit its digits at whatever size the user reads at, which
    /// is a different question from how big a thumb is.
    ///
    /// Each has a floor beneath it, reached only by the tightest density in
    /// `body`: fourteen finger-sized buttons, a speed readout and a pitch
    /// slider do not all fit across an iPhone in landscape, and something has
    /// to give. The floors are where each still holds its widest string —
    /// `62.5%`, a slider you can still aim at, `+12`.
    ///
    /// Nothing moves on a Mac or a full-size iPad, which take a density that
    /// uses the preferred widths — so the bar still does not reflow as `100%`
    /// becomes `62.5%`.
    @ScaledMetric(relativeTo: .body) private var speedWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .body) private var speedFloor: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var sliderWidth: CGFloat = 92
    @ScaledMetric(relativeTo: .body) private var sliderFloor: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var pitchLabelWidth: CGFloat = 58
    @ScaledMetric(relativeTo: .body) private var pitchLabelFloor: CGFloat = 40

    private var state: TransportState { model.transportState }

    /// The width this bar has been given. Measured off a frame pinned to the
    /// proposal, so it is what the *container* offers and never what the
    /// content demanded — measuring the content would make the density depend
    /// on itself.
    @State private var available: CGFloat = 0

    var body: some View {
        let density = TransportDensity.fitting(available: available, row: row, metrics: metrics)
        bar(
            buttonWidth: density.buttonWidth,
            readouts: density.readoutsAtFloor ? .floor : .preferred
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            available = $0
        }
        .background(palette.background.color())
        .overlay(alignment: .top) {
            Rectangle().fill(palette.rule.color()).frame(height: Metrics.hairline)
        }
        // The row itself is out of the focus chain, so a click cannot land
        // the keyboard here even before `restoreFocus` runs.
        .focusable(false)
    }

    /// This bar's shape, handed to the arithmetic in `TransportDensity`.
    private var row: TransportDensity.Row {
        TransportDensity.Row(
            buttons: TransportControl.allCases.count,
            groups: TransportControl.groups.count,
            gaps: TransportControl.groups.reduce(0) { $0 + max(0, $1.count - 1) },
            speedPreferred: speedWidth, speedFloor: speedFloor,
            sliderPreferred: sliderWidth, sliderFloor: sliderFloor,
            labelPreferred: pitchLabelWidth, labelFloor: pitchLabelFloor,
            pitchGap: Metrics.sm, slack: Metrics.md)
    }

    /// How much room the three readouts get. Two settings rather than a scale
    /// factor: there is a width at which each still holds its widest string —
    /// `62.5%`, a slider you can still aim at, `+12` — and no reason to sit
    /// anywhere between that and the comfortable one.
    private enum ReadoutWidth {
        case preferred
        case floor
    }

    private func bar(buttonWidth: CGFloat, readouts: ReadoutWidth) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(TransportControl.groups.enumerated()), id: \.offset) { index, controls in
                if index > 0 { separator }
                row(controls, buttonWidth: buttonWidth, readouts: readouts)
            }
            separator
            pitchControl(readouts)
            Spacer(minLength: Metrics.md)
        }
        .padding(.horizontal, metrics.barInset)
        .padding(.vertical, metrics.rowPadding)
    }

    @ViewBuilder
    private func row(
        _ controls: [TransportControl], buttonWidth: CGFloat, readouts: ReadoutWidth
    ) -> some View {
        HStack(spacing: metrics.spacing) {
            ForEach(controls, id: \.self) { control in
                button(control, width: buttonWidth)
                // The speed sits *between* its two buttons, where a mixer would
                // put the value it steps.
                if control == .slower { speedReadout(readouts) }
            }
        }
        .padding(.horizontal, metrics.groupPadding)
    }

    private var separator: some View {
        Rectangle().fill(palette.rule.color())
            .frame(width: Metrics.hairline, height: metrics.target * 0.67)
    }

    private func button(_ control: TransportControl, width: CGFloat) -> some View {
        let enabled = control.isEnabled(in: state)
        let isOn = control.isOn(in: state)
        return Button {
            model.perform(control)
            restoreFocus()
        } label: {
            Image(systemName: control.symbol(in: state))
                .font(.system(size: metrics.glyph, weight: .medium))
                // Whatever width the chosen density settled on — see `body`.
                // **Height never varies**, because height is the axis a thumb
                // is actually short of and the axis nothing here competes for.
                .frame(width: width, height: metrics.buttonHeight)
                .foregroundStyle(tint(enabled: enabled, isOn: isOn))
                .background(
                    RoundedRectangle(cornerRadius: metrics.cornerRadius)
                        .fill(
                            isOn
                                ? palette.loop.color(opacity: 0.22)
                                : palette.panel.color(opacity: enabled ? 1 : 0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.cornerRadius)
                        .stroke(
                            isOn ? palette.loop.color() : palette.rule.color(),
                            lineWidth: isOn ? 1.5 : 1)
                )
                .contentShape(Rectangle())
                .hitRegion(target: metrics.target, drawn: metrics.buttonHeight)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(control.tooltip(in: state))
        .accessibilityLabel(control.title(in: state))
        // Where this control landed, so the acceptance harness can click the
        // real button instead of hard-coding a layout — the same seam the lanes
        // and the overview strip already publish.
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear {
                    model.setTransportFrame(proxy.frame(in: .global), for: control)
                }
                .onChange(of: proxy.frame(in: .global)) { _, frame in
                    model.setTransportFrame(frame, for: control)
                }
            })
    }

    /// An engaged loop is a *mode*, and a mode has to be readable at a glance:
    /// the loop's own violet, not the generic accent, because that is the colour
    /// the loop already wears on the lanes.
    private func tint(enabled: Bool, isOn: Bool) -> Color {
        guard enabled else { return palette.dimmed.color(opacity: 0.5) }
        return isOn ? palette.loop.color() : palette.text.color()
    }

    /// Between `−` and `+`, carrying the status bar's emphasis rule — the same
    /// `SpeedStepping.isAltered` both readouts ask, so they cannot disagree
    /// about what "not normal speed" looks like.
    private func speedReadout(_ readouts: ReadoutWidth) -> some View {
        Text(state.speedLabel)
            .font(state.speedIsEmphasised ? Typography.readoutEmphasis : Typography.readout)
            .monospacedDigit()
            .foregroundStyle(
                state.hasTrack
                    ? (state.speedIsEmphasised ? palette.emphasis.color() : palette.text.color())
                    : palette.dimmed.color()
            )
            .frame(width: readouts == .floor ? speedFloor : speedWidth)
            .help("Speed  (1–4, Q, W)")
    }

    /// Transposition, beside the speed it is independent of.
    ///
    /// **A slider rather than the −/+ buttons the speed uses.** Pitch has a
    /// natural centre and a symmetric range, so a slider shows *where you are*
    /// in that range at a glance and returns to the middle by feel; speed has
    /// neither property. The keyboard remains the precise route — the slider
    /// steps in semitones, and `⇧[`/`⇧]` reach the cents it cannot.
    ///
    /// Bound through `setPitch(cents:)` rather than to `model.pitch` directly,
    /// so a drag goes down the same path as a key press and there is still one
    /// place a pitch reaches the render thread.
    private func pitchControl(_ readouts: ReadoutWidth) -> some View {
        HStack(spacing: Metrics.sm) {
            Slider(
                value: Binding(
                    get: { Double(model.pitch.cents) },
                    set: { model.setPitch(cents: Int($0.rounded())) }
                ),
                in: Double(PitchState.minCents)...Double(PitchState.maxCents),
                step: Double(PitchState.centsPerSemitone)
            )
            // Read off the metric rather than off the platform: a mini slider's
            // thumb is a pointer-sized grab, and where the row is sized for a
            // fingertip the thumb has to be too.
            .controlSize(metrics.target >= 44 ? .regular : .mini)
            .frame(
                width: readouts == .floor ? sliderFloor : sliderWidth,
                height: metrics.buttonHeight
            )
            .disabled(!state.hasTrack)
            .help("Pitch, independent of speed  ([, ], ⇧ for cents, ⌥] to reset)")

            Text(model.pitchLabel.isEmpty ? "±0" : model.pitchLabel)
                .font(
                    model.pitch.isAltered ? Typography.readoutEmphasis : Typography.readout
                )
                .monospacedDigit()
                .foregroundStyle(
                    state.hasTrack
                        ? (model.pitch.isAltered
                            ? palette.emphasis.color() : palette.text.color())
                        : palette.dimmed.color()
                )
                .frame(
                    width: readouts == .floor ? pitchLabelFloor : pitchLabelWidth,
                    alignment: .leading)
        }
    }
}
