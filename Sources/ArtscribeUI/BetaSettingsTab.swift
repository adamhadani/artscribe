import SwiftUI

/// **Settings ▸ Beta** — present only on a build that is not from the App Store.
///
/// Two things a tester needs and a shipped user does not: which build they are
/// looking at, and a way back to how a new user meets the app.
///
/// ## Why it is hidden rather than merely worded carefully
///
/// The button throws away the recents list. On a beta that is the point; on a
/// released app it is a support ticket from someone who tapped an unfamiliar
/// row to find out what it did. Gating on `InstallEnvironment` costs one
/// comparison and removes the question.
///
/// It is *not* gated on `#if DEBUG`, for the reason the Stretch Engine menu is
/// not: the builds this needs to be reachable on are release builds, uploaded
/// to TestFlight, running on someone else's iPad. A debug gate would remove it
/// from precisely those.
///
/// ## The build number is not decoration
///
/// "Which build are you on?" is the first question every beta bug report needs
/// and the one testers most often cannot answer — the number is in TestFlight,
/// not in the app. `CFBundleVersion` here is `git rev-list --count HEAD`, so it
/// names a commit exactly.
struct BetaSettingsTab: View {
    let welcome: WelcomeState
    let recents: RecentFiles
    /// Injected rather than read from `Bundle.main` so the row is checkable, and
    /// so a preview does not report the build number of Xcode.
    var environment: InstallEnvironment
    var build: String

    @State private var confirming = false

    /// Enough for the caption to sit on one or two lines rather than four.
    private static let captionWidth: CGFloat = 320

    var body: some View {
        Form {
            Section {
                LabeledContent("Build", value: build)
                LabeledContent("Installed from", value: environment.label)
            }

            Section {
                Button("Reset to a New Install…", role: .destructive) { confirming = true }
                Text(
                    """
                    Forgets the welcome tour and the list of recent files, so the \
                    app greets you the way it greets someone opening it for the \
                    first time. Your preferences are kept.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: Self.captionWidth, alignment: .leading)
            } header: {
                Text("First run")
            } footer: {
                Text(
                    environment == .testFlight
                        ? "Installing a new TestFlight build does this for you."
                        : "TestFlight builds also do this whenever the build number changes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .confirmationDialog(
            "Reset to a new install?", isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                FirstRunReset.reset(welcome: welcome, recents: recents)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The welcome tour and your recent files are forgotten. Preferences are kept.")
        }
    }
}

extension InstallEnvironment {
    /// How to name this to a person, rather than to the receipt parser.
    var label: String {
        switch self {
        case .appStore: return "the App Store"
        case .testFlight: return "TestFlight"
        case .development: return "Xcode or a direct build"
        }
    }
}
