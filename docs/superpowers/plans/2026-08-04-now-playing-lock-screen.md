# Now Playing — lock-screen controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A locked iPhone or iPad shows what Artscripture is playing, at what speed, and offers play/pause plus a way back to the top of the loop.

**Architecture:** Two pure value types decide everything — `NowPlayingSnapshot` (what the app looks like right now) and `NowPlayingInfo` (what to publish). A thin iOS-only `NowPlayingController` owns the `MediaPlayer` framework calls and holds no policy. This is the shape `AudioSessionPolicy` already uses: the rules are pure functions unit-tested on the Mac, the platform adapter only translates.

**Tech Stack:** Swift 6.3, SwiftUI, `MediaPlayer.framework` (iOS only), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-04-now-playing-lock-screen-design.md`

## Global Constraints

- **Module boundary.** All new code lives in `ArtscribeUI`. `Playback` must never import UI; `ArtscribeKit` imports nothing.
- **The pure types must NOT be platform-guarded.** A test behind `#if !os(macOS)` in `ArtscribeUITests` runs on no platform at all — `make check` is macOS so it compiles out, and `ArtscribeUITests` is not in the iOS test bundle. Only `NowPlayingController.swift` is wrapped in `#if !os(macOS)`.
- **macOS behaviour must not change.** No `MPRemoteCommandCenter` registration on macOS, ever.
- **Testing:** Swift Testing (`import Testing`, `@Test`, `#expect`), never XCTest.
- **swiftlint `file_length` is 400 lines, strict.** Split before you reach it.
- **`make check` must be green before every commit.** Pre-commit hooks enforce the same checks.
- **Speed ratio, not time ratio.** `speed.ratio` is user-facing (0.5 == half speed). `timeRatio` is its reciprocal and is wrong here.
- Never run `git add -A`. Stage explicit paths — several agents share this worktree.

---

### Task 1: `NowPlayingSnapshot` and `NowPlayingInfo`

The two pure value types. `NowPlayingSnapshot` is what the app looks like at an instant; `NowPlayingInfo` is the text and numbers to hand the system.

**Files:**
- Create: `Sources/ArtscribeUI/NowPlayingInfo.swift`
- Test: `Tests/ArtscribeUITests/NowPlayingInfoTests.swift`

**Interfaces:**
- Consumes: `FrameIndex`, `FrameRange`, `LoopRegion` (all `ArtscribeKit`); `TimeCode.coarse(frames:sampleRate:)` and `TimeCode.seconds(frames:sampleRate:)` (`ArtscribeUI`).
- Produces:
  - `NowPlayingPractice` — `struct { isRunning: Bool, repetition: Int, total: Int }`, `Equatable, Sendable`, memberwise `init`.
  - `NowPlayingSnapshot` — `struct { trackURL: URL?, playhead: FrameIndex, totalFrames: FrameIndex, sampleRate: Double, speedRatio: Double, isPlaying: Bool, loop: LoopRegion, practice: NowPlayingPractice }`, `Equatable, Sendable`, memberwise `init` with defaults.
  - `NowPlayingInfo` — `struct { title: String, subtitle: String, elapsed: Double, duration: Double, rate: Double }`, `Equatable, Sendable`.
  - `NowPlayingInfo.init?(_ snapshot: NowPlayingSnapshot)` — `nil` when there is no track.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ArtscribeUITests/NowPlayingInfoTests.swift`:

```swift
import ArtscribeKit
import Foundation
import Testing

@testable import ArtscribeUI

/// What a locked screen says about the app.
///
/// Every branch is a pure function of a snapshot, which is the only reason any
/// of this can be checked on a Mac — the surface it drives exists only on iOS.
@Suite("Now Playing info")
struct NowPlayingInfoTests {

