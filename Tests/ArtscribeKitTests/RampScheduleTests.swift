import Foundation
import Testing

@testable import ArtscribeKit

/// **The practice ramp's arithmetic**, which is the whole of the feature that
/// does not need a window.
///
/// Four of these are cases that a plausible implementation gets wrong rather
/// than cases that merely exist: `repetitions == 1` is a division by zero,
/// `start == end` is a schedule with no motion in it, an **inverted** range is a
/// real way to practise that an ascent-shaped loop would silently reverse or
/// refuse, and the clamp is what keeps a typed 300% from reaching the transport.
@Suite("Ramp schedule")
struct RampScheduleTests {

    /// One expected schedule. A named type rather than a tuple: SwiftLint caps
    /// a tuple at two members, and four reads better with the names anyway.
    private struct Row {
        let start: Double
        let end: Double
        let count: Int
        let delta: Double
    }

    private func decode(_ json: String) throws -> RampSchedule {
        try JSONDecoder().decode(RampSchedule.self, from: Data(json.utf8))
    }

    // MARK: - The deltas

    /// The shipped default, spelled out. Both endpoints are played, so the step
    /// is over nine gaps and not ten.
    @Test("the default ramp walks 50% to 100% over ten repetitions")
    func theDefaultSchedule() {
        let schedule = RampSchedule()
        #expect(schedule.startRatio == 0.50)
        #expect(schedule.endRatio == 1.00)
        #expect(schedule.repetitions == 10)
        #expect(abs(schedule.delta - 0.5 / 9) < 1e-12)

        let ratios = schedule.ratios
        #expect(ratios.count == 10)
        #expect(ratios.first == 0.50)
        // Exactly, not nearly: the last repetition is the tempo that was asked
        // for, and it is what a test written against the user's own number has
        // to be able to compare with `==`.
        #expect(ratios.last == 1.00)
        for (earlier, later) in zip(ratios, ratios.dropFirst()) {
            #expect(abs((later - earlier) - schedule.delta) < 1e-12)
        }
    }

