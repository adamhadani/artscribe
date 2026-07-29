import Foundation

/// Where the interaction preferences live between launches: the zoom-drag
/// direction, and the two selection-move amounts.
///
/// A plain store, not an `@Observable`, for exactly the reasons `NudgeSettings`
/// records: the applied values live on `ViewerModel` — which the menu titles,
/// the gestures and the Settings fields all read — so there is one source of
/// truth and this is only its backing tape. Keeping `UserDefaults` out of
/// `ViewerModel()` is the other half: unit tests build models by the dozen, and
/// one that read the real user defaults on construction would depend on
/// whatever the developer last typed into Settings.
///
/// Separate from `NudgeSettings` rather than folded into it because the two
/// answer different questions — how far the *playhead* moves, and how the
/// *view* and the *selection* behave — and because a store named for nudging
/// that also held a zoom direction would be a lie in the one file whose whole
/// job is to be boring.
@MainActor
public final class InteractionSettings {

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests and the acceptance harness get
    ///   their own suite instead of writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let invertZoomDragKey = "zoom.invertDragDirection"

    public static func key(for tier: SelectionMoveTier) -> String {
        "selectionMove.\(tier.rawValue).seconds"
    }

    /// Reads the stored preferences, falling back to the shipped defaults.
    ///
    /// Every amount goes through `SelectionMoveAmounts`' validating subscript on
    /// the way in. Storage is not a trusted source: a value written by an older
    /// build, by `defaults write`, or by a half-completed save must not be able
    /// to install a move of zero, which would silently do nothing.
    public func load() -> InteractionPreferences {
        var preferences = InteractionPreferences.defaults
        // `object(forKey:)`, not `bool(forKey:)`: the latter cannot tell "absent"
        // from "false", and the difference matters if the default ever changes.
        if let stored = defaults.object(forKey: Self.invertZoomDragKey) as? Bool {
            preferences.invertZoomDrag = stored
        }
        for tier in SelectionMoveTier.allCases {
            // `object(forKey:) as? Double` for the same reason `NudgeSettings`
            // uses it: `double(forKey:)` answers 0 for both "absent" and "a
            // string", and 0 is the one value that must never be installed.
            guard let stored = defaults.object(forKey: Self.key(for: tier)) as? Double else {
                continue
            }
            preferences.selectionMove[tier] = stored
        }
        return preferences
    }

    /// Writes the preferences, removing anything that is back at its default so
    /// a later build changing a default is not overridden by a stale copy of the
    /// old one that the user never chose.
    public func save(_ preferences: InteractionPreferences) {
        if preferences.invertZoomDrag {
            defaults.set(true, forKey: Self.invertZoomDragKey)
        } else {
            defaults.removeObject(forKey: Self.invertZoomDragKey)
        }
        for tier in SelectionMoveTier.allCases {
            let key = Self.key(for: tier)
            if preferences.selectionMove[tier] == tier.defaultSeconds {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(preferences.selectionMove[tier], forKey: key)
            }
        }
    }
}
