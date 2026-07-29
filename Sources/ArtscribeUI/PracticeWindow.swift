import AppKit
import ArtscribeKit
import SwiftUI

/// **The Practice hub**: a loop that plays itself over and over while the speed
/// climbs, so a passage can be taken from slow to tempo without your hands
/// leaving the instrument.
///
/// The user's own idea, and the thing this app has that Transcribe! does not.
/// You give it three numbers — where to start, where to finish, how many
/// repetitions — and it works out the step and applies it on every wrap.
///
/// ## Why a window and not a panel
///
/// The same reason as Task 25's shortcut window, only more so: this is a thing
/// you *watch the waveform while using*. A panel inside the document window
/// could only exist by taking width from the waveform, which is the one surface
/// the loop you are practising is drawn on. A separate window costs it nothing,
/// can sit on a second display, and closes on its own.
///
/// ## What it draws, and what it does not
///
/// Everything here is a view over `ViewerModel.ramp` and the model's loop.
/// There is no state in this file at all beyond the two in-flight text-field
/// buffers, and no transport logic: Start calls `model.startRamp()`, and the
/// live readout reads `model.ramp`, which the loop wraps move. See
/// `ViewerModel+Practice`.
public struct PracticeWindow: View {
    private let context: MenuContext
    private let theme: ThemeController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Comfortably fits the three fields and the live readout, and small enough
    /// to park in a corner beside the document window. Hoisted out of the frame
    /// modifier so a test can check the two constants against each other.
    public static let minimumWidth: Double = 300
    public static let minimumHeight: Double = 330

    public init(context: MenuContext, theme: ThemeController) {
        self.context = context
        self.theme = theme
    }

    private var model: ViewerModel { context.model }
    private var appearance: Appearance { colorScheme == .dark ? .dark : .light }
    private var palette: Palette { Palette.of(appearance) }
    private var ramp: SpeedRamp { model.ramp }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(palette.rule.color()).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.canRamp {
                        scheduleFields
                        stepSummary
                        Rectangle().fill(palette.rule.color()).frame(height: 1)
                        liveState
                    } else {
                        NoLoopGuidance(hasTrack: model.hasTrack)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        .background(palette.background.color())
        .environment(\.palette, palette)
        .preferredColorScheme(theme.colorScheme)
        .background(WindowReader(onWindow: configure))
    }

    // MARK: - Chrome

