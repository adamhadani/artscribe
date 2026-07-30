import Foundation

/// Whether this run shows developer-only controls.
///
/// ## Why an environment variable and not `#if DEBUG`
///
/// The developer menu exists to compare stretching engines **by ear**, and
/// `#if DEBUG` would make that comparison worthless. This project's first rule
/// is "measure in release, never debug" — a debug build decodes roughly 4×
/// slower, and the render thread is exactly where that shows up. Judging
/// Signalsmith against Rubber Band on a build that stalls under both would say
/// nothing about either, and it has already produced two false conclusions here
/// on other questions.
///
/// So the gate has to survive `-c release`, and an environment variable does.
/// It also matches how everything else in this project is switched off for a
/// run — `ARTSCRIBE_SILENT`, `ARTSCRIBE_ACCEPTANCE_AUDIBLE` — rather than
/// inventing a second mechanism.
///
/// ```sh
/// ARTSCRIBE_DEV_MENU=1 swift run -c release ArtscribeApp
/// ```
///
/// The cost is that a bundle launched from Finder never shows it, since it
/// inherits no shell environment. That is deliberate: shipping a build whose
/// hidden menu is one `defaults write` away is a different risk from shipping
/// one where the menu cannot appear at all without a terminal.
///
/// ## Read once
///
/// A `let`, not a computed property. The environment cannot change during a
/// run, and this is read from a SwiftUI menu body — which is re-evaluated far
/// more often than anyone expects. `PlaybackCommands` already carries the scar:
/// a value invalidated 62 times a second kept the Output Device submenu from
/// ever staying open long enough for AppKit's submenu delay to elapse.
public enum DeveloperMenu {
    public static let environmentKey = "ARTSCRIBE_DEV_MENU"

    public static let isEnabled: Bool = isEnabled(in: ProcessInfo.processInfo.environment)

    /// The decision, as a pure function, so it can be tested without setting a
    /// variable in the test runner's own process — which is global, and which
    /// two tests running concurrently would fight over.
    ///
    /// Anything other than unset, empty, `0`, `false` or `no` turns it on. The
    /// bias is deliberate: someone who typed `ARTSCRIBE_DEV_MENU=yes` meant yes,
    /// and the failure mode of guessing wrong here is a menu that does not
    /// appear for a developer rather than one that appears for a user.
    public static func isEnabled(in environment: [String: String]) -> Bool {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespaces),
            !raw.isEmpty
        else { return false }
        return !["0", "false", "no"].contains(raw.lowercased())
    }
}