    /// 44.1 kHz, a two-minute track, playhead at one minute.
    private func snapshot(
        speedRatio: Double = 1.0,
        isPlaying: Bool = true,
        loop: LoopRegion = LoopRegion(),
        practice: NowPlayingPractice = NowPlayingPractice(),
        playhead: FrameIndex = 2_646_000,
        totalFrames: FrameIndex = 5_292_000,
        url: URL? = URL(fileURLWithPath: "/tmp/Black Codes.flac")
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            trackURL: url, playhead: playhead, totalFrames: totalFrames,
            sampleRate: 44100, speedRatio: speedRatio, isPlaying: isPlaying,
            loop: loop, practice: practice)
    }

    // MARK: - Title

    @Test("the title is the file name without its extension")
    func titleDropsTheExtension() throws {
        let info = try #require(NowPlayingInfo(snapshot()))
        #expect(info.title == "Black Codes")
    }

    /// Only the *last* dot is an extension. `deletingPathExtension` gets this
    /// right and hand-rolled string splitting does not.
    @Test("a name containing dots keeps all but the extension")
    func titleKeepsInteriorDots() throws {
        let url = URL(fileURLWithPath: "/tmp/My.Song.v2.flac")
        let info = try #require(NowPlayingInfo(snapshot(url: url)))
        #expect(info.title == "My.Song.v2")
    }

    @Test("no track means nothing to publish")
    func noTrackIsNil() {
        #expect(NowPlayingInfo(snapshot(url: nil)) == nil)
    }

    // MARK: - Subtitle

    @Test("plain playback reports only the speed")
    func subtitleAtFullSpeed() throws {
        let info = try #require(NowPlayingInfo(snapshot()))
        #expect(info.subtitle == "100%")
    }

    @Test("a slowed track reports its speed")
    func subtitleSlowed() throws {
        let info = try #require(NowPlayingInfo(snapshot(speedRatio: 0.5)))
        #expect(info.subtitle == "50%")
    }

    /// The two facts a locked screen cannot otherwise convey.
    @Test("an enabled loop reports its bounds")
    func subtitleLooping() throws {
        let loop = LoopRegion(
            range: FrameRange(start: 3_660_300, count: 176_400), isEnabled: true)
        let info = try #require(NowPlayingInfo(snapshot(speedRatio: 0.5, loop: loop)))
        #expect(info.subtitle == "50% · looping 1:23–1:27")
    }

    /// **A loop region exists with `isEnabled == false`.** Reading the range
    /// without checking the flag is the plausible bug, and it would announce a
    /// loop the user had switched off.
    @Test("a disabled loop is not announced")
    func subtitleIgnoresADisabledLoop() throws {
        let loop = LoopRegion(
            range: FrameRange(start: 3_660_300, count: 176_400), isEnabled: false)
        let info = try #require(NowPlayingInfo(snapshot(loop: loop)))
        #expect(info.subtitle == "100%")
    }

    /// A ramp always runs on a loop, so printing both would say the same thing
    /// twice in a field with room for one line.
    @Test("a running practice ramp supersedes the loop")
    func subtitlePractising() throws {
        let loop = LoopRegion(
            range: FrameRange(start: 3_660_300, count: 176_400), isEnabled: true)
        let practice = NowPlayingPractice(isRunning: true, repetition: 4, total: 12)
        let info = try #require(
            NowPlayingInfo(snapshot(speedRatio: 0.65, loop: loop, practice: practice)))
        #expect(info.subtitle == "65% · practice, rep 4 of 12")
    }

    @Test("a stopped ramp falls back to the loop")
    func subtitleIgnoresAStoppedRamp() throws {
        let loop = LoopRegion(
            range: FrameRange(start: 3_660_300, count: 176_400), isEnabled: true)
        let practice = NowPlayingPractice(isRunning: false, repetition: 4, total: 12)
        let info = try #require(NowPlayingInfo(snapshot(loop: loop, practice: practice)))
        #expect(info.subtitle == "100% · looping 1:23–1:27")
    }

    // MARK: - The rate, which is the one that fails visibly

    /// **The trap.** The system extrapolates position from
    /// `(elapsed, rate, timestamp)`. Publishing 1.0 while playing at half speed
    /// makes the lock-screen timer run at twice the true rate and visibly
    /// outrun the audio — the speed-ratio-versus-time-ratio mistake in a new
    /// place. It must be the *speed* ratio, never its reciprocal.
    @Test("the published rate is the real playback rate")
    func rateIsTheSpeedRatio() throws {
        let half = try #require(NowPlayingInfo(snapshot(speedRatio: 0.5)))
        #expect(half.rate == 0.5, "publishing 1.0 here makes the timer outrun the audio")

        let full = try #require(NowPlayingInfo(snapshot(speedRatio: 1.0)))
        #expect(full.rate == 1.0)

        let double = try #require(NowPlayingInfo(snapshot(speedRatio: 2.0)))
        #expect(double.rate == 2.0, "2.0 would be the time ratio, which is 0.5")
    }

    @Test("a paused track publishes a rate of zero")
    func rateIsZeroWhenPaused() throws {
        let info = try #require(NowPlayingInfo(snapshot(speedRatio: 0.5, isPlaying: false)))
        #expect(info.rate == 0)
    }

    // MARK: - Position

    @Test("elapsed and duration are seconds")
    func positionInSeconds() throws {
        let info = try #require(NowPlayingInfo(snapshot()))
        #expect(abs(info.elapsed - 60) < 0.001)
        #expect(abs(info.duration - 120) < 0.001)
    }

    /// A playhead past the end publishes a nonsense scrubber otherwise.
    @Test("elapsed clamps to the track")
    func elapsedClamps() throws {
        let past = try #require(NowPlayingInfo(snapshot(playhead: 9_999_999)))
        #expect(abs(past.elapsed - 120) < 0.001)

        let before = try #require(NowPlayingInfo(snapshot(playhead: -100)))
        #expect(before.elapsed == 0)
    }

    /// A sample rate of zero is what a half-loaded track reports. Dividing by it
    /// yields infinity or NaN, and a non-finite number in the info dictionary is
    /// undefined behaviour on the far side.
    @Test("an unusable sample rate publishes zeroes rather than infinities")
    func zeroSampleRateIsSafe() throws {
        let snapshot = NowPlayingSnapshot(
            trackURL: URL(fileURLWithPath: "/tmp/a.flac"), playhead: 100,
            totalFrames: 200, sampleRate: 0, speedRatio: 1, isPlaying: true,
            loop: LoopRegion(), practice: NowPlayingPractice())
        let info = try #require(NowPlayingInfo(snapshot))
        #expect(info.elapsed == 0)
        #expect(info.duration == 0)
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

```sh
swift test --filter NowPlayingInfoTests --no-parallel
```

Expected: compilation failure — `cannot find 'NowPlayingSnapshot' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ArtscribeUI/NowPlayingInfo.swift`:

```swift
import ArtscribeKit
import Foundation

/// Whether a practice ramp is running, and where it has got to.
///
/// A plain value rather than `SpeedRamp` itself: this type has to be
/// constructible in a test in one line, and it keeps the pure layer from
/// depending on the ramp's internals.
public struct NowPlayingPractice: Equatable, Sendable {
    public var isRunning: Bool
    public var repetition: Int
    public var total: Int

    public init(isRunning: Bool = false, repetition: Int = 0, total: Int = 0) {
        self.isRunning = isRunning
        self.repetition = repetition
        self.total = total
    }
}

/// What the app looks like at one instant, as far as a locked screen cares.
///
/// `Equatable` is not decoration — the controller compares consecutive
/// snapshots to decide whether a republish is warranted. See
/// `NowPlayingPolicy.shouldPublish`.
public struct NowPlayingSnapshot: Equatable, Sendable {
    public var trackURL: URL?
    public var playhead: FrameIndex
    public var totalFrames: FrameIndex
    public var sampleRate: Double
    public var speedRatio: Double
    public var isPlaying: Bool
    public var loop: LoopRegion
    public var practice: NowPlayingPractice

    public init(
        trackURL: URL? = nil, playhead: FrameIndex = 0, totalFrames: FrameIndex = 0,
        sampleRate: Double = 0, speedRatio: Double = 1, isPlaying: Bool = false,
        loop: LoopRegion = LoopRegion(), practice: NowPlayingPractice = NowPlayingPractice()
    ) {
        self.trackURL = trackURL
        self.playhead = playhead
        self.totalFrames = totalFrames
        self.sampleRate = sampleRate
        self.speedRatio = speedRatio
        self.isPlaying = isPlaying
        self.loop = loop
        self.practice = practice
    }
}

/// What to hand `MPNowPlayingInfoCenter`, computed and testable without it.
public struct NowPlayingInfo: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    /// Seconds, clamped to the track.
    public let elapsed: Double
    /// Seconds.
    public let duration: Double
    /// **The real playback rate**: the user-facing speed ratio while playing,
    /// zero while paused.
    ///
    /// The system extrapolates position between updates from
    /// `(elapsed, rate, timestamp)`, so a rate that disagrees with the audio
    /// makes the lock-screen timer drift away from what is being heard —
    /// quickly and visibly at 0.5×. This is `speed.ratio`, never `timeRatio`,
    /// which is its reciprocal.
    public let rate: Double

    /// `nil` when there is no track, which is also how the controller knows to
    /// clear the info centre rather than publish something stale.
    public init?(_ snapshot: NowPlayingSnapshot) {
        guard let url = snapshot.trackURL else { return nil }
        title = url.deletingPathExtension().lastPathComponent
        subtitle = Self.subtitle(for: snapshot)
        duration = TimeCode.seconds(frames: snapshot.totalFrames, sampleRate: snapshot.sampleRate)
        let position = TimeCode.seconds(
            frames: snapshot.playhead, sampleRate: snapshot.sampleRate)
        elapsed = Swift.max(0, Swift.min(position, duration))
        rate = snapshot.isPlaying ? snapshot.speedRatio : 0
    }

    /// Speed always; then the practice ramp if one is running, else the loop if
    /// one is enabled. Never both — a ramp always runs on a loop, so saying so
    /// twice wastes the only line there is.
    private static func subtitle(for snapshot: NowPlayingSnapshot) -> String {
        let speed = Readout.percent(snapshot.speedRatio)
        if snapshot.practice.isRunning {
            let practice = snapshot.practice
            return "\(speed) · practice, rep \(practice.repetition) of \(practice.total)"
        }
        guard snapshot.loop.isEnabled, snapshot.loop.range.count > 0 else { return speed }
        let start = TimeCode.coarse(
            frames: snapshot.loop.range.start, sampleRate: snapshot.sampleRate)
        let end = TimeCode.coarse(
            frames: snapshot.loop.range.start + snapshot.loop.range.count,
            sampleRate: snapshot.sampleRate)
        return "\(speed) · looping \(start)–\(end)"
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

```sh
swift test --filter NowPlayingInfoTests --no-parallel
```

Expected: PASS. If `Readout.percent` renders `1.0` as something other than `100%`, read `Sources/ArtscribeUI/Readout.swift` and match the test to what it actually does rather than changing `Readout` — it is used by the volume control too.

- [ ] **Step 5: Mutation-test the rate**

Temporarily change `rate = snapshot.isPlaying ? snapshot.speedRatio : 0` to `rate = snapshot.isPlaying ? 1 : 0`, and run:

```sh
swift test --filter NowPlayingInfoTests --no-parallel
```

Expected: FAIL on `rateIsTheSpeedRatio`. **Put the line back** and confirm the suite is green again. A test that cannot fail is worse than none.

- [ ] **Step 6: Commit**

```sh
git add Sources/ArtscribeUI/NowPlayingInfo.swift Tests/ArtscribeUITests/NowPlayingInfoTests.swift
git commit -m "What a locked screen should say, as a pure function"
```

---

### Task 2: `NowPlayingPolicy` — when to publish, and what a button means

Both remaining decisions, as pure functions: whether a snapshot is worth republishing, and what each remote command does given the loop.

**Files:**
- Create: `Sources/ArtscribeUI/NowPlayingPolicy.swift`
- Test: `Tests/ArtscribeUITests/NowPlayingPolicyTests.swift`

**Interfaces:**
- Consumes: `NowPlayingSnapshot` (Task 1); `NudgeStepping.target(from:bySeconds:sampleRate:totalFrames:) -> FrameIndex` (`Sources/ArtscribeUI/Nudging.swift`).
- Produces:
  - `NowPlayingRemoteCommand` — `enum { play, pause, toggle, skipBackward, skipForward }`, `CaseIterable, Sendable`.
  - `NowPlayingAction` — `enum { play, pause, toggle, restartLoop, seek(FrameIndex), none }`, `Equatable, Sendable`.
  - `NowPlayingPolicy.shouldPublish(previous:current:) -> Bool`
  - `NowPlayingPolicy.action(for:snapshot:skipSeconds:) -> NowPlayingAction`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ArtscribeUITests/NowPlayingPolicyTests.swift`:

```swift
import ArtscribeKit
import Foundation
import Testing

@testable import ArtscribeUI

/// The two decisions behind the lock screen: when to tell the system anything,
/// and what its buttons mean.
@Suite("Now Playing policy")
struct NowPlayingPolicyTests {

    private let track = URL(fileURLWithPath: "/tmp/a.flac")

    private func snapshot(
        playhead: FrameIndex = 44100,
        loop: LoopRegion = LoopRegion(),
        isPlaying: Bool = true,
        speedRatio: Double = 1
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            trackURL: track, playhead: playhead, totalFrames: 4_410_000,
            sampleRate: 44100, speedRatio: speedRatio, isPlaying: isPlaying, loop: loop,
            practice: NowPlayingPractice())
    }

    /// Bars 12–16: one second in, two seconds long.
    private var enabledLoop: LoopRegion {
        LoopRegion(range: FrameRange(start: 44100, count: 88200), isEnabled: true)
    }

    // MARK: - When to publish

    @Test("the first snapshot is always published")
    func firstPublish() {
        #expect(NowPlayingPolicy.shouldPublish(previous: nil, current: snapshot()))
    }

    /// **The reason this function exists.** The display link polls the playhead
    /// sixty times a second; republishing at that rate would burn CPU telling
    /// the system something it extrapolates correctly by itself.
    @Test("the playhead advancing on its own is not worth republishing")
    func forwardMotionIsSilent() {
        let before = snapshot(playhead: 44100)
        let after = snapshot(playhead: 44200)
        #expect(!NowPlayingPolicy.shouldPublish(previous: before, current: after))
    }

    /// A loop wrap, or a seek backwards. Both are real jumps the system cannot
    /// predict, and without this the scrubber drifts further from the truth on
    /// every lap.
    @Test("the playhead jumping backwards is republished")
    func backwardJumpPublishes() {
        let before = snapshot(playhead: 132_300)
        let after = snapshot(playhead: 44100)
        #expect(NowPlayingPolicy.shouldPublish(previous: before, current: after))
    }

    @Test("pausing is republished")
    func pausePublishes() {
        #expect(
            NowPlayingPolicy.shouldPublish(
                previous: snapshot(isPlaying: true), current: snapshot(isPlaying: false)))
    }

    @Test("a speed change is republished")
    func speedPublishes() {
        #expect(
            NowPlayingPolicy.shouldPublish(
                previous: snapshot(speedRatio: 1), current: snapshot(speedRatio: 0.5)))
    }

    @Test("a loop change is republished")
    func loopPublishes() {
        #expect(
            NowPlayingPolicy.shouldPublish(
                previous: snapshot(), current: snapshot(loop: enabledLoop)))
    }

    @Test("an identical snapshot is not republished")
    func identicalIsSilent() {
        #expect(!NowPlayingPolicy.shouldPublish(previous: snapshot(), current: snapshot()))
    }

    // MARK: - What the buttons do

    @Test("play, pause and toggle map straight through")
    func transportCommands() {
        let now = snapshot()
        #expect(NowPlayingPolicy.action(for: .play, snapshot: now, skipSeconds: 10) == .play)
        #expect(NowPlayingPolicy.action(for: .pause, snapshot: now, skipSeconds: 10) == .pause)
        #expect(NowPlayingPolicy.action(for: .toggle, snapshot: now, skipSeconds: 10) == .toggle)
    }

    /// Inside a four-second loop a ten-second skip-back lands outside the
    /// passage the user deliberately fenced off. What they want without looking
    /// is "again, from the top".
    @Test("skip-back restarts an enabled loop")
    func skipBackRestartsTheLoop() {
        let now = snapshot(playhead: 100_000, loop: enabledLoop)
        #expect(
            NowPlayingPolicy.action(for: .skipBackward, snapshot: now, skipSeconds: 10)
                == .restartLoop)
    }

    /// **A loop region exists with `isEnabled == false`.** Treating that as a
    /// loop would hijack the button for a loop the user had switched off.
    @Test("skip-back seeks when the loop is disabled")
    func skipBackSeeksWithADisabledLoop() {
        let disabled = LoopRegion(range: FrameRange(start: 44100, count: 88200), isEnabled: false)
        let now = snapshot(playhead: 441_000, loop: disabled)
        #expect(
            NowPlayingPolicy.action(for: .skipBackward, snapshot: now, skipSeconds: 10)
                == .seek(0))
    }

    @Test("skip-back seeks by the skip amount when there is no loop")
    func skipBackSeeks() {
        // 20 s in, back 10 s at 44.1 kHz -> 10 s.
        let now = snapshot(playhead: 882_000)
        #expect(
            NowPlayingPolicy.action(for: .skipBackward, snapshot: now, skipSeconds: 10)
                == .seek(441_000))
    }

    /// Forward always leaves the loop — the asymmetry is deliberate.
    @Test("skip-forward seeks even inside a loop")
    func skipForwardAlwaysSeeks() {
        let now = snapshot(playhead: 44100, loop: enabledLoop)
        #expect(
            NowPlayingPolicy.action(for: .skipForward, snapshot: now, skipSeconds: 10)
                == .seek(485_100))
    }

    /// Clamping rather than refusing, exactly as the keyboard's rewind does.
    @Test("a seek clamps to the track at both ends")
    func seeksClamp() {
        let nearStart = snapshot(playhead: 1000)
        #expect(
            NowPlayingPolicy.action(for: .skipBackward, snapshot: nearStart, skipSeconds: 10)
                == .seek(0))

        let nearEnd = snapshot(playhead: 4_400_000)
        #expect(
            NowPlayingPolicy.action(for: .skipForward, snapshot: nearEnd, skipSeconds: 10)
                == .seek(4_410_000))
    }

    @Test("with no track every command does nothing")
    func noTrackIsInert() {
        let empty = NowPlayingSnapshot()
        for command in NowPlayingRemoteCommand.allCases {
            #expect(
                NowPlayingPolicy.action(for: command, snapshot: empty, skipSeconds: 10) == .none,
                "\(command) acted on a closed track")
        }
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

```sh
swift test --filter NowPlayingPolicyTests --no-parallel
```

Expected: compilation failure — `cannot find 'NowPlayingPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ArtscribeUI/NowPlayingPolicy.swift`:

```swift
import ArtscribeKit
import Foundation

/// The remote commands this app answers. Deliberately not every command
/// `MPRemoteCommandCenter` offers — an enabled command with no handler is a
/// button that does nothing.
public enum NowPlayingRemoteCommand: CaseIterable, Sendable {
    case play
    case pause
    case toggle
    case skipBackward
    case skipForward
}

/// What pressing one should do to the model.
public enum NowPlayingAction: Equatable, Sendable {
    case play
    case pause
    case toggle
    /// Back to the top of the passage — the app's `restartLoop`, which `F` also
    /// invokes.
    case restartLoop
    case seek(FrameIndex)
    /// No track, so nothing to do.
    case none
}

/// Both lock-screen decisions, as pure functions.
public enum NowPlayingPolicy {

    /// Whether `current` is worth telling the system about.
    ///
    /// The system extrapolates position between updates from
    /// `(elapsed, rate, timestamp)`, so ordinary forward motion needs no
    /// message at all — and the display link that drives this polls sixty times
    /// a second. What does need one is any change it cannot predict: a
    /// different track, speed, loop, ramp or transport state, or the playhead
    /// moving *backwards*, which is a loop wrap or a seek.
    public static func shouldPublish(
        previous: NowPlayingSnapshot?, current: NowPlayingSnapshot
    ) -> Bool {
        guard let previous else { return true }
        if previous.playhead > current.playhead { return true }
        var predicted = previous
        predicted.playhead = current.playhead
        return predicted != current
    }

    /// What a button means, given what the app is doing.
    ///
    /// `skipSeconds` is the app's coarse "Rewind / skip" amount, passed in
    /// rather than read here so that changing it in Settings changes the lock
    /// screen and there is no second number to keep in sync.
    public static func action(
        for command: NowPlayingRemoteCommand, snapshot: NowPlayingSnapshot,
        skipSeconds: Double
    ) -> NowPlayingAction {
        guard snapshot.trackURL != nil else { return .none }
        switch command {
        case .play: return .play
        case .pause: return .pause
        case .toggle: return .toggle
        case .skipBackward:
            // Inside a fenced-off passage, "back ten seconds" lands outside it.
            // The useful blind action is "again, from the top".
            if snapshot.loop.isEnabled, snapshot.loop.range.count > 0 { return .restartLoop }
            return .seek(target(in: snapshot, bySeconds: -skipSeconds))
        case .skipForward:
            return .seek(target(in: snapshot, bySeconds: skipSeconds))
        }
    }

    /// Reuses the keyboard's own stepping, so a lock-screen skip and a `⌥Z`
    /// land in the same place and the saturation and clamping have one
    /// implementation.
    private static func target(
        in snapshot: NowPlayingSnapshot, bySeconds seconds: Double
    ) -> FrameIndex {
        NudgeStepping.target(
            from: snapshot.playhead, bySeconds: seconds, sampleRate: snapshot.sampleRate,
            totalFrames: snapshot.totalFrames)
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

```sh
swift test --filter NowPlayingPolicyTests --no-parallel
```

Expected: PASS. If the seek frame numbers in `skipBackSeeks` or `skipForwardAlwaysSeeks` are off, read `NudgeStepping.target` and correct the *test's* arithmetic — do not change the stepping, which the whole keyboard depends on.

- [ ] **Step 5: Mutation-test both decisions**

Run each mutation, confirm the named test fails, then revert it and confirm green:

1. In `shouldPublish`, change `if previous.playhead > current.playhead` to `if false` → `backwardJumpPublishes` must fail.
2. In `shouldPublish`, delete the `predicted.playhead = current.playhead` line → `forwardMotionIsSilent` must fail.
3. In `action(for:)`, change `if snapshot.loop.isEnabled, snapshot.loop.range.count > 0` to `if snapshot.loop.range.count > 0` → `skipBackSeeksWithADisabledLoop` must fail.

- [ ] **Step 6: Commit**

```sh
git add Sources/ArtscribeUI/NowPlayingPolicy.swift Tests/ArtscribeUITests/NowPlayingPolicyTests.swift
git commit -m "When to tell the system, and what its buttons mean"
```

---

### Task 3: `NowPlayingController` — the iOS adapter

The only file that imports `MediaPlayer`. It registers the commands, publishes the info, and forwards actions to the model. It contains no decisions — every one of those is in Tasks 1 and 2.

**Files:**
- Create: `Sources/ArtscribeUI/NowPlayingController.swift`

**Interfaces:**
- Consumes: `NowPlayingSnapshot`, `NowPlayingInfo` (Task 1); `NowPlayingPolicy`, `NowPlayingRemoteCommand`, `NowPlayingAction` (Task 2); `ViewerModel` — `play()`, `pause()`, `seek(to:)`, `restartLoop()`, `isPlaying`, `playhead`, `totalFrames`, `sampleRate`, `speed.ratio`, `loop`, `ramp`, `trackURL`, `prefs.nudgeAmounts[.coarse]`.
- Produces: `NowPlayingController` — `@MainActor final class`, `init()`, `func update(from model: ViewerModel)`, `func clear()`.

- [ ] **Step 1: Write the implementation**

There is no unit test in this task: the file is a translation layer over a framework that exists only on a device, and every decision it could get wrong has already been tested in Tasks 1 and 2. Its correctness is verified on hardware in Task 4.

Create `Sources/ArtscribeUI/NowPlayingController.swift`:

```swift
#if !os(macOS)
import ArtscribeKit
import Foundation
import MediaPlayer

/// Publishes what is playing to the lock screen and Control Centre, and answers
/// their buttons.
///
/// **iOS only, and that is a decision rather than a limitation.**
/// `MPRemoteCommandCenter` is claimed process-globally by whichever app
/// registered most recently, so a Mac build doing this would silently capture
/// the hardware media keys from whatever the user actually had playing. On the
/// Mac the window is already on screen and the app is keyboard-first; there is
/// nothing to solve.
///
/// **This type holds no policy.** What to say lives in `NowPlayingInfo`, when to
/// say it and what the buttons mean live in `NowPlayingPolicy`, and both are
/// pure and unit-tested on macOS — which is the only reason any of this is
/// checkable without a device. Resist adding a rule here; it belongs next to its
/// tests.
@MainActor
public final class NowPlayingController {

    /// What was last handed to the info centre, so an unchanged snapshot costs
    /// nothing. See `NowPlayingPolicy.shouldPublish`.
    private var published: NowPlayingSnapshot?

    /// Set once. `MPRemoteCommandCenter` handlers accumulate — registering on
    /// every update would leave one press invoking the action many times.
    private var registered = false

    public init() {}

    /// Called from the same poll that already drives the playhead readout.
    /// Cheap on the overwhelming majority of calls: it builds a snapshot,
    /// compares, and returns.
    public func update(from model: ViewerModel) {
        register(model)
        let snapshot = Self.snapshot(of: model)
        guard NowPlayingPolicy.shouldPublish(previous: published, current: snapshot) else {
            return
        }
        published = snapshot
        publish(NowPlayingInfo(snapshot))
    }

    /// A closed track must not leave the previous one on the lock screen.
    public func clear() {
        published = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Reading the model

    private static func snapshot(of model: ViewerModel) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            trackURL: model.hasTrack ? model.trackURL : nil,
            playhead: model.playhead,
            totalFrames: model.totalFrames,
            sampleRate: model.sampleRate,
            speedRatio: model.speed.ratio,
            isPlaying: model.isPlaying,
            loop: model.loop,
            practice: NowPlayingPractice(
                isRunning: model.ramp.isRunning,
                repetition: model.ramp.repetition,
                total: model.ramp.total))
    }

    // MARK: - Publishing

    private func publish(_ info: NowPlayingInfo?) {
        guard let info else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.subtitle,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate
        ]
    }

    // MARK: - The buttons

    private func register(_ model: ViewerModel) {
        guard !registered else { return }
        registered = true
        let centre = MPRemoteCommandCenter.shared()

        // Everything not handled is switched off explicitly. An enabled command
        // with no handler draws a button that does nothing.
        centre.changePlaybackPositionCommand.isEnabled = false
        centre.nextTrackCommand.isEnabled = false
        centre.previousTrackCommand.isEnabled = false
        centre.seekForwardCommand.isEnabled = false
        centre.seekBackwardCommand.isEnabled = false

        handle(centre.playCommand, .play, model)
        handle(centre.pauseCommand, .pause, model)
        handle(centre.togglePlayPauseCommand, .toggle, model)
        handle(centre.skipBackwardCommand, .skipBackward, model)
        handle(centre.skipForwardCommand, .skipForward, model)
    }

    private func handle(
        _ command: MPRemoteCommand, _ which: NowPlayingRemoteCommand, _ model: ViewerModel
    ) {
        command.isEnabled = true
        // The interval iOS draws inside the skip glyph. The app's own coarse
        // "Rewind / skip" amount, so changing it in Settings changes the lock
        // screen and there is no second number to keep in sync.
        if let skip = command as? MPSkipIntervalCommand {
            skip.preferredIntervals = [NSNumber(value: model.prefs.nudgeAmounts[.coarse])]
        }
        command.addTarget { [weak self, weak model] _ in
            guard let self, let model else { return .noSuchContent }
            return self.perform(which, on: model)
        }
    }

    private func perform(
        _ command: NowPlayingRemoteCommand, on model: ViewerModel
    ) -> MPRemoteCommandHandlerStatus {
        let snapshot = Self.snapshot(of: model)
        let action = NowPlayingPolicy.action(
            for: command, snapshot: snapshot,
            skipSeconds: model.prefs.nudgeAmounts[.coarse])
        switch action {
        case .play: model.play()
        case .pause: model.pause()
        case .toggle: model.isPlaying ? model.pause() : model.play()
        case .restartLoop: model.restartLoop()
        case .seek(let frame): model.seek(to: frame)
        case .none: return .noSuchContent
        }
        update(from: model)
        return .success
    }
}
#endif
```

- [ ] **Step 2: Build for both platforms**

```sh
swift build
make ios-check
```

Expected: both succeed. `make ios-check` builds the iPad scheme, which is the only thing that compiles this file — a mistake inside the `#if` is invisible to `swift build`.

