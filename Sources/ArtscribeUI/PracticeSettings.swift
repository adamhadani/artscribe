import ArtscribeKit
import Foundation

/// Where the ramp the user set up is kept between launches.
///
/// A plain store, not an `@Observable`: the applied schedule lives on
/// `ViewerModel.ramp`, which is what the window and the ramp itself read, so
/// there is one source of truth and this is only its backing tape. The same
/// split as `NudgeSettings`, and for the same second reason — it keeps
/// `UserDefaults` out of `ViewerModel()`, which unit tests build by the dozen.
///
/// **The schedule is remembered and the run is not.** How slow you have to start
/// a passage and how many passes it takes you is a fact about the passage and
/// about you; which repetition you were on when you quit is a fact about
/// Tuesday. Restoring a half-finished ramp on launch would leave the transport
/// at 72% for reasons nothing on screen could explain.
@MainActor
public final class PracticeSettings {

    private static let key = "practice.ramp"

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests and the acceptance harness get
    ///   their own suite instead of writing into the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored schedule, or the shipped default.
    ///
    /// Anything that will not decode is discarded rather than repaired in place:
    /// `RampSchedule`'s own decoder already falls back field by field, so a
    /// failure here means the stored blob is not a schedule at all — written by
    /// an older build, or by `defaults write` — and the shipped default is a
    /// better answer than a guess.
    public func load() -> RampSchedule {
        guard let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(RampSchedule.self, from: data)
        else {
            return RampSchedule()
        }
        return decoded
    }

    /// Writes the schedule, removing it entirely when it is back at the shipped
    /// default — so a later build changing that default is not overridden by a
    /// stale copy of the old one that the user never chose. `NudgeSettings.save`
    /// does the same, for the same reason.
    public func save(_ schedule: RampSchedule) {
        guard schedule != RampSchedule() else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
