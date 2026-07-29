import Foundation

/// Where the preroll is kept between launches.
///
/// A plain store, not an `@Observable`, for the reasons `NudgeSettings` records:
/// the applied value lives on `ViewerModel`, so there is one source of truth and
/// this is only its backing tape — and keeping `UserDefaults` out of
/// `ViewerModel()` is what stops a suite that builds models by the dozen from
/// depending on whatever the developer last typed into Settings.
///
/// Its own store rather than a fourth field on `NudgeSettings` because the two
/// amounts have **different floors and the difference is the point**: a nudge of
/// zero must never be storable, and a preroll of zero must be (see `Preroll`).
/// One type holding both would have to carry two validation rules under one
/// name, which is exactly how a zero eventually gets installed somewhere it
/// should not be.
@MainActor
public final class PrerollSettings {

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests and the acceptance harness get
    ///   their own suite instead of writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static let key = "playback.preroll.seconds"

    /// The on/off mode, kept apart from the amount so turning it off and back
    /// on restores the seconds the user chose rather than a default.
    public static let enabledKey = "playback.preroll.enabled"

    /// Reads the stored preroll, falling back to the shipped default, and
    /// validates on the way in — storage is not a trusted source.
    ///
    /// `object(forKey:) as? Double`, not `double(forKey:)`. The distinction
    /// matters more here than anywhere else in the app: `double(forKey:)`
    /// answers 0 for "absent", for "a string" *and* for a genuine stored zero,
    /// and here zero is a real value meaning off. Reading it the lazy way would
    /// silently turn the feature off for every user who has never set it.
    public func load() -> Double {
        guard let stored = defaults.object(forKey: Self.key) as? Double else {
            return Preroll.defaultSeconds
        }
        return Preroll.validated(stored)
    }

    /// Reads the on/off mode, defaulting to **on** — the feature ships enabled,
    /// and `object(forKey:)` again rather than `bool(forKey:)` because the lazy
    /// reader answers `false` for "absent" and would ship it off to everyone who
    /// has never touched it.
    public func loadEnabled() -> Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Writes the mode, removing it when back at the shipped default.
    public func saveEnabled(_ enabled: Bool) {
        if enabled {
            defaults.removeObject(forKey: Self.enabledKey)
        } else {
            defaults.set(false, forKey: Self.enabledKey)
        }
    }

    /// Writes the amount, removing it when it is back at the default so a later
    /// build changing that default is not overridden by a stale copy of the old
    /// one the user never chose.
    public func save(_ seconds: Double) {
        if seconds == Preroll.defaultSeconds {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(seconds, forKey: Self.key)
        }
    }
}