If `model.prefs.nudgeAmounts[.coarse]` does not compile, read `Sources/ArtscribeUI/Preferences.swift` and `Sources/ArtscribeUI/Nudging.swift` for the real accessor and use that; do not add a new one.

- [ ] **Step 3: Run the whole gate**

```sh
make check
```

Expected: green, with the test count from Tasks 1 and 2 included.

- [ ] **Step 4: Commit**

```sh
git add Sources/ArtscribeUI/NowPlayingController.swift
git commit -m "The MediaPlayer adapter, and nothing but"
```

---

### Task 4: Wire it up, and verify it on a device

Drive the controller from the poll that already exists, clear it when a track closes, and confirm on hardware — which is the only place this can be confirmed at all.

**Files:**
- Modify: `Sources/ArtscribeUI/DocumentView.swift`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `NowPlayingController` (Task 3).
- Produces: nothing further tasks depend on.

- [ ] **Step 1: Find where the playhead poll already runs**

```sh
grep -n "poll\|PlayheadClock\|onChange(of: model.playhead" Sources/ArtscribeUI/DocumentView.swift
```

The controller's `update(from:)` must be called wherever the view already learns the playhead moved. Do not add a second timer — `PlayheadClock` exists precisely so there is one.

- [ ] **Step 2: Hold the controller and drive it**

