import SwiftUI

/// **Artscribe ▸ Settings…** (⌘,), the content of SwiftUI's `Settings` scene.
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

/// The three nudge amounts.
///
/// Only the *amounts* are editable here. The bindings are fixed until the real
/// `BindingTable` lands (spec §6.3), so each row names its keys rather than
/// pretending they can be changed.
struct NudgeSettingsTab: View {
    let model: ViewerModel

    var body: some View {
        Form {
            Section {
                ForEach(NudgeTier.allCases) { tier in
                    LabeledContent(tier.label) { field(for: tier) }
                    // The keys the amount applies to, under the field, because
                    // "Nudge" alone does not say which of three tiers this is.
                    Text(tier.keys)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Navigation amounts")
            } footer: {
                // Says the range up front, so a value that snaps back is
                // explained rather than mysterious.
                Text(
                    "Between \(NudgeAmounts.label(seconds: NudgeAmounts.minimumSeconds)) and "
                        + "\(NudgeAmounts.label(seconds: NudgeAmounts.maximumSeconds)). "
                        + "A value outside that range is adjusted to the nearest allowed one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.restoreDefaultNudgeAmounts() }
                        .disabled(model.nudgeAmounts == NudgeAmounts.defaults)
                }
            }
        }
        .formStyle(.grouped)
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
            get: { tier.unit.display(seconds: model.nudgeAmounts[tier]) },
            set: { model.setNudgeAmount(tier.unit.seconds(from: $0), for: tier) })
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
