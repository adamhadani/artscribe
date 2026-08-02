import Foundation

/// Putting a **TestFlight** build back to how a new user meets it.
///
/// ## The problem this solves, and the one it must not create
///
/// Installing a TestFlight update keeps the app's container, so a tester who has
/// opened the app once never sees the first-run experience again — no welcome
/// tour, no sample-track offer, just the resting screen with their recents. That
/// is exactly right for a shipped app and exactly wrong for a beta, where the
/// first two minutes are usually the thing under review.
///
/// So: **on a TestFlight build only, a change of build number puts the first-run
/// state back**. On the App Store it never runs, which is the half that matters
/// — a released app that forgot a user's recents on every update would be a bug
/// report, not a feature. `InstallEnvironment` is what separates them, and it is
/// a pure function of the receipt's name so both branches are testable here.
///
/// A tester who wants it sooner has `Reset to a New Install` in Settings, which
/// is the same `reset` below. Deleting and reinstalling the app works too and
/// always has; this exists because nobody should have to.
///
/// ## What "first run" means
///
/// Two flags and one list, and no more:
///
/// * `welcomeSeen`, so the tour is offered again.
/// * The recents, because the sample-track offer is gated on the list being
///   empty (`SampleTrack.isOffered(recentCount:)`) — a tour without the track it
///   invites you to open is half the experience.
///
/// **Not** the theme, the nudge amounts, the preroll or the practice schedule.
/// Those are preferences a tester has deliberately set, and throwing them away
/// on every build would make the beta hostile to use.
public enum FirstRunReset {

    /// Where the build this container was last opened by is remembered.
    static let lastBuildKey = "lastRunBuildVersion"

    /// Whether to put the first-run state back.
    ///
    /// Nil `stored` is a genuinely fresh container — there is nothing to reset,
    /// and resetting anyway would be harmless but would also mean the flag is
    /// doing nothing. The rule is *changed*, not merely *different from
    /// current*, so a tester who rolls back to an earlier build gets the tour
    /// too, which is what they want when they are comparing two builds.
    public static func shouldReset(
        environment: InstallEnvironment, stored: String?, current: String
    ) -> Bool {
        guard environment == .testFlight else { return false }
        guard let stored else { return false }
        return stored != current
    }

    /// Clears the first-run state. Also the manual `Reset to a New Install`.
    @MainActor public static func reset(defaults: UserDefaults, recents: RecentFiles) {
        WelcomeState(defaults: defaults).forget()
        recents.clear()
    }

    /// Applies a pending reset and records the build, once per launch.
    ///
    /// Returns whether anything was reset, so a caller can say so; the app
    /// ignores it, because a tester who is being shown the tour does not need
    /// to be told they are being shown the tour.
    @MainActor @discardableResult
    public static func performIfNeeded(
        defaults: UserDefaults = .standard,
        environment: InstallEnvironment = .current,
        currentBuild: String = Bundle.main.buildVersion,
        recents: () -> RecentFiles = { RecentFiles() }
    ) -> Bool {
        let stored = defaults.string(forKey: lastBuildKey)
        defer { defaults.set(currentBuild, forKey: lastBuildKey) }
        guard shouldReset(environment: environment, stored: stored, current: currentBuild) else {
            return false
        }
        reset(defaults: defaults, recents: recents())
        return true
    }

    /// `UserDefaults.standard`, **after** any pending reset has been applied.
    ///
    /// The ordering is the whole point and it is why this is a `static let`
    /// rather than a call in the App's `init()`: a stored property's default
    /// value is evaluated before the initialiser's body runs, so by the time
    /// `init()` could clear a flag, `RecentFiles()` and `WelcomeState()` have
    /// already read it. Both are handed *this* instead, which cannot be reached
    /// without the reset having happened first.
    @MainActor public static let readyDefaults: UserDefaults = {
        performIfNeeded()
        return .standard
    }()
}

extension Bundle {
    /// `CFBundleVersion` — the build number, which `git rev-list --count HEAD`
    /// supplies and which therefore moves on every commit that ships.
    public var buildVersion: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