In `DocumentView`, add the state (iOS only) and call it from the existing poll. Adapt the anchor lines to what Step 1 found:

```swift
#if !os(macOS)
/// The lock screen and Control Centre. iOS only — see `NowPlayingController`.
@State private var nowPlaying = NowPlayingController()
#endif
```

and, where the playhead is already observed:

```swift
#if !os(macOS)
nowPlaying.update(from: model)
#endif
```

and in the same `onDisappear` that calls `model.teardownPlayback()`:

```swift
#if !os(macOS)
nowPlaying.clear()
#endif
```

- [ ] **Step 3: Build and run the gate**

```sh
make check
make ios-check
```

Expected: both green.

- [ ] **Step 4: Verify on the simulator that nothing regressed**

```sh
xcodegen generate
DEV=$(./App/ipad-simulator.sh)
xcrun simctl boot "$DEV" 2>/dev/null; xcrun simctl bootstatus "$DEV" -b
xcodebuild build -scheme ArtscribeiPad -destination "platform=iOS Simulator,id=$DEV" \
  -derivedDataPath .build/nowplaying-dd -quiet
APP=$(find .build/nowplaying-dd -name "Artscripture.app" -path "*iphonesimulator*" | head -1)
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_ARTSCRIBE_SILENT=1 xcrun simctl launch "$DEV" com.artscribe.Artscribe
```

