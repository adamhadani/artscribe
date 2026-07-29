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
    /// than toolbar afterthought" means in points.
    private static let glyphSize: CGFloat = 13
    private static let buttonSize = CGSize(width: 30, height: 24)

    private var state: TransportState { model.transportState }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(TransportControl.groups.enumerated()), id: \.offset) { index, controls in
                if index > 0 { separator }
                row(controls)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(palette.background.color())
        .overlay(alignment: .top) {
            Rectangle().fill(palette.rule.color()).frame(height: 1)
        }
        // The row itself is out of the focus chain, so a click cannot land the
        // keyboard here even before `restoreFocus` runs.
        .focusable(false)
    }

    @ViewBuilder
    private func row(_ controls: [TransportControl]) -> some View {
        HStack(spacing: 3) {
            ForEach(controls, id: \.self) { control in
                button(control)
                // The speed sits *between* its two buttons, where a mixer would
                // put the value it steps.
                if control == .slower { speedReadout }
            }
        }
        .padding(.horizontal, 7)
    }

    private var separator: some View {
        Rectangle().fill(palette.rule.color()).frame(width: 1, height: 16)
    }

    private func button(_ control: TransportControl) -> some View {
        let enabled = control.isEnabled(in: state)
        let isOn = control.isOn(in: state)
        return Button {
            model.perform(control)
            restoreFocus()
        } label: {
            Image(systemName: control.symbol(in: state))
                .font(.system(size: Self.glyphSize, weight: .medium))
                .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
                .foregroundStyle(tint(enabled: enabled, isOn: isOn))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            isOn
                                ? palette.loop.color(opacity: 0.22)
                                : palette.panel.color(opacity: enabled ? 1 : 0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isOn ? palette.loop.color() : palette.rule.color(),
                            lineWidth: isOn ? 1.5 : 1)
                )
                .contentShape(Rectangle())
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
    private var speedReadout: some View {
        Text(state.speedLabel)
            .font(state.speedIsEmphasised ? Typography.readoutEmphasis : Typography.readout)
            .monospacedDigit()
            .foregroundStyle(
                state.hasTrack
                    ? (state.speedIsEmphasised ? palette.emphasis.color() : palette.text.color())
                    : palette.dimmed.color()
            )
            .frame(width: 46)
            .help("Speed  (1–4, Q, W)")
    }
}