    /// The Start/Stop button is **absent** with no loop, not present-and-disabled.
    ///
    /// Measured, not a preference: a disabled default button is drawn as a pale
    /// prominent button, and in the dark theme, in a key window, that is
    /// indistinguishable at a glance from a live one — the acceptance run's
    /// `26-practice-no-loop.png` showed a full-strength blue Start on a window
    /// that could not start anything. The empty state below already says what
    /// is missing and which keys fix it, so a control that cannot be used adds
    /// only the suggestion that it can.
    private var header: some View {
        HStack(spacing: 12) {
            Eyebrow("RAMPING LOOP")
            Spacer(minLength: 8)
            if model.canRamp {
                Button(startStopTitle) { model.toggleRamp() }
                    // Return runs it, which is what a keyboard-first app owes a
                    // window with one obvious action in it.
                    .keyboardShortcut(.defaultAction)
                    .help(
                        "Play the loop repeatedly while the speed walks from the start "
                            + "value to the end value")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.background.color())
    }

    /// "Start" when there is nothing running, and "Stop" when there is —
    /// including from a completed ramp, whose button says Start again because
    /// pressing it runs the whole thing from the top.
    private var startStopTitle: String { ramp.isRunning ? "Stop" : "Start" }

    // MARK: - The schedule

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            percentField(
                "Start speed", value: ramp.schedule.startRatio, set: model.setRampStartRatio)
            percentField("End speed", value: ramp.schedule.endRatio, set: model.setRampEndRatio)
            countField
        }
        // Editing the plan under a running ramp is refused on the model as well
        // (`setRampSchedule`); disabling here is what makes the refusal visible
        // rather than a control that silently does nothing.
        .disabled(ramp.isRunning)
        .opacity(ramp.isRunning ? 0.55 : 1)
    }

    /// One labelled percentage field.
    ///
    /// Edited in whole percent, which is the unit the readout, the presets and
    /// the `Q`/`W` steps are all already spoken in. Reads and writes through the
    /// model, which clamps — so a rejected value snaps the field to what was
    /// actually stored, the same validate-and-snap behaviour the Settings
    /// amounts have and the visible half of "never degrade silently".
    private func percentField(
        _ title: String, value: Double, set: @escaping (Double) -> Void
    ) -> some View {
        LabeledContent {
            HStack(spacing: 5) {
                TextField(
                    title,
                    value: Binding(
                        get: { (value * 100).rounded() },
                        set: { set($0 / 100) }),
                    format: .number.precision(.fractionLength(0))
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                Text("%").foregroundStyle(palette.dimmed.color())
            }
        } label: {
            Text(title).foregroundStyle(palette.text.color())
        }
    }

    private var countField: some View {
        LabeledContent {
            TextField(
                "Repetitions",
                value: Binding(
                    get: { ramp.schedule.repetitions },
                    set: { model.setRampRepetitions($0) }),
                format: .number
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
        } label: {
            Text("Repetitions").foregroundStyle(palette.text.color())
        }
    }

    /// The number the other three imply, which is the one the user would
    /// otherwise be doing in their head.
    private var stepSummary: some View {
        Text(PracticeReadout.step(ramp.schedule))
            .font(Typography.readoutSmall)
            .foregroundStyle(palette.dimmed.color())
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Where the ramp has got to

    /// **A practice tool whose progress is invisible is a stopwatch you cannot
    /// see.** Which repetition, at what speed, and how many are left.
    private var liveState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PracticeReadout.headline(ramp))
                .font(ramp.isIdle ? Typography.readout : Typography.readoutEmphasis)
                .foregroundStyle(
                    ramp.isIdle ? palette.dimmed.color() : palette.accent.color())

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Readout.percent(model.speed.ratio))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(
                        SpeedStepping.isAltered(model.speed.ratio)
                            ? palette.emphasis.color() : palette.text.color())
                Text(PracticeReadout.remaining(ramp))
                    .font(Typography.readoutSmall)
                    .foregroundStyle(palette.dimmed.color())
            }

            progressBar

            Text(PracticeReadout.loop(range: model.loop.range, sampleRate: model.sampleRate))
                .font(Typography.readoutSmall)
                .foregroundStyle(palette.dimmed.color())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Repetitions completed, as a bar.
    ///
    /// The fill is animated only when Reduce Motion is off, and even then over
    /// 0.12 s — this moves once per repetition, not continuously, so there is
    /// nothing here that needs to slide. With the setting on it simply
    /// redraws, which is spec §12's rule: turn the movement off rather than
    /// shorten it.
    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // `rule`, not `panel`: an unfilled bar has to be visible as a
                // bar, and `panel` against `background` is a two-value
                // difference in the dark theme — measured as an invisible track
                // on the first repetition, where the fill is legitimately zero.
                Capsule().fill(palette.rule.color())
                Capsule()
                    .fill(palette.loop.color())
                    .frame(width: geometry.size.width * ramp.progress)
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: ramp.progress)
        .accessibilityHidden(true)
    }

    /// Size and position remembered, by name — `setFrameAutosaveName` rather
    /// than scene restoration, for the reason `ShortcutWindow.configure` records:
    /// an unbundled `swift run` binary has no state-restoration file to write
    /// into, which is the configuration this project is actually run in.
    private func configure(_ window: NSWindow?) {
        // Reported so `⌘P` can tell "open and in front" from "open but behind"
        // — without it the toggle has no window to ask and could only ever open.
        context.practice.adopt(window: window)
        guard let window else { return }
        _ = window.setFrameAutosaveName(PracticeWindowController.windowID)
        window.isRestorable = true
    }
}

/// **What the window shows with no loop to ramp**, which is not nothing and is
/// not a disabled Start button on its own.
///
/// A ramp needs a region, so without one every control here would be inert. The
/// failure to avoid is the window that looks ready and silently does nothing
/// when pressed, so instead it says what is missing and exactly which keys fix
/// it — the two routes to a loop that this app actually has.
struct NoLoopGuidance: View {
    let hasTrack: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                hasTrack ? "A ramp needs a loop." : "Open a track, then set a loop.",
                systemImage: "repeat"
            )
            .font(Typography.readoutEmphasis)
            .foregroundStyle(palette.text.color())

            if hasTrack {
                Text(
                    "Put the playhead where the passage starts and press A, then where it "
                        + "ends and press S. Or drag a selection and press G to turn it into "
                        + "a loop.")
                Text(
                    "Starting a ramp switches looping on for you, so the loop does not have "
                        + "to be enabled first.")
            } else {
                Text("File ▸ Open… (⌘O), or drop an audio file on the window.")
            }
        }
        .font(Typography.readoutSmall)
        .foregroundStyle(palette.dimmed.color())
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