Expected: the app launches and behaves as before. A simulator cannot show a lock screen, so this proves only that the wiring did not break anything.

**Shut the simulator down when finished** — `xcrun simctl shutdown all`. A stranded simulator cost 313% CPU for 54 minutes on 2026-08-04.

- [ ] **Step 5: Verify on the physical iPad**

```sh
make ipad
```

Then, with a track open and a loop of about four seconds set:

| Check | Expect |
|---|---|
| Lock the screen | Title, subtitle, and transport controls appear |
| Subtitle at 100%, no loop | `100%` |
| Set a loop, look again | `50% · looping 1:23–1:27` style |
| **Play at 50% and watch the elapsed time for 30 s** | It tracks the audio. If it runs roughly twice as fast, the rate is wrong — Task 1, Step 5 |
| Press ⏸ then ⏵ on the lock screen | Pauses and resumes |
| Press ⟲ with the loop enabled | Jumps to the loop's in point |
| Press ⟳ | Moves forward ten seconds |
| Start a practice ramp, lock, wait for two repetitions | Subtitle's rep count advances |
| Close the track, lock the screen | Nothing shown — no stale track |
| Swipe into Control Centre while playing | Same information and controls |

- [ ] **Step 6: Record what the device run showed**

Add to `CLAUDE.md`, after the `AudioSessionCoordinator` paragraphs in the platform section:

