import Foundation
import Observation

/// Whether the welcome sheet should appear, and the record that it has.
///
/// ## What Apple actually asks for
///
/// The HIG is more sceptical of first-run tutorials than their ubiquity
/// suggests — *"ideally, people can understand your app simply by experiencing
/// it, but if onboarding is necessary, design a flow that's fast, fun, and
/// **optional**"* — and it sets three conditions this type exists to satisfy:
///
///  * **Optional.** Skip is always available, and skipping counts as seen.
///  * **Never twice.** *"If you let people skip the tutorial when they first
///    launch … don't present it again on subsequent launches."*
///  * **Findable afterwards.** *"…but make sure it's easy for people to find if
///    they want to view it later … in a help, account, or settings area."* The
///    About panel carries the link, on both platforms.
///
/// It also says onboarding *"occurs after launching is complete — it isn't part
/// of the launch experience"*, which is why the sheet is raised from the
/// document view's appearance rather than from the app's `init`.
///
/// ## Why the flag records *seen* rather than a version
///
/// A version would let a later release re-show the sheet, and that is exactly
/// the behaviour the HIG rules out for someone who already skipped it. If a
/// future release genuinely needs to say something new, it wants a *release
/// notes* surface, not this one.
@MainActor
@Observable
public final class WelcomeState {

    private static let defaultsKey = "welcomeSeen"

    private let defaults: UserDefaults

    /// Injectable for the same reason every settings type here is: the suite
    /// must not read or write the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasBeenSeen = defaults.bool(forKey: Self.defaultsKey)
    }

    /// Persisted the moment it changes, rather than on quit: a first run that
    /// ends in a crash should still not show the sheet twice.
    public var hasBeenSeen: Bool {
        didSet {
            guard hasBeenSeen != oldValue else { return }
            defaults.set(hasBeenSeen, forKey: Self.defaultsKey)
        }
    }

    /// Whether to raise the sheet on this launch.
    ///
    /// Pure, and takes the answer rather than reading the flag itself, so the
    /// rule is testable without a `UserDefaults` round trip — and so a caller
    /// cannot accidentally consult a different source of truth than the one the
    /// dismissal writes to.
    public static func shouldPresent(hasBeenSeen: Bool) -> Bool { !hasBeenSeen }

    /// Both **Skip** and reaching the end record the same thing. Apple draws no
    /// distinction, and neither should this: a person who skipped has decided,
    /// and re-asking is the behaviour the guidance forbids.
    public func markSeen() { hasBeenSeen = true }

    /// Puts the flag back, so the tour returns **on the next launch, unbidden**
    /// — which is exactly what `replayRequested` exists to avoid, and is
    /// correct for the one caller that wants it: `FirstRunReset`, putting a
    /// TestFlight container back to how a new user meets it. Not reachable from
    /// anywhere a user could hit it by accident; see that type.
    public func forget() { hasBeenSeen = false }

    /// Set by the About panel to ask for the sheet again; `DocumentView`
    /// observes it and presents, then clears it.
    ///
    /// A trigger rather than clearing `hasBeenSeen`, because it *has* been seen
    /// and viewing it again does not un-see it — clearing the flag would make
    /// the sheet return unbidden on the next launch, which is precisely the
    /// behaviour the guidance forbids.
    public var replayRequested = false
}
