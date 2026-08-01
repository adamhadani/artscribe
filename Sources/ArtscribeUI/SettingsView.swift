import SwiftUI

/// **Artscripture ▸ Settings…** (⌘,), the content of SwiftUI's `Settings` scene.
///
/// In the app menu rather than under File: that is where macOS has put
/// preferences since Ventura, and it is where the `Settings` scene puts them
/// automatically, complete with ⌘, — so nothing here hand-rolls a window or a
/// shortcut.
///
/// Two tabs, and deliberately no third. Theme moved here out of `View ▸ Theme`
/// the moment there was a Settings window to move it into: two preference
/// surfaces is one too many, and the state did not move with it — the control
/// still points at the same `ThemeController` the menu did.
public struct SettingsView: View {
    private let model: ViewerModel
    private let theme: ThemeController

    public init(model: ViewerModel, theme: ThemeController) {
        self.model = model
        self.theme = theme
    }

    public var body: some View {
        TabView {
            NudgeSettingsTab(model: model)
                .tabItem { Label("Playback", systemImage: "waveform") }
            AppearanceSettingsTab(theme: theme)
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
        }
        // A settings window does not resize to fit its tabs on its own, and an
        // unset width gives whichever tab is shown first the final say.
        .frame(width: 460)
    }
}

/// The preroll, the three nudge amounts, the two selection-move amounts, and
/// the zoom direction.
///
/// Only the *amounts* are editable here. The bindings are fixed until the real
/// `BindingTable` lands (spec §6.3), so each row names its keys rather than
/// pretending they can be changed.
struct NudgeSettingsTab: View {
    let model: ViewerModel

