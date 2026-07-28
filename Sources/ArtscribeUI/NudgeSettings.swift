import Foundation

/// Where the three nudge amounts are kept between launches.
///
/// A plain store, not an `@Observable`: the applied amounts live on
/// `ViewerModel`, which is what the menu titles and the nudge actions read, so
/// there is one source of truth and this is only its backing tape. The split
/// also keeps `UserDefaults` out of `ViewerModel()`, which unit tests build by
/// the dozen — a model that read the real user defaults on construction would
/// make the test suite depend on whatever the developer last typed into
/// Settings.
///
/// Deliberately mirrors `ThemeController`'s injectable-`defaults` shape so the
/// acceptance harness can run on its own suite and not disturb the real app's
/// preferences.
@MainActor
public final class NudgeSettings {

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests and the acceptance harness get
    ///   their own suite instead of writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for tier: NudgeTier) -> String { "nudge.\(tier.rawValue).seconds" }

    /// Reads the stored amounts, falling back per tier to the shipped default.
    ///
    /// Every value goes through `NudgeAmounts`'s validating subscript on the way
    /// in. Storage is not a trusted source: a value written by an older build,
    /// by `defaults write`, or by a half-completed save must not be able to
    /// install a nudge of zero, which would silently do nothing.
    public func load() -> NudgeAmounts {
        var amounts = NudgeAmounts.defaults
        for tier in NudgeTier.allCases {
            // `object(forKey:) as? Double`, not `double(forKey:)`: the latter
            // answers 0 for both "absent" and "a string", and 0 is the one value
            // that must never be installed.
            guard let stored = defaults.object(forKey: Self.key(for: tier)) as? Double else {
                continue
            }
            amounts[tier] = stored
        }
        return amounts
    }

    /// Writes the amounts, removing any that are back at their default so a
    /// later build changing a default is not overridden by a stale copy of the
    /// old one that the user never chose.
    public func save(_ amounts: NudgeAmounts) {
        for tier in NudgeTier.allCases {
            let key = Self.key(for: tier)
            if amounts[tier] == tier.defaultSeconds {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(amounts[tier], forKey: key)
            }
        }
    }
}