    @Test("the delta is the range divided by one fewer than the repetitions")
    func deltaSpansTheRange() {
        let cases: [Row] = [
            Row(start: 0.5, end: 1.0, count: 2, delta: 0.5),
            Row(start: 0.5, end: 1.0, count: 5, delta: 0.125),
            Row(start: 0.25, end: 1.0, count: 4, delta: 0.25),
            Row(start: 0.6, end: 0.9, count: 7, delta: 0.05)
        ]
        for row in cases {
            let schedule = RampSchedule(
                startRatio: row.start, endRatio: row.end, repetitions: row.count)
            #expect(
                abs(schedule.delta - row.delta) < 1e-12,
                "\(row.start)→\(row.end) over \(row.count) gave \(schedule.delta)")
            #expect(schedule.ratios.first == row.start)
            #expect(schedule.ratios.last == row.end)
            #expect(schedule.ratios.count == row.count)
        }
    }

    // MARK: - The cases that break a naive implementation

    /// The division by zero. One repetition can only be played at one speed, and
    /// it is the one the user said to start at.
    @Test("a single repetition has no delta and plays the start speed")
    func oneRepetition() {
        let schedule = RampSchedule(startRatio: 0.4, endRatio: 1.0, repetitions: 1)
        #expect(schedule.repetitions == 1)
        #expect(schedule.delta == 0)
        #expect(schedule.delta.isFinite)
        #expect(schedule.ratios == [0.4])
        #expect(schedule.ratio(at: 0) == 0.4)
        // And out of range in both directions, because a view body reads this
        // while the count can be edited underneath it.
        #expect(schedule.ratio(at: -3) == 0.4)
        #expect(schedule.ratio(at: 99) == 0.4)
    }

    /// Drilling one tempo. A valid ramp, and one with a zero delta that must not
    /// be mistaken for a degenerate schedule.
    @Test("start equal to end is a flat ramp, not an error")
    func startEqualsEnd() {
        let schedule = RampSchedule(startRatio: 0.75, endRatio: 0.75, repetitions: 6)
        #expect(schedule.delta == 0)
        #expect(schedule.ratios == Array(repeating: 0.75, count: 6))
        #expect(schedule.ratios.count == 6, "a flat ramp still has all its repetitions")
    }

    /// **Descending.** Practising by progressively slowing down is a real thing
    /// musicians do — it is how you find out what your fingers are actually
    /// playing at tempo — so the schedule must ramp *down* rather than sorting
    /// the endpoints or clamping the delta to positive.
    @Test("an inverted range descends, and never quietly turns itself the right way up")
    func invertedRangeDescends() {
        let schedule = RampSchedule(startRatio: 1.0, endRatio: 0.5, repetitions: 6)
        #expect(schedule.delta < 0, "the delta of a descending ramp must be negative")
        #expect(abs(schedule.delta + 0.1) < 1e-12)

        let ratios = schedule.ratios
        #expect(ratios.first == 1.0)
        #expect(ratios.last == 0.5)
        for (earlier, later) in zip(ratios, ratios.dropFirst()) {
            #expect(later < earlier, "a descending ramp went up: \(ratios)")
        }
        // The mirror of `deltaSpansTheRange`'s ascending row, so a sort of the
        // endpoints would fail here rather than pass both.
        #expect(ratios == [1.0, 0.9, 0.8, 0.7, 0.6, 0.5].map { ($0 * 1000).rounded() / 1000 })
    }

    // MARK: - The clamps

    @Test("the endpoints are clamped into the transport's speed range, at both ends")
    func endpointsAreClamped() {
        let tooLow = RampSchedule(startRatio: 0.01, endRatio: 0.5, repetitions: 4)
        #expect(tooLow.startRatio == SpeedState.minRatio)
        #expect(tooLow.ratios.allSatisfy { $0 >= SpeedState.minRatio })

        let tooHigh = RampSchedule(startRatio: 1.0, endRatio: 9.0, repetitions: 4)
        #expect(tooHigh.endRatio == SpeedState.maxRatio)
        #expect(tooHigh.ratios.allSatisfy { $0 <= SpeedState.maxRatio })

        // Both ends out of range at once, and inverted while it is at it.
        let both = RampSchedule(startRatio: 5.0, endRatio: -1.0, repetitions: 5)
        #expect(both.startRatio == SpeedState.maxRatio)
        #expect(both.endRatio == SpeedState.minRatio)
        #expect(both.delta < 0)
        #expect(
            both.ratios.allSatisfy { $0 >= SpeedState.minRatio && $0 <= SpeedState.maxRatio },
            "\(both.ratios) left the speed range")

        // Non-finite, which is what an empty or malformed field can produce.
        // `SpeedState`'s clamp answers 1.0 rather than a bound for these — a NaN
        // or an infinity is not a speed at one end of the range, it is a value
        // that says nothing — and the ramp inherits that rather than restating it.
        let broken = RampSchedule(startRatio: .nan, endRatio: .infinity, repetitions: 3)
        #expect(broken.startRatio == 1.0)
        #expect(broken.endRatio == 1.0)
        #expect(broken.ratios.allSatisfy { $0.isFinite })
    }

    @Test("no ratio in any schedule can leave the speed range")
    func noRatioEverLeavesTheRange() {
        for start in [-4.0, 0.0, 0.1, 0.33, 1.0, 2.0, 7.5] {
            for end in [-4.0, 0.0, 0.1, 0.5, 1.0, 2.0, 7.5] {
                for count in [1, 2, 3, 10, 99, 400] {
                    let schedule = RampSchedule(
                        startRatio: start, endRatio: end, repetitions: count)
                    for ratio in schedule.ratios {
                        #expect(
                            ratio >= SpeedState.minRatio && ratio <= SpeedState.maxRatio,
                            "\(start)→\(end) over \(count) produced \(ratio)")
                    }
                }
            }
        }
    }

    @Test("the repetition count is clamped rather than allowed to be zero or absurd")
    func repetitionCountIsClamped() {
        #expect(RampSchedule(repetitions: 0).repetitions == RampSchedule.minimumRepetitions)
        #expect(RampSchedule(repetitions: -12).repetitions == RampSchedule.minimumRepetitions)
        #expect(RampSchedule(repetitions: 5000).repetitions == RampSchedule.maximumRepetitions)
        // A zero count would make `ratios` empty and the ramp complete before it
        // began, which is the failure this clamp exists to prevent.
        #expect(!RampSchedule(repetitions: 0).ratios.isEmpty)
    }

    @Test("the setters clamp too, so a field cannot bypass the range")
    func settersClamp() {
        var schedule = RampSchedule()
        schedule.setStartRatio(9)
        schedule.setEndRatio(0)
        schedule.setRepetitions(0)
        #expect(schedule.startRatio == SpeedState.maxRatio)
        #expect(schedule.endRatio == SpeedState.minRatio)
        #expect(schedule.repetitions == RampSchedule.minimumRepetitions)
    }

    // MARK: - Persistence

    /// The schedule is remembered between launches, so a decoder that trusted
    /// its input could install a ramp the transport cannot play.
    @Test("a decoded schedule is validated, and missing fields fall back")
    func decodingIsValidated() throws {
        let decoded = try decode(#"{"startRatio": 40, "endRatio": -2, "repetitions": 999}"#)
        #expect(decoded.startRatio == SpeedState.maxRatio)
        #expect(decoded.endRatio == SpeedState.minRatio)
        #expect(decoded.repetitions == RampSchedule.maximumRepetitions)

        let partial = try decode(#"{"repetitions": 4}"#)
        #expect(partial.startRatio == RampSchedule.defaultStartRatio)
        #expect(partial.endRatio == RampSchedule.defaultEndRatio)
        #expect(partial.repetitions == 4)

        #expect(try decode("{}") == RampSchedule())
    }
}