    var body: some View {
        Form {
            prerollSection
            nudgeSection
            selectionSection
            zoomSection

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.prefs.restoreDefaults() }
                        .disabled(!model.prefs.hasNonDefaultPreferences)
                }
            }
        }
        .formStyle(.grouped)
        // Four sections and a button. Without a floor the *window* opens at the
        // height of whichever tab was shown first and scrolls the rest, which
        // hides the zoom switch — the one control here nobody would think to
        // scroll for.
        //
        // macOS only: on iPad this is a sheet, which takes its height from the
        // presentation rather than its content, and a 780 pt floor there would
        // force a scroll on the smaller iPads instead of preventing one.
        #if os(macOS)
        .frame(minHeight: 780)
        #endif
    }

    /// How far `Space` rolls back when it resumes.
    ///
    /// First, above the nudge amounts, because it is the one amount here that
    /// governs a key the user presses constantly without thinking about it.
    /// Seconds with three decimals, the same field shape as the move amounts —
    /// but its own footer, because its range is the one that differs: zero is
    /// allowed here and turns the feature off.
    @ViewBuilder
    private var prerollSection: some View {
        Section {
            LabeledContent {
                prerollField
            } label: {
                rowLabel("Preroll", keys: "Space")
            }
        } header: {
            Text("Resuming")
        } footer: {
            Text(
                "Space resumes this far before where playback stopped, so you hear the note "
                    + "you stopped on in context. 0 turns it off. It never crosses the start "
                    + "of the file, or the in point of a loop you are inside."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var prerollField: some View {
        HStack(spacing: 6) {
            TextField(
                "Preroll",
                value: Binding(
                    get: { model.prefs.prerollSeconds },
                    set: { model.prefs.setPrerollSeconds($0) }),
                format: .number.precision(.fractionLength(0...3))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
            Text("s")
                .foregroundStyle(.secondary)
            // Without this, setting an amount while the mode is off is a field
            // that accepts a value and changes nothing — the silent no-op spec
            // §8 forbids. It names the key so the fix is one press away.
            if !model.prefs.prerollEnabled {
                Text("— off (H)")
                    .foregroundStyle(.secondary)
                    .help("Preroll is switched off. Press H, or use Playback ▸ Preroll.")
            }
        }
    }

    @ViewBuilder
    private var nudgeSection: some View {
        Section {
            ForEach(NudgeTier.allCases) { tier in
                LabeledContent {
                    field(for: tier)
                } label: {
                    // The keys the amount applies to, under its name, because
                    // "Nudge" alone does not say which of three tiers this is.
                    // Inside the label rather than as a row of its own: five
                    // amounts and a switch fit a Settings pane, ten rows and a
                    // switch do not.
                    rowLabel(tier.label, keys: tier.keys)
                }
            }
        } header: {
            Text("Navigation amounts")
        } footer: {
            Self.rangeFooter
        }
    }

    /// The two amounts that slide a region: `C`/`V` and `⌥C`/`⌥V` for the
    /// selection, and the `⇧` forms for the loop's edges and its body.
    ///
    /// Edited in **seconds with fractions** rather than in the nudge tab's
    /// mixed units: both amounts live in the same range here — a fine one is
    /// worth having (0.02 is 20 ms) and so is a bar-length one — and one unit
    /// for both keeps the two rows comparable at a glance.
    @ViewBuilder
    private var selectionSection: some View {
        Section {
            ForEach(SelectionMoveTier.allCases) { tier in
                LabeledContent {
                    moveField(for: tier)
                } label: {
                    rowLabel(tier.label, keys: tier.keys)
                }
            }
        } header: {
            Text("Selection and loop movement")
        } footer: {
            // The range is stated once, under the amounts above; repeating it
            // verbatim would cost a pane's worth of height to say nothing new.
            Text("The same range applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One switch for every zoom gesture in the window.
    @ViewBuilder
    private var zoomSection: some View {
        Section {
            Toggle(
                "Invert zoom direction",
                isOn: Binding(
                    get: { model.prefs.invertZoomDrag },
                    set: { model.prefs.setInvertZoomDrag($0) }))
        } header: {
            Text("Zoom")
        } footer: {
            // Deliberately unemphasised. `Text` parses Markdown in a string
            // *literal* only, and this string has to be concatenated to stay
            // inside the line limit — a `**down**` here reached the screen with
            // its asterisks showing, which is how that was measured.
            Text(
                "Normally a vertical drag downwards — on the time ruler, or ⌥-dragging "
                    + "the waveform — zooms in, and the wheel zooms in rolled forward. "
                    + "Inverting reverses both, so one window never holds two conventions."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Says the allowed range up front, so a value that snaps back is explained
    /// rather than mysterious. Shared by both amount sections, which share the
    /// bounds.
    private static var rangeFooter: some View {
        Text(
            "Between \(NudgeAmounts.label(seconds: NudgeAmounts.minimumSeconds)) and "
                + "\(NudgeAmounts.label(seconds: NudgeAmounts.maximumSeconds)). "
                + "A value outside that range is adjusted to the nearest allowed one."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// One amount row's name with the keys it governs under it.
    private func rowLabel(_ title: String, keys: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(keys)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func field(for tier: NudgeTier) -> some View {
        HStack(spacing: 6) {
            TextField(
                tier.label, value: binding(for: tier),
                format: .number.precision(.fractionLength(0...tier.unit.fractionDigits))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
            Text(tier.unit.suffix)
                .foregroundStyle(.secondary)
        }
    }

    /// Reads and writes in the tier's editing unit; the model stores seconds and
    /// validates. A rejected value therefore snaps the field to what was
    /// actually stored, which is the visible half of "never degrade silently" —
    /// typing 0 leaves a field reading 1 ms, not a nudge that quietly does
    /// nothing.
    private func binding(for tier: NudgeTier) -> Binding<Double> {
        Binding(
            get: { tier.unit.display(seconds: model.prefs.nudgeAmounts[tier]) },
            set: { model.prefs.setNudgeAmount(tier.unit.seconds(from: $0), for: tier) })
    }

    /// Seconds, with three decimals so 20 ms is typable. Same validate-and-snap
    /// behaviour as the nudge fields.
    private func moveField(for tier: SelectionMoveTier) -> some View {
        HStack(spacing: 6) {
            TextField(
                tier.label,
                value: Binding(
                    get: { model.prefs.selectionMoveAmounts[tier] },
                    set: { model.prefs.setSelectionMoveAmount($0, for: tier) }),
                format: .number.precision(.fractionLength(0...3))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
            Text("s")
                .foregroundStyle(.secondary)
        }
    }
}

/// Light / Dark / System — formerly `View ▸ Theme`.
struct AppearanceSettingsTab: View {
    @Bindable var theme: ThemeController

    var body: some View {
        Form {
            Picker("Theme", selection: $theme.preference) {
                ForEach(ThemePreference.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            Text("System follows the appearance macOS is set to, and changes with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