```markdown
**The lock screen is `MPNowPlayingInfoCenter`, and the rate it is given must be the
*real* one.** `NowPlayingInfo` publishes `speed.ratio` while playing and `0` while
paused. The system extrapolates position between updates from
`(elapsed, rate, timestamp)`, so publishing `1.0` at half speed makes the lock-screen
timer run at twice the true rate and visibly outrun the audio — the
speed-ratio-versus-time-ratio trap in a new place, and mutation-tested for it.

Nothing republishes on the display link's tick. `NowPlayingPolicy.shouldPublish`
compares consecutive snapshots and speaks only when something the system cannot
predict has changed — including the playhead moving *backwards*, which is a loop wrap.

`MPRemoteCommandCenter` is **iOS only on purpose**: it is claimed process-globally by
whichever app registered last, so a Mac build would silently capture the media keys
from whatever the user actually had playing.
```

- [ ] **Step 7: Run the full acceptance harness**

```sh
make acceptance AUDIO=<a real audio file>
```

Expected: `0 failure(s) — every group ran`. This touches `DocumentView`, which the harness drives heavily. The run takes the foreground for about three minutes — do not start it while using the machine.

- [ ] **Step 8: Commit**

```sh
git add Sources/ArtscribeUI/DocumentView.swift CLAUDE.md
git commit -m "Drive the lock screen from the poll that already exists"
```

---

## Self-Review

**Spec coverage.** §2 architecture → Tasks 1–3. §3 published fields → Task 1. §3.1 subtitle → Task 1 (four tests). §3.2 rate → Task 1 (test + mutation) and Task 4 Step 5. §3.3 when it publishes → Task 2 `shouldPublish`. §4 commands and mapping → Tasks 2 and 3, including the explicit disabling of unhandled commands and `preferredIntervals`. §5 testing → the test blocks in Tasks 1 and 2 plus the device table in Task 4. §6 risks: stale info on track close → Task 3 `clear()` and Task 4 Step 2; no render-thread writes → the controller is `@MainActor`.

**Deliberately not built:** artwork, scrubbing, cue-sheet track names, macOS support. All four are listed as out of scope in spec §1.2.

**Type consistency.** `NowPlayingSnapshot`, `NowPlayingInfo`, `NowPlayingPractice`, `NowPlayingPolicy`, `NowPlayingRemoteCommand`, `NowPlayingAction`, `NowPlayingController` are spelled identically across all four tasks. `shouldPublish(previous:current:)` and `action(for:snapshot:skipSeconds:)` match between Task 2's implementation and Task 3's call sites. `update(from:)` and `clear()` match between Tasks 3 and 4.

**One thing the implementer should expect to adjust:** the exact anchor lines in `DocumentView` (Task 4, Step 2). The file is large and the plan deliberately says "adapt to what Step 1 found" rather than quoting line numbers that will have moved.
