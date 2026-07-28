# Artscribe Audio Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless audio core of Artscribe — decode, waveform peaks, time-stretch, and a real-time playback engine with seamless looping — delivered as SwiftPM modules plus a CLI that can play a track at any speed on a loop.

**Architecture:** Six SwiftPM modules with strictly one-way dependencies. `ArtscribeKit` (pure value types, zero platform deps) ← `AudioDecode` / `Waveform` / `TimeStretch` ← `Playback`. All audio processing is expressed as "frames in, frames out" so it is testable with no CoreAudio and no audio hardware; `AVAudioSourceNode` is attached only at the outermost edge in the final task. The `TimeStretcher` protocol exists specifically so `PlaybackEngine` can be tested against a deterministic identity stub.

**Tech Stack:** Swift 6.3, SwiftPM (tools-version 6.2), Swift Testing (`import Testing`), AVFoundation, Accelerate, `Synchronization` (`Atomic`), Rubber Band 4.0 via its C API.

This plan implements §§ 3–5, 9, 10 of `docs/superpowers/specs/2026-07-27-artscribe-design.md`. UI, input bindings, session sidecars, and the app shell are Plan 2.

## Global Constraints

- Swift tools-version **6.2** and `platforms: [.macOS(.v26)]`. `.v26` is unavailable below tools-version 6.2 — this is verified, do not lower it.
- Every module except the CLI must build and test under plain `swift test`. No Xcode project, no scheme, no simulator.
- `ArtscribeKit` imports **nothing**. Dependencies point one way only (see module table in spec §4). `Playback` must never import UI.
- Speed semantics: user-facing **speed ratio** (0.5 = half speed) is the reciprocal of Rubber Band's **time ratio** (2.0 = twice as long). `timeRatio == 1.0 / speedRatio`. Never pass one where the other is expected.
- Speed range **0.10 – 2.00** inclusive.
- Sample positions are `Int64` frames (`FrameIndex`), never seconds, anywhere correctness matters.
- Inside a render block: no allocation, no locks, no `async`/`await`, no actor access, no Swift retain/release, no Foundation collections.
- Prerequisite: `brew install rubberband`. Verified present at 4.0.0.
- Real integration media lives at `$ARTSCRIBE_TEST_MEDIA_DIR`; tests **skip cleanly** when unset. Never commit audio over 100 KB.
- **Every task ends with `make check` passing** (swift-format lint, SwiftLint, tests). Warnings are errors. Task 0 establishes these gates.
- Reuse `sharedSwiftSettings` from `Package.swift` on every target added.

---

### Task 0: Tooling and quality gates

Done first so every later task is checked by the same gates. Formatting, linting,
and warnings-as-errors are cheap to adopt now and expensive to retrofit across
nine tasks of existing code.

**Files:**
- Create: `.swift-format`
- Create: `.swiftlint.yml`
- Create: `Makefile`
- Create: `.github/workflows/ci.yml`
- Create: `Package.swift` (minimal; Task 1 fills in the real targets)

**Interfaces:**
- Consumes: nothing
- Produces: `make format`, `make lint`, `make test`, `make check`; the
  `sharedSwiftSettings` array in `Package.swift` that every later target reuses

- [ ] **Step 1: Install the toolchain**

`swift format` ships inside the Swift 6.3 toolchain — do not install it separately.
SwiftLint and XcodeGen come from Homebrew.

Run: `brew install swiftlint xcodegen rubberband`
Expected: swiftlint ≥ 0.65, xcodegen ≥ 2.46, rubberband ≥ 4.0.

- [ ] **Step 2: Create the formatter configuration**

`.swift-format`:

```json
{
  "version": 1,
  "lineLength": 100,
  "indentation": { "spaces": 4 },
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeEachArgument": false,
  "indentConditionalCompilationBlocks": false,
  "rules": {
    "AlwaysUseLowerCamelCase": true,
    "NeverUseImplicitlyUnwrappedOptionals": true,
    "UseShorthandTypeNames": true,
    "OrderedImports": true,
    "ReturnVoidInsteadOfEmptyTuple": true
  }
}
```

- [ ] **Step 3: Create the linter configuration**

`.swiftlint.yml`:

```yaml
included:
  - Sources
  - Tests
excluded:
  - .build

analyzer_rules:
  - unused_import

opt_in_rules:
  - force_unwrapping
  - empty_count
  - explicit_init
  - first_where
  - redundant_nil_coalescing
  - toggle_bool
  - unneeded_parentheses_in_closure_argument

line_length:
  warning: 100
  error: 140
  ignores_comments: true

identifier_name:
  # Audio code legitimately uses short names: n, c, b, lo, hi, fpp.
  min_length: 1
  excluded: [i, j, k, n, c, b, r, s, v, lo, hi, fpp, dst, src]

function_body_length:
  warning: 80
  error: 140

type_body_length:
  warning: 300
  error: 450

# The render path deliberately uses unsafe pointer arithmetic.
force_unwrapping:
  severity: warning
```

- [ ] **Step 4: Create the minimal Package.swift with shared settings**

Task 1 replaces the target list; the `sharedSwiftSettings` array below is what every
later target must reuse.

```swift
// swift-tools-version: 6.2
import PackageDescription

/// Applied to every target. Swift 6 language mode already implies complete
/// strict concurrency; `treatAllWarnings(as: .error)` keeps the build honest.
let sharedSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "Artscribe",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArtscribeKit", targets: ["ArtscribeKit"])
    ],
    targets: [
        .target(name: "ArtscribeKit", swiftSettings: sharedSwiftSettings)
    ]
)
```

Create `Sources/ArtscribeKit/Placeholder.swift` so the target compiles:

```swift
// Replaced in Task 1 by FrameIndex.swift.
enum Placeholder {}
```

If `treatAllWarnings(as:)` is rejected by this toolchain, fall back to
`.unsafeFlags(["-warnings-as-errors"])` and note the substitution in the report.

- [ ] **Step 5: Create the Makefile**

```make
.PHONY: bootstrap format lint test coverage check clean

bootstrap:
	brew list rubberband >/dev/null 2>&1 || brew install rubberband
	brew list swiftlint  >/dev/null 2>&1 || brew install swiftlint
	brew list xcodegen   >/dev/null 2>&1 || brew install xcodegen

# swift format ships with the Swift 6.3 toolchain.
format:
	swift format --in-place --recursive Sources Tests

format-check:
	swift format lint --strict --recursive Sources Tests

lint:
	swiftlint lint --quiet --strict

test:
	swift test

coverage:
	swift test --enable-code-coverage

# The single gate. Run before every commit.
check: format-check lint test

clean:
	rm -rf .build
```

- [ ] **Step 6: Verify the gates actually catch problems**

Write a deliberately bad file, confirm each gate rejects it, then delete it.

```bash
mkdir -p Sources/ArtscribeKit
cat > Sources/ArtscribeKit/Bad.swift <<'EOF'
enum Bad {
      static let VeryBadlyIndentedAndNamed =    1
}
EOF
make format-check   # expect: FAIL (indentation / line breaks)
make lint           # expect: FAIL (identifier_name — should be lowerCamelCase)
rm Sources/ArtscribeKit/Bad.swift
```

Expected: both commands exit non-zero while `Bad.swift` exists. If either passes,
the configuration is not being picked up — check that `.swift-format` and
`.swiftlint.yml` are at the repository root.

- [ ] **Step 7: Verify the clean tree passes every gate**

Run: `make check`
Expected: `format-check` and `lint` pass. **`test` will fail with `error: no tests
found; create a target in the 'Tests' directory`** — SwiftPM treats a package with no
test target as an error, not an empty pass. This is expected and transient: Task 1 adds
`CRubberBandTests` and the gate goes green from there on. Do not add a placeholder test
target to paper over it, and do not weaken `make test` to tolerate missing tests — that
would mask real failures for the rest of the project.

- [ ] **Step 8: Create the CI workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build-and-test:
    # macos-26 is GA on arm64 and is the only image with a Swift 6.3 /
    # macOS 26 SDK toolchain. macos-15 cannot build platforms: [.macOS(.v26)].
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      - name: Show toolchain
        run: swift --version && swift format --version && sw_vers

      - name: Install dependencies
        run: brew install rubberband swiftlint

      - name: Check formatting
        run: swift format lint --strict --recursive Sources Tests

      - name: Lint
        run: swiftlint lint --quiet --strict

      - name: Test
        run: swift test
```

Note: integration tests that read `$ARTSCRIBE_TEST_MEDIA_DIR` skip automatically in
CI because the variable is unset. That is intended — CI must stay green without the
copyrighted reference album.

- [ ] **Step 9: Commit**

```bash
git add .swift-format .swiftlint.yml Makefile Package.swift Sources .github
git commit -m "build: formatting, linting, warnings-as-errors, and CI gates"
```

---

### Task 1: Package scaffold and Rubber Band linkage

The riskiest dependency, done first. The test asserts we actually get the R3 engine, not a silent fallback.

**Files:**
- Create: `Package.swift`
- Create: `Sources/CRubberBand/module.modulemap`
- Create: `Sources/CRubberBand/shim.h`
- Create: `Sources/ArtscribeKit/FrameIndex.swift`
- Create: `Makefile`
- Create: `CLAUDE.md`
- Test: `Tests/CRubberBandTests/LinkageTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `public typealias FrameIndex = Int64` in `ArtscribeKit`; module `CRubberBand` exposing the Rubber Band C API

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Artscribe",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArtscribeKit", targets: ["ArtscribeKit"]),
        .library(name: "AudioDecode", targets: ["AudioDecode"]),
        .library(name: "Waveform", targets: ["Waveform"]),
        .library(name: "TimeStretch", targets: ["TimeStretch"]),
        .library(name: "Playback", targets: ["Playback"]),
    ],
    targets: [
        .systemLibrary(
            name: "CRubberBand",
            path: "Sources/CRubberBand",
            pkgConfig: "rubberband",
            providers: [.brew(["rubberband"])]
        ),
        .target(name: "ArtscribeKit"),
        .testTarget(name: "CRubberBandTests", dependencies: ["CRubberBand"]),
    ]
)
```

- [ ] **Step 2: Create the C shim and module map**

`Sources/CRubberBand/shim.h`:

```c
#include <rubberband/rubberband-c.h>
```

`Sources/CRubberBand/module.modulemap`:

```
module CRubberBand [system] {
    header "shim.h"
    link "rubberband"
    export *
}
```

- [ ] **Step 3: Create the one placeholder type so ArtscribeKit compiles**

`Sources/ArtscribeKit/FrameIndex.swift`:

```swift
/// A sample-frame position or count. Frames, never seconds, wherever correctness matters.
public typealias FrameIndex = Int64
```

- [ ] **Step 4: Write the failing linkage test**

`Tests/CRubberBandTests/LinkageTests.swift`:

```swift
import Testing
import CRubberBand

@Test func finerEngineIsR3() {
    let opts = RubberBandOptions(
        RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue)
    let state = rubberband_new(44100, 2, opts, 1.0, 1.0)
    #expect(state != nil)
    defer { rubberband_delete(state) }
    #expect(rubberband_get_engine_version(state) == 3)
    #expect(rubberband_get_channel_count(state) == 2)
}

@Test func fasterEngineIsR2() {
    let opts = RubberBandOptions(
        RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFaster.rawValue)
    let state = rubberband_new(44100, 2, opts, 1.0, 1.0)
    #expect(state != nil)
    defer { rubberband_delete(state) }
    #expect(rubberband_get_engine_version(state) == 2)
}

@Test func realtimeModeReportsStartDelay() {
    let opts = RubberBandOptions(
        RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue)
    let state = rubberband_new(44100, 2, opts, 1.0, 1.0)
    defer { rubberband_delete(state) }
    // R3 realtime reports a non-zero start delay that PlaybackEngine must compensate.
    #expect(rubberband_get_start_delay(state) > 0)
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `swift test --filter CRubberBandTests`
Expected: FAIL — the package does not build yet if `rubberband` is not installed, or the test binary does not exist.

- [ ] **Step 6: Create the Makefile and bootstrap**

`Makefile`:

```make
.PHONY: bootstrap build test clean

bootstrap:
	brew list rubberband >/dev/null 2>&1 || brew install rubberband

build:
	swift build

test:
	swift test

clean:
	rm -rf .build
```

Run: `make bootstrap`

- [ ] **Step 7: Write CLAUDE.md**

`CLAUDE.md`:

```markdown
# Artscribe — working notes

Design spec: `docs/superpowers/specs/2026-07-27-artscribe-design.md`

## Commands
- `make bootstrap` — install Homebrew prerequisites (rubberband)
- `swift test` — full headless suite, no Xcode and no audio hardware needed
- `swift test --filter <TargetName>` — one module

## Module boundaries — dependencies point one way only
ArtscribeKit ← AudioDecode / Waveform / TimeStretch ← Playback ← ArtscribeUI

`ArtscribeKit` imports **nothing**. If a type needs an upward import, it belongs
in `ArtscribeKit`. `Playback` must never import UI.

## Speed vs time ratio
User-facing **speed ratio** (0.5 = half speed) is the reciprocal of Rubber Band's
**time ratio** (2.0 = twice as long). `timeRatio == 1.0 / speedRatio`. Swapping
these is the single easiest bug to introduce here.

## Real-time rules — inside PlaybackEngine.render and the AVAudioSourceNode block
No allocation. No locks. No `async`/`await`. No actor access. No Swift
retain/release. No Foundation collections. Rubber Band is pre-sized via
`setMaxProcessSize` at configure time so it never allocates during rendering.

Main actor → render thread is `CommandRing` only. Render thread → main actor is
one atomic frame counter that the UI polls. The audio thread never pushes.

## Looping
Never `reset()` the stretcher at a loop boundary — feed continuously across it.
Resetting flushes the overlap state and clicks on every repetition.

## Test media
Integration tests read `$ARTSCRIBE_TEST_MEDIA_DIR` and skip when unset. Never
commit audio files over 100 KB.
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `swift test --filter CRubberBandTests`
Expected: PASS, 3 tests. If `finerEngineIsR3` reports version 2, the options constant is being dropped — check that `RubberBandOptionEngineFiner.rawValue` (0x20000000) is OR-ed in.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Makefile CLAUDE.md Sources/ Tests/
git commit -m "feat: package scaffold and verified Rubber Band R3 linkage"
```

---

### Task 2: Viewport — zoom, scroll, and playhead anchoring

Pure math, no platform deps. Playhead-anchored zoom is the behaviour that makes keyboard-only zooming usable (spec §6.1).

**Files:**
- Create: `Sources/ArtscribeKit/FrameRange.swift`
- Create: `Sources/ArtscribeKit/Viewport.swift`
- Test: `Tests/ArtscribeKitTests/ViewportTests.swift`

**Interfaces:**
- Consumes: `FrameIndex` (Task 1)
- Produces: `FrameRange(start:count:)` with `.end`, `.isEmpty`, `.clamped(to:)`; `Viewport(totalFrames:widthPixels:)` with `startFrame`, `framesPerPixel`, `visibleFrames`, `endFrame`, `zoom(by:anchorFrame:)`, `scroll(byPixels:)`, `fit()`, `zoom(to:)`, `frame(atPixel:)`, `pixel(forFrame:)`

- [ ] **Step 1: Write the failing tests**

`Tests/ArtscribeKitTests/ViewportTests.swift`:

```swift
import Testing
@testable import ArtscribeKit

private func makeViewport() -> Viewport {
    Viewport(totalFrames: 1_000_000, widthPixels: 1000)   // fit => 1000 frames/pixel
}

@Test func fitShowsWholeFile() {
    var v = makeViewport()
    v.fit()
    #expect(v.startFrame == 0)
    #expect(v.framesPerPixel == 1000)
    #expect(v.endFrame == 1_000_000)
}

@Test func zoomKeepsAnchorFrameUnderTheSamePixel() {
    var v = makeViewport()
    v.fit()
    let anchor: FrameIndex = 400_000
    let pixelBefore = v.pixel(forFrame: anchor)
    v.zoom(by: 4.0, anchorFrame: anchor)
    let pixelAfter = v.pixel(forFrame: anchor)
    #expect(abs(pixelBefore - pixelAfter) < 0.5)
    #expect(v.framesPerPixel == 250)
}

@Test func zoomOutClampsToFit() {
    var v = makeViewport()
    v.fit()
    v.zoom(by: 0.01, anchorFrame: 500_000)   // try to zoom way out
    #expect(v.framesPerPixel == 1000)        // never coarser than fit
    #expect(v.startFrame == 0)
}

@Test func zoomInClampsAtMaximum() {
    var v = makeViewport()
    v.fit()
    for _ in 0..<50 { v.zoom(by: 4.0, anchorFrame: 500_000) }
    #expect(v.framesPerPixel >= Viewport.minFramesPerPixel)
    #expect(v.framesPerPixel == Viewport.minFramesPerPixel)
}

@Test func scrollClampsAtBothEnds() {
    var v = makeViewport()
    v.fit()
    v.zoom(by: 10.0, anchorFrame: 0)        // 100 frames/pixel, 100_000 visible
    v.scroll(byPixels: -10_000)
    #expect(v.startFrame == 0)
    v.scroll(byPixels: 1_000_000)
    #expect(v.endFrame == 1_000_000)
    #expect(v.startFrame == 1_000_000 - v.visibleFrames)
}

@Test func zoomToRangeFramesTheRange() {
    var v = makeViewport()
    v.zoom(to: FrameRange(start: 200_000, count: 100_000))
    #expect(v.startFrame == 200_000)
    #expect(v.visibleFrames == 100_000)
}

@Test func pixelAndFrameRoundTrip() {
    var v = makeViewport()
    v.fit()
    v.zoom(by: 8.0, anchorFrame: 500_000)
    let f: FrameIndex = 500_000
    #expect(v.frame(atPixel: v.pixel(forFrame: f)) == f)
}

@Test func frameRangeClampsToBounds() {
    let r = FrameRange(start: -50, count: 200).clamped(to: 100)
    #expect(r.start == 0)
    #expect(r.end == 100)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArtscribeKitTests`
Expected: FAIL — `cannot find 'Viewport' in scope`.

- [ ] **Step 3: Implement FrameRange**

`Sources/ArtscribeKit/FrameRange.swift`:

```swift
/// A half-open range of sample frames: [start, start + count).
public struct FrameRange: Equatable, Sendable, Codable {
    public var start: FrameIndex
    public var count: FrameIndex

    public init(start: FrameIndex, count: FrameIndex) {
        self.start = start
        self.count = count
    }

    public var end: FrameIndex { start + count }
    public var isEmpty: Bool { count <= 0 }

    /// Clamps into [0, total], collapsing to empty at `start` if inverted.
    public func clamped(to total: FrameIndex) -> FrameRange {
        let s = Swift.max(0, Swift.min(start, total))
        let e = Swift.max(s, Swift.min(end, total))
        return FrameRange(start: s, count: e - s)
    }

    public func contains(_ frame: FrameIndex) -> Bool {
        frame >= start && frame < end
    }
}
```

- [ ] **Step 4: Implement Viewport**

`Sources/ArtscribeKit/Viewport.swift`:

```swift
/// The visible window over the timeline, shared by every lane.
///
/// Zoom always anchors on a caller-supplied frame (normally the playhead) so the
/// anchor stays under the same pixel — see spec §6.1.
public struct Viewport: Equatable, Sendable {
    /// Most zoomed-in state: 100 pixels per frame.
    public static let minFramesPerPixel: Double = 0.01

    public let totalFrames: FrameIndex
    public private(set) var widthPixels: Int
    public private(set) var startFrame: FrameIndex
    public private(set) var framesPerPixel: Double

    public init(totalFrames: FrameIndex, widthPixels: Int) {
        self.totalFrames = Swift.max(0, totalFrames)
        self.widthPixels = Swift.max(1, widthPixels)
        self.startFrame = 0
        self.framesPerPixel = 1
        fit()
    }

    /// Coarsest useful zoom: the whole file exactly fills the width.
    public var maxFramesPerPixel: Double {
        Swift.max(Self.minFramesPerPixel, Double(totalFrames) / Double(widthPixels))
    }

    public var visibleFrames: FrameIndex {
        FrameIndex((Double(widthPixels) * framesPerPixel).rounded())
    }

    public var endFrame: FrameIndex { startFrame + visibleFrames }

    public mutating func resize(widthPixels: Int) {
        self.widthPixels = Swift.max(1, widthPixels)
        clamp()
    }

    public mutating func fit() {
        framesPerPixel = maxFramesPerPixel
        startFrame = 0
    }

    /// `factor > 1` zooms in. `anchorFrame` stays under the same pixel.
    public mutating func zoom(by factor: Double, anchorFrame: FrameIndex) {
        guard factor > 0, factor.isFinite else { return }
        let anchorPixel = pixel(forFrame: anchorFrame)
        let target = framesPerPixel / factor
        framesPerPixel = Swift.min(maxFramesPerPixel,
                                   Swift.max(Self.minFramesPerPixel, target))
        let newStart = Double(anchorFrame) - anchorPixel * framesPerPixel
        startFrame = FrameIndex(newStart.rounded())
        clamp()
    }

    public mutating func zoom(to range: FrameRange) {
        let r = range.clamped(to: totalFrames)
        guard !r.isEmpty else { return }
        framesPerPixel = Swift.min(maxFramesPerPixel,
                                   Swift.max(Self.minFramesPerPixel,
                                             Double(r.count) / Double(widthPixels)))
        startFrame = r.start
        clamp()
    }

    public mutating func scroll(byPixels pixels: Int) {
        startFrame += FrameIndex((Double(pixels) * framesPerPixel).rounded())
        clamp()
    }

    public func pixel(forFrame frame: FrameIndex) -> Double {
        Double(frame - startFrame) / framesPerPixel
    }

    public func frame(atPixel pixel: Double) -> FrameIndex {
        startFrame + FrameIndex((pixel * framesPerPixel).rounded())
    }

    private mutating func clamp() {
        let maxStart = Swift.max(0, totalFrames - visibleFrames)
        startFrame = Swift.max(0, Swift.min(startFrame, maxStart))
    }
}
```

- [ ] **Step 5: Register the test target**

In `Package.swift`, add to `targets`:

```swift
        .testTarget(name: "ArtscribeKitTests", dependencies: ["ArtscribeKit"]),
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter ArtscribeKitTests`
Expected: PASS, 8 tests.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/ArtscribeKit Tests/ArtscribeKitTests
git commit -m "feat: Viewport with playhead-anchored zoom and clamped scrolling"
```

---

### Task 3: Selection, LoopRegion, and SpeedState

**Files:**
- Create: `Sources/ArtscribeKit/Selection.swift`
- Create: `Sources/ArtscribeKit/LoopRegion.swift`
- Create: `Sources/ArtscribeKit/SpeedState.swift`
- Test: `Tests/ArtscribeKitTests/SelectionTests.swift`
- Test: `Tests/ArtscribeKitTests/SpeedStateTests.swift`

**Interfaces:**
- Consumes: `FrameIndex`, `FrameRange` (Tasks 1–2)
- Produces: `Selection(anchor:head:)` with `.range`, `.isEmpty`, `.extend(to:)`, `.clear()`; `LoopRegion(range:isEnabled:)`; `StretchEngine` enum (`.studio`, `.fast`); `SpeedState` with `.ratio`, `.timeRatio`, `.engine`, `.step(by:)`, `.setRatio(_:)`, `SpeedState.min/maxRatio`

- [ ] **Step 1: Write the failing tests**

`Tests/ArtscribeKitTests/SelectionTests.swift`:

```swift
import Testing
@testable import ArtscribeKit

@Test func emptySelectionHasEmptyRange() {
    let s = Selection()
    #expect(s.isEmpty)
    #expect(s.range.isEmpty)
}

@Test func selectionNormalisesBackwardDrag() {
    var s = Selection()
    s.begin(at: 900)
    s.extend(to: 400)
    #expect(s.range == FrameRange(start: 400, count: 500))
    #expect(!s.isEmpty)
}

@Test func selectionForwardDrag() {
    var s = Selection()
    s.begin(at: 100)
    s.extend(to: 350)
    #expect(s.range == FrameRange(start: 100, count: 250))
}

@Test func clearMakesSelectionEmpty() {
    var s = Selection()
    s.begin(at: 10); s.extend(to: 99)
    s.clear()
    #expect(s.isEmpty)
}

@Test func loopRegionDefaultsDisabled() {
    let l = LoopRegion(range: FrameRange(start: 0, count: 100))
    #expect(!l.isEnabled)
}
```

`Tests/ArtscribeKitTests/SpeedStateTests.swift`:

```swift
import Testing
@testable import ArtscribeKit

@Test func defaultsToFullSpeedStudio() {
    let s = SpeedState()
    #expect(s.ratio == 1.0)
    #expect(s.timeRatio == 1.0)
    #expect(s.engine == .studio)
}

@Test func timeRatioIsReciprocalOfSpeed() {
    var s = SpeedState()
    s.setRatio(0.5)
    #expect(s.ratio == 0.5)
    #expect(s.timeRatio == 2.0)      // half speed => twice as long
    s.setRatio(2.0)
    #expect(s.timeRatio == 0.5)
}

@Test func stepClampsAtBounds() {
    var s = SpeedState()
    s.setRatio(SpeedState.minRatio)
    s.step(by: -0.05)
    #expect(s.ratio == SpeedState.minRatio)
    s.setRatio(SpeedState.maxRatio)
    s.step(by: 0.05)
    #expect(s.ratio == SpeedState.maxRatio)
}

@Test func setRatioClampsOutOfRangeInput() {
    var s = SpeedState()
    s.setRatio(99)
    #expect(s.ratio == SpeedState.maxRatio)
    s.setRatio(0)
    #expect(s.ratio == SpeedState.minRatio)
}

@Test func stepMovesByExactDelta() {
    var s = SpeedState()
    s.step(by: -0.05)
    #expect(abs(s.ratio - 0.95) < 1e-9)
}

@Test func boundsMatchSpec() {
    #expect(SpeedState.minRatio == 0.10)
    #expect(SpeedState.maxRatio == 2.00)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ArtscribeKitTests`
Expected: FAIL — `cannot find 'Selection' in scope`, `cannot find 'SpeedState' in scope`.

- [ ] **Step 3: Implement Selection and LoopRegion**

`Sources/ArtscribeKit/Selection.swift`:

```swift
/// A selection expressed as an anchor and a moving head, so backward drags
/// and shift-extension normalise for free.
public struct Selection: Equatable, Sendable, Codable {
    public private(set) var anchor: FrameIndex
    public private(set) var head: FrameIndex
    public private(set) var isEmpty: Bool

    public init() {
        anchor = 0
        head = 0
        isEmpty = true
    }

    public init(anchor: FrameIndex, head: FrameIndex) {
        self.anchor = anchor
        self.head = head
        self.isEmpty = anchor == head
    }

    public var range: FrameRange {
        guard !isEmpty else { return FrameRange(start: anchor, count: 0) }
        let lo = Swift.min(anchor, head)
        let hi = Swift.max(anchor, head)
        return FrameRange(start: lo, count: hi - lo)
    }

    public mutating func begin(at frame: FrameIndex) {
        anchor = frame
        head = frame
        isEmpty = true
    }

    public mutating func extend(to frame: FrameIndex) {
        head = frame
        isEmpty = (frame == anchor)
    }

    public mutating func clear() {
        self = Selection()
    }
}
```

`Sources/ArtscribeKit/LoopRegion.swift`:

```swift
public struct LoopRegion: Equatable, Sendable, Codable {
    public var range: FrameRange
    public var isEnabled: Bool

    public init(range: FrameRange = FrameRange(start: 0, count: 0), isEnabled: Bool = false) {
        self.range = range
        self.isEnabled = isEnabled
    }

    /// Only loop when enabled and the region is long enough to be meaningful.
    public var isActive: Bool { isEnabled && range.count > 0 }
}
```

- [ ] **Step 4: Implement SpeedState**

`Sources/ArtscribeKit/SpeedState.swift`:

```swift
public enum StretchEngine: String, Sendable, Codable, CaseIterable {
    case studio   // Rubber Band R3 "Finer"
    case fast     // Rubber Band R2 "Faster"
}

/// Playback speed. `ratio` is user-facing (0.5 == half speed); `timeRatio` is what
/// Rubber Band consumes and is its reciprocal. See Global Constraints.
public struct SpeedState: Equatable, Sendable, Codable {
    public static let minRatio: Double = 0.10
    public static let maxRatio: Double = 2.00

    public private(set) var ratio: Double
    public var engine: StretchEngine

    public init(ratio: Double = 1.0, engine: StretchEngine = .studio) {
        self.ratio = Self.clamp(ratio)
        self.engine = engine
    }

    public var timeRatio: Double { 1.0 / ratio }

    public mutating func setRatio(_ newValue: Double) {
        ratio = Self.clamp(newValue)
    }

    public mutating func step(by delta: Double) {
        setRatio(ratio + delta)
    }

    private static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 1.0 }
        return Swift.min(maxRatio, Swift.max(minRatio, v))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ArtscribeKitTests`
Expected: PASS, 19 tests total (8 from Task 2 plus 11 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/ArtscribeKit Tests/ArtscribeKitTests
git commit -m "feat: Selection, LoopRegion, and SpeedState with reciprocal time ratio"
```

---

### Task 4: Audio decoding to Float32

The 24-bit correctness requirement from spec §4.1 is the point of this task. The default `AVAssetReader` path can hand back Int16 and silently discard 8 bits of a 24-bit source.

**Files:**
- Create: `Sources/AudioDecode/AudioStorage.swift`
- Create: `Sources/AudioDecode/DecodedAudio.swift`
- Create: `Sources/AudioDecode/DecodeError.swift`
- Create: `Sources/AudioDecode/AudioFileDecoder.swift`
- Create: `Tests/Fixtures/generate.sh`
- Test: `Tests/AudioDecodeTests/DecodeTests.swift`

**Interfaces:**
- Consumes: `FrameIndex` (Task 1)
- Produces: `AudioStorage` (class, `channelPointers: [UnsafeMutablePointer<Float>]`); `DecodedAudio` with `.channels`, `.sampleRate`, `.frameCount`, `.storage`, `.channel(_:)`; `DecodeError`; `AudioFileDecoder.decode(url:progress:) async throws -> DecodedAudio`

- [ ] **Step 1: Write the fixture generation script**

`Tests/Fixtures/generate.sh` (then `chmod +x` it):

```bash
#!/usr/bin/env bash
# Regenerates the small test fixtures. Requires ffmpeg and afconvert.
# All outputs are ~2s of 440 Hz stereo sine and stay well under 100 KB.
set -euo pipefail
cd "$(dirname "$0")"

ffmpeg -y -loglevel error -f lavfi \
  -i "sine=frequency=440:duration=2:sample_rate=44100" -ac 2 -c:a pcm_s16le sine.wav
ffmpeg -y -loglevel error -i sine.wav -c:a libmp3lame -b:a 192k sine.mp3
ffmpeg -y -loglevel error -i sine.wav -c:a flac  sine.flac
ffmpeg -y -loglevel error -i sine.wav -c:a libopus sine.opus
ffmpeg -y -loglevel error -i sine.wav -ac 2 -c:a vorbis -strict -2 sine.ogg
afconvert -f m4af -d aac sine.wav sine.m4a

# 24-bit source, for the bit-depth regression test.
ffmpeg -y -loglevel error -f lavfi \
  -i "sine=frequency=440:duration=2:sample_rate=44100" -ac 2 -c:a pcm_s24le sine24.wav
ffmpeg -y -loglevel error -i sine24.wav -c:a flac -sample_fmt s32 sine24.flac

ls -la
```

Run: `chmod +x Tests/Fixtures/generate.sh && Tests/Fixtures/generate.sh`
Expected: eight files created. `sine.opus` will report a 48000 Hz sample rate — Opus always resamples, and the test accounts for it.

- [ ] **Step 2: Write the failing tests**

`Tests/AudioDecodeTests/DecodeTests.swift`:

```swift
import Testing
import Foundation
@testable import AudioDecode

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // AudioDecodeTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

@Test func decodesWavToFloat32() async throws {
    let audio = try await AudioFileDecoder.decode(url: fixture("sine.wav"))
    #expect(audio.channels == 2)
    #expect(audio.sampleRate == 44100)
    // ~2 seconds, allowing codec priming slop
    #expect(abs(audio.frameCount - 88200) < 2000)
}

@Test(arguments: [
    ("sine.mp3", 44100.0), ("sine.flac", 44100.0), ("sine.m4a", 44100.0),
    ("sine.ogg", 44100.0), ("sine.opus", 48000.0),
])
func decodesEveryNativeFormat(name: String, expectedRate: Double) async throws {
    let audio = try await AudioFileDecoder.decode(url: fixture(name))
    #expect(audio.channels == 2)
    #expect(audio.sampleRate == expectedRate)
    #expect(audio.frameCount > Int64(expectedRate) )   // more than 1 second

    // A 440 Hz sine must have real signal in it.
    let ch = audio.channel(0)
    var peak: Float = 0
    for i in 0..<Int(audio.frameCount) { peak = max(peak, abs(ch[i])) }
    #expect(peak > 0.3)
    #expect(peak <= 1.01)
}

@Test func preserves24BitResolution() async throws {
    let audio = try await AudioFileDecoder.decode(url: fixture("sine24.flac"))
    let ch = audio.channel(0)
    // If the decoder silently produced Int16, every sample would be an exact
    // multiple of 1/32768. Assert that some sample is not.
    let step: Float = 1.0 / 32768.0
    var foundSubQuantumValue = false
    for i in 0..<Int(audio.frameCount) {
        let quotient = ch[i] / step
        if abs(quotient - quotient.rounded()) > 0.01 { foundSubQuantumValue = true; break }
    }
    #expect(foundSubQuantumValue, "decoder appears to have quantised a 24-bit source to 16 bits")
}

@Test func missingFileThrowsUnreadable() async {
    await #expect(throws: DecodeError.self) {
        _ = try await AudioFileDecoder.decode(url: URL(fileURLWithPath: "/nope/missing.wav"))
    }
}

/// A `@Sendable` progress closure cannot capture a local `var`, so collect through
/// a locked reference type.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

@Test func reportsMonotonicProgress() async throws {
    let log = ProgressLog()
    _ = try await AudioFileDecoder.decode(url: fixture("sine.flac")) { log.record($0) }
    let samples = log.snapshot
    #expect(!samples.isEmpty)
    #expect(samples == samples.sorted())
    #expect(samples.last! >= 0.99)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter AudioDecodeTests`
Expected: FAIL — `no such module 'AudioDecode'`.

- [ ] **Step 4: Implement AudioStorage and DecodedAudio**

`Sources/AudioDecode/AudioStorage.swift`:

```swift
import Foundation

/// Owns one planar Float32 allocation per channel for the lifetime of a loaded file.
///
/// Deliberately a class with manual memory: the render thread reads these pointers
/// directly and must not trigger ARC or bounds-checking machinery.
public final class AudioStorage: @unchecked Sendable {
    public let channels: Int
    public let capacityFrames: Int
    private let buffers: [UnsafeMutablePointer<Float>]

    public init(channels: Int, capacityFrames: Int) {
        precondition(channels > 0 && capacityFrames > 0)
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.buffers = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
            p.initialize(repeating: 0, count: capacityFrames)
            return p
        }
    }

    deinit {
        for b in buffers {
            b.deinitialize(count: capacityFrames)
            b.deallocate()
        }
    }

    public func pointer(_ channel: Int) -> UnsafeMutablePointer<Float> {
        buffers[channel]
    }

    /// Immutable view for the render thread.
    public var channelPointers: [UnsafePointer<Float>] {
        buffers.map { UnsafePointer($0) }
    }
}
```

`Sources/AudioDecode/DecodedAudio.swift`:

```swift
import ArtscribeKit

/// A fully decoded file. Immutable once built; both the UI and the render thread read it.
public struct DecodedAudio: @unchecked Sendable {
    public let channels: Int
    public let sampleRate: Double
    public let frameCount: FrameIndex
    public let storage: AudioStorage

    public init(channels: Int, sampleRate: Double, frameCount: FrameIndex, storage: AudioStorage) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.storage = storage
    }

    public func channel(_ index: Int) -> UnsafePointer<Float> {
        UnsafePointer(storage.pointer(index))
    }

    public var duration: Double { Double(frameCount) / sampleRate }
}
```

- [ ] **Step 5: Implement DecodeError**

`Sources/AudioDecode/DecodeError.swift`:

```swift
import Foundation

public enum DecodeError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case noAudioTrack
    case unsupportedFormat(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "This file could not be read. \(detail)"
        case .noAudioTrack:
            return "This file contains no audio track."
        case .unsupportedFormat(let detail):
            return "macOS cannot decode this file's audio format. \(detail)"
        case .cancelled:
            return "Loading was cancelled."
        }
    }
}
```

- [ ] **Step 6: Implement AudioFileDecoder**

`Sources/AudioDecode/AudioFileDecoder.swift`:

```swift
import Foundation
import AVFoundation
import CoreMedia
import Accelerate
import ArtscribeKit

public enum AudioFileDecoder {

    /// Decodes an entire file to planar Float32.
    ///
    /// Requests **interleaved** Float32 from AVAssetReader (universally supported)
    /// and de-interleaves with a strided copy. Requesting non-interleaved output
    /// directly is not reliable across all codecs.
    public static func decode(
        url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DecodedAudio {

        let asset = AVURLAsset(url: url)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }
        guard let track = tracks.first else { throw DecodeError.noAudioTrack }

        let duration: CMTime
        let formatDescriptions: [CMFormatDescription]
        do {
            duration = try await asset.load(.duration)
            formatDescriptions = try await track.load(.formatDescriptions)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }

        guard let asbd = formatDescriptions.first.flatMap({
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }) else {
            throw DecodeError.unsupportedFormat("No stream description available.")
        }

        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        guard sampleRate > 0, channels > 0 else {
            throw DecodeError.unsupportedFormat("Reported \(channels) channels at \(sampleRate) Hz.")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw DecodeError.unreadable(error.localizedDescription) }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw DecodeError.unsupportedFormat("Reader rejected Float32 output.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw DecodeError.unreadable(reader.error?.localizedDescription ?? "Reader failed to start.")
        }

        let estimatedFrames = Int(duration.seconds * sampleRate) + Int(sampleRate)
        let storage = AudioStorage(channels: channels, capacityFrames: max(estimatedFrames, 1))
        var written = 0

        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }

            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
                let base = dataPointer else { continue }

            let floats = UnsafeRawPointer(base).assumingMemoryBound(to: Float.self)
            let frames = totalLength / (MemoryLayout<Float>.size * channels)
            guard frames > 0, written + frames <= storage.capacityFrames else {
                if written + frames > storage.capacityFrames { break }
                continue
            }

            // De-interleave: stride-copy channel c out of the packed frame stream.
            for c in 0..<channels {
                cblas_scopy(Int32(frames),
                            floats + c, Int32(channels),
                            storage.pointer(c) + written, 1)
            }
            written += frames

            if let progress, estimatedFrames > 0 {
                progress(min(1.0, Double(written) / Double(estimatedFrames)))
            }
            if Task.isCancelled { reader.cancelReading(); throw DecodeError.cancelled }
        }

        if reader.status == .failed {
            throw DecodeError.unreadable(reader.error?.localizedDescription ?? "Decode failed.")
        }
        guard written > 0 else { throw DecodeError.unsupportedFormat("Decoded zero frames.") }

        progress?(1.0)
        return DecodedAudio(channels: channels, sampleRate: sampleRate,
                            frameCount: FrameIndex(written), storage: storage)
    }
}
```

- [ ] **Step 7: Register the targets**

In `Package.swift`, add to `targets`:

```swift
        .target(name: "AudioDecode", dependencies: ["ArtscribeKit"]),
        .testTarget(name: "AudioDecodeTests", dependencies: ["AudioDecode"]),
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter AudioDecodeTests`
Expected: PASS, 10 tests (the parameterised format test counts as 5).

If `preserves24BitResolution` fails, the output settings are being ignored — confirm `AVLinearPCMIsFloatKey: true` and `AVLinearPCMBitDepthKey: 32` are both present.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/AudioDecode Tests/AudioDecodeTests Tests/Fixtures
git commit -m "feat: Float32 audio decoding with 24-bit resolution preserved"
```

---

### Task 5: Waveform peak pyramid

**Files:**
- Create: `Sources/Waveform/PeakPyramid.swift`
- Test: `Tests/WaveformTests/PeakPyramidTests.swift`

**Interfaces:**
- Consumes: `DecodedAudio` (Task 4), `FrameRange` (Task 2)
- Produces: `PeakPyramid.build(_:)`; `PeakPyramid.Level` with `.bucketFrames`, `.mins`, `.maxs`, `.bucketCount`; `PeakPyramid.level(forFramesPerPixel:)`; `PeakPyramid.peaks(channel:range:buckets:)` returning `[Peak]` where `Peak` has `.min`/`.max`

- [ ] **Step 1: Write the failing tests**

`Tests/WaveformTests/PeakPyramidTests.swift`:

```swift
import Testing
import ArtscribeKit
import AudioDecode
@testable import Waveform

/// Builds a DecodedAudio whose channel 0 is a known ramp and channel 1 its negation.
private func makeRamp(frames: Int) -> DecodedAudio {
    let storage = AudioStorage(channels: 2, capacityFrames: frames)
    for i in 0..<frames {
        let v = Float(i) / Float(frames)      // 0 ..< 1
        storage.pointer(0)[i] = v
        storage.pointer(1)[i] = -v
    }
    return DecodedAudio(channels: 2, sampleRate: 44100,
                        frameCount: FrameIndex(frames), storage: storage)
}

@Test func baseLevelMatchesNaiveReference() {
    let frames = 4096
    let audio = makeRamp(frames: frames)
    let pyramid = PeakPyramid.build(audio)
    let base = pyramid.levels[0]
    #expect(base.bucketFrames == 256)
    #expect(base.bucketCount == frames / 256)

    // Naive reference for bucket 3 of channel 0.
    let b = 3
    var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
    for i in (b * 256)..<((b + 1) * 256) {
        lo = min(lo, audio.channel(0)[i]); hi = max(hi, audio.channel(0)[i])
    }
    #expect(abs(base.mins[0][b] - lo) < 1e-6)
    #expect(abs(base.maxs[0][b] - hi) < 1e-6)
}

@Test func higherLevelsAreConsistentWithBase() {
    let audio = makeRamp(frames: 65_536)
    let pyramid = PeakPyramid.build(audio)
    #expect(pyramid.levels.count >= 2)
    let base = pyramid.levels[0], next = pyramid.levels[1]
    #expect(next.bucketFrames == base.bucketFrames * 4)
    // Bucket 0 of `next` must span buckets 0..<4 of `base`.
    let expectedMax = (0..<4).map { base.maxs[0][$0] }.max()!
    #expect(abs(next.maxs[0][0] - expectedMax) < 1e-6)
}

@Test func levelSelectionPicksCoarsestThatStillResolves() {
    let audio = makeRamp(frames: 1_048_576)
    let pyramid = PeakPyramid.build(audio)
    // At 300 frames/pixel the 256-frame level resolves; 1024 would be too coarse.
    #expect(pyramid.level(forFramesPerPixel: 300).bucketFrames == 256)
    #expect(pyramid.level(forFramesPerPixel: 5000).bucketFrames == 4096)
    // Zoomed right in, fall back to the finest level available.
    #expect(pyramid.level(forFramesPerPixel: 1).bucketFrames == 256)
}

@Test func peaksSpanRequestedRange() {
    let audio = makeRamp(frames: 65_536)
    let pyramid = PeakPyramid.build(audio)
    let peaks = pyramid.peaks(channel: 0,
                              range: FrameRange(start: 0, count: 65_536),
                              buckets: 100)
    #expect(peaks.count == 100)
    // Ramp rises monotonically, so the last bucket must peak higher than the first.
    #expect(peaks[99].max > peaks[0].max)
    #expect(peaks[0].min >= 0)
}

@Test func negatedChannelHasNegativeMinima() {
    let audio = makeRamp(frames: 8192)
    let pyramid = PeakPyramid.build(audio)
    let peaks = pyramid.peaks(channel: 1,
                              range: FrameRange(start: 0, count: 8192),
                              buckets: 10)
    #expect(peaks.allSatisfy { $0.max <= 0.0001 })
    #expect(peaks.last!.min < -0.5)
}

@Test func emptyRangeYieldsSilentBuckets() {
    let audio = makeRamp(frames: 8192)
    let pyramid = PeakPyramid.build(audio)
    let peaks = pyramid.peaks(channel: 0, range: FrameRange(start: 0, count: 0), buckets: 5)
    #expect(peaks.count == 5)
    #expect(peaks.allSatisfy { $0.min == 0 && $0.max == 0 })
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WaveformTests`
Expected: FAIL — `no such module 'Waveform'`.

- [ ] **Step 3: Implement PeakPyramid**

`Sources/Waveform/PeakPyramid.swift`:

```swift
import Accelerate
import ArtscribeKit
import AudioDecode

/// Multi-resolution min/max peaks so the waveform can be drawn at any zoom
/// without touching the sample buffer. ~600 KB for a 10-minute stereo track.
public struct PeakPyramid: Sendable {

    public struct Peak: Sendable, Equatable {
        public var min: Float
        public var max: Float
    }

    public struct Level: Sendable {
        public let bucketFrames: Int
        /// Indexed [channel][bucket].
        public let mins: [[Float]]
        public let maxs: [[Float]]
        public var bucketCount: Int { mins.first?.count ?? 0 }
    }

    public static let baseBucketFrames = 256
    private static let reductionFactor = 4

    public let channels: Int
    public let frameCount: FrameIndex
    public let levels: [Level]

    public static func build(_ audio: DecodedAudio) -> PeakPyramid {
        let channels = audio.channels
        let total = Int(audio.frameCount)
        var levels: [Level] = []

        // Base level straight from the samples, using Accelerate.
        let baseBuckets = max(1, total / baseBucketFrames)
        var baseMins = [[Float]](repeating: [Float](repeating: 0, count: baseBuckets), count: channels)
        var baseMaxs = baseMins

        for c in 0..<channels {
            let src = audio.channel(c)
            for b in 0..<baseBuckets {
                let offset = b * baseBucketFrames
                let n = Swift.min(baseBucketFrames, total - offset)
                guard n > 0 else { continue }
                var lo: Float = 0, hi: Float = 0
                vDSP_minv(src + offset, 1, &lo, vDSP_Length(n))
                vDSP_maxv(src + offset, 1, &hi, vDSP_Length(n))
                baseMins[c][b] = lo
                baseMaxs[c][b] = hi
            }
        }
        levels.append(Level(bucketFrames: baseBucketFrames, mins: baseMins, maxs: baseMaxs))

        // Coarser levels reduce the previous level rather than rescanning samples.
        while levels[levels.count - 1].bucketCount > reductionFactor {
            let prev = levels[levels.count - 1]
            let count = prev.bucketCount / reductionFactor
            guard count > 0 else { break }
            var mins = [[Float]](repeating: [Float](repeating: 0, count: count), count: channels)
            var maxs = mins
            for c in 0..<channels {
                for b in 0..<count {
                    var lo = Float.greatestFiniteMagnitude
                    var hi = -Float.greatestFiniteMagnitude
                    for k in 0..<reductionFactor {
                        let i = b * reductionFactor + k
                        lo = Swift.min(lo, prev.mins[c][i])
                        hi = Swift.max(hi, prev.maxs[c][i])
                    }
                    mins[c][b] = lo
                    maxs[c][b] = hi
                }
            }
            levels.append(Level(bucketFrames: prev.bucketFrames * reductionFactor,
                                mins: mins, maxs: maxs))
        }

        return PeakPyramid(channels: channels, frameCount: audio.frameCount, levels: levels)
    }

    /// Coarsest level whose buckets are still no wider than one pixel.
    public func level(forFramesPerPixel fpp: Double) -> Level {
        var chosen = levels[0]
        for level in levels where Double(level.bucketFrames) <= fpp {
            chosen = level
        }
        return chosen
    }

    /// Aggregated peaks for a time range, resampled to exactly `buckets` entries.
    public func peaks(channel: Int, range: FrameRange, buckets: Int) -> [Peak] {
        guard buckets > 0, channel < channels else { return [] }
        var out = [Peak](repeating: Peak(min: 0, max: 0), count: buckets)
        let clamped = range.clamped(to: frameCount)
        guard !clamped.isEmpty else { return out }

        let fpp = Double(clamped.count) / Double(buckets)
        let level = level(forFramesPerPixel: fpp)
        let mins = level.mins[channel], maxs = level.maxs[channel]
        let bucketCount = level.bucketCount
        guard bucketCount > 0 else { return out }

        for i in 0..<buckets {
            let startFrame = Double(clamped.start) + Double(i) * fpp
            let endFrame = startFrame + fpp
            let lo = Swift.max(0, Int(startFrame) / level.bucketFrames)
            let hi = Swift.min(bucketCount - 1, Int(endFrame) / level.bucketFrames)
            guard lo <= hi else { continue }
            var mn = Float.greatestFiniteMagnitude
            var mx = -Float.greatestFiniteMagnitude
            for b in lo...hi {
                mn = Swift.min(mn, mins[b])
                mx = Swift.max(mx, maxs[b])
            }
            out[i] = Peak(min: mn, max: mx)
        }
        return out
    }
}
```

- [ ] **Step 4: Register the targets**

In `Package.swift`, add to `targets`:

```swift
        .target(name: "Waveform", dependencies: ["ArtscribeKit", "AudioDecode"]),
        .testTarget(name: "WaveformTests", dependencies: ["Waveform"]),
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter WaveformTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/Waveform Tests/WaveformTests
git commit -m "feat: multi-resolution waveform peak pyramid"
```

---

### Task 6: TimeStretcher protocol and Rubber Band implementation

**Files:**
- Create: `Sources/TimeStretch/TimeStretcher.swift`
- Create: `Sources/TimeStretch/RubberBandStretcher.swift`
- Create: `Sources/TimeStretch/IdentityStretcher.swift`
- Test: `Tests/TimeStretchTests/StretchQualityTests.swift`

`IdentityStretcher` is not test-only scaffolding to be deleted — Task 8 depends on it to make `PlaybackEngine` deterministically testable.

**Interfaces:**
- Consumes: `StretchEngine` (Task 3)
- Produces: `TimeStretcher` protocol (`configure`, `timeRatio`, `startDelay`, `samplesRequired()`, `process(_:frames:final:)`, `available()`, `retrieve(_:frames:)`, `reset()`); `RubberBandStretcher(engine:)`; `IdentityStretcher()`

- [ ] **Step 1: Write the failing tests**

`Tests/TimeStretchTests/StretchQualityTests.swift`:

```swift
import Testing
import Foundation      // sin, log2
import ArtscribeKit
@testable import TimeStretch

/// Estimates frequency by counting zero crossings with hysteresis.
/// Over several seconds this resolves well inside 2 cents for a pure tone.
private func estimateFrequency(_ samples: [Float], sampleRate: Double) -> Double {
    var crossings = 0
    var armed = false
    var firstCrossing = -1
    var lastCrossing = -1
    let threshold: Float = 0.1
    for (i, s) in samples.enumerated() {
        if !armed && s > threshold { armed = true }
        else if armed && s < -threshold {
            armed = false
            crossings += 1
            if firstCrossing < 0 { firstCrossing = i }
            lastCrossing = i
        }
    }
    guard crossings > 1, lastCrossing > firstCrossing else { return 0 }
    let span = Double(lastCrossing - firstCrossing) / sampleRate
    return Double(crossings - 1) / span
}

private func sine(freq: Double, seconds: Double, sampleRate: Double) -> [Float] {
    let n = Int(seconds * sampleRate)
    return (0..<n).map { Float(sin(2 * Double.pi * freq * Double($0) / sampleRate)) }
}

/// Pushes mono input through a stretcher and collects all output.
private func runStretcher(_ s: TimeStretcher, input: [Float],
                          sampleRate: Double, block: Int = 1024) -> [Float] {
    s.configure(sampleRate: sampleRate, channels: 1, maxBlock: block)
    var out: [Float] = []
    var scratch = [Float](repeating: 0, count: block * 8)
    var offset = 0

    func drain() {
        while s.available() > 0 {
            let want = Swift.min(s.available(), scratch.count)
            let got = scratch.withUnsafeMutableBufferPointer { buf -> Int in
                var ptr: UnsafeMutablePointer<Float>? = buf.baseAddress
                return withUnsafeMutablePointer(to: &ptr) { s.retrieve($0, frames: want) }
            }
            guard got > 0 else { break }
            out.append(contentsOf: scratch[0..<got])
        }
    }

    while offset < input.count {
        let n = Swift.min(block, input.count - offset)
        input.withUnsafeBufferPointer { buf in
            var ptr: UnsafePointer<Float>? = buf.baseAddress! + offset
            withUnsafePointer(to: &ptr) { s.process($0, frames: n, final: offset + n >= input.count) }
        }
        offset += n
        drain()
    }
    drain()
    return out
}

@Test func identityStretcherPassesSamplesThroughUnchanged() {
    let input = sine(freq: 440, seconds: 0.5, sampleRate: 44100)
    let out = runStretcher(IdentityStretcher(), input: input, sampleRate: 44100)
    #expect(out.count == input.count)
    for i in stride(from: 0, to: input.count, by: 97) {
        #expect(abs(out[i] - input[i]) < 1e-6)
    }
}

@Test func identityStretcherHasNoStartDelay() {
    let s = IdentityStretcher()
    s.configure(sampleRate: 44100, channels: 1, maxBlock: 512)
    #expect(s.startDelay == 0)
}

@Test(arguments: [StretchEngine.studio, StretchEngine.fast])
func halfSpeedPreservesPitch(engine: StretchEngine) {
    let rate = 44100.0
    let input = sine(freq: 440, seconds: 6, sampleRate: rate)
    let s = RubberBandStretcher(engine: engine)
    s.timeRatio = 2.0                       // half speed => twice as long
    var out = runStretcher(s, input: input, sampleRate: rate)

    // Discard the engine's start delay plus a safety margin before measuring.
    let skip = Swift.min(out.count, s.startDelay + 8192)
    out.removeFirst(skip)
    #expect(out.count > Int(rate * 4))

    let measured = estimateFrequency(out, sampleRate: rate)
    let cents = 1200 * log2(measured / 440.0)
    #expect(abs(cents) < 2.0, "pitch drifted \(cents) cents (measured \(measured) Hz)")
}

@Test func halfSpeedRoughlyDoublesLength() {
    let rate = 44100.0
    let input = sine(freq: 440, seconds: 4, sampleRate: rate)
    let s = RubberBandStretcher(engine: .studio)
    s.timeRatio = 2.0
    let out = runStretcher(s, input: input, sampleRate: rate)
    let ratio = Double(out.count) / Double(input.count)
    #expect(abs(ratio - 2.0) < 0.05, "expected ~2x length, got \(ratio)x")
}

@Test func doubleSpeedRoughlyHalvesLength() {
    let rate = 44100.0
    let input = sine(freq: 440, seconds: 4, sampleRate: rate)
    let s = RubberBandStretcher(engine: .studio)
    s.timeRatio = 0.5
    let out = runStretcher(s, input: input, sampleRate: rate)
    let ratio = Double(out.count) / Double(input.count)
    #expect(abs(ratio - 0.5) < 0.05, "expected ~0.5x length, got \(ratio)x")
}

@Test func outputContainsNoNaNOrInfinity() {
    let input = sine(freq: 440, seconds: 2, sampleRate: 44100)
    let s = RubberBandStretcher(engine: .studio)
    s.timeRatio = 3.0
    let out = runStretcher(s, input: input, sampleRate: 44100)
    #expect(out.allSatisfy { $0.isFinite })
}

@Test func studioEngineReportsNonZeroStartDelay() {
    let s = RubberBandStretcher(engine: .studio)
    s.configure(sampleRate: 44100, channels: 2, maxBlock: 1024)
    #expect(s.startDelay > 0)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TimeStretchTests`
Expected: FAIL — `no such module 'TimeStretch'`.

- [ ] **Step 3: Define the protocol**

`Sources/TimeStretch/TimeStretcher.swift`:

```swift
/// Pull-based time stretching. Implementations must be allocation-free once
/// `configure` has returned, because `process`/`retrieve` run on the render thread.
public protocol TimeStretcher: AnyObject {
    /// Must be called before any processing. May allocate.
    func configure(sampleRate: Double, channels: Int, maxBlock: Int)

    /// Rubber Band's time ratio: 2.0 means output is twice as long (half speed).
    /// Safe to set from the render thread.
    var timeRatio: Double { get set }

    /// Output frames of priming to discard after `configure`/`reset`.
    var startDelay: Int { get }

    /// Input frames the stretcher would like next.
    func samplesRequired() -> Int

    /// Output frames ready to be retrieved.
    func available() -> Int

    func process(_ input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool)
    func retrieve(_ output: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int) -> Int
    func reset()
}
```

- [ ] **Step 4: Implement IdentityStretcher**

`Sources/TimeStretch/IdentityStretcher.swift`:

```swift
/// A 1:1 passthrough with zero latency, ignoring `timeRatio`.
///
/// Exists so `PlaybackEngine` can be tested for exact sample positions and loop
/// wrapping without a real stretcher's latency and priming in the way.
public final class IdentityStretcher: TimeStretcher {
    private var channels = 0
    private var capacity = 0
    private var buffers: [[Float]] = []
    private var count = 0

    public init() {}

    public var timeRatio: Double = 1.0
    public var startDelay: Int { 0 }

    public func configure(sampleRate: Double, channels: Int, maxBlock: Int) {
        self.channels = channels
        self.capacity = maxBlock * 8
        self.buffers = Array(repeating: [Float](repeating: 0, count: capacity), count: channels)
        self.count = 0
    }

    public func samplesRequired() -> Int { Swift.max(0, capacity / 8) }
    public func available() -> Int { count }

    public func process(_ input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool) {
        let n = Swift.min(frames, capacity - count)
        guard n > 0 else { return }
        for c in 0..<channels {
            guard let src = input[c] else { continue }
            for i in 0..<n { buffers[c][count + i] = src[i] }
        }
        count += n
    }

    public func retrieve(_ output: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int) -> Int {
        let n = Swift.min(frames, count)
        guard n > 0 else { return 0 }
        for c in 0..<channels {
            guard let dst = output[c] else { continue }
            for i in 0..<n { dst[i] = buffers[c][i] }
            if count > n {
                for i in 0..<(count - n) { buffers[c][i] = buffers[c][n + i] }
            }
        }
        count -= n
        return n
    }

    public func reset() { count = 0 }
}
```

- [ ] **Step 5: Implement RubberBandStretcher**

`Sources/TimeStretch/RubberBandStretcher.swift`:

```swift
import ArtscribeKit
import CRubberBand

public final class RubberBandStretcher: TimeStretcher {
    private var state: RubberBandState?
    private let engine: StretchEngine
    private var pendingRatio: Double = 1.0

    public init(engine: StretchEngine) {
        self.engine = engine
    }

    deinit {
        if let state { rubberband_delete(state) }
    }

    public func configure(sampleRate: Double, channels: Int, maxBlock: Int) {
        if let state { rubberband_delete(state) }
        let engineFlag = engine == .studio
            ? RubberBandOptionEngineFiner.rawValue
            : RubberBandOptionEngineFaster.rawValue
        let opts = RubberBandOptions(RubberBandOptionProcessRealTime.rawValue | engineFlag)
        state = rubberband_new(UInt32(sampleRate), UInt32(channels), opts, pendingRatio, 1.0)
        if let state {
            // Pre-size so process()/retrieve() never allocate on the render thread.
            rubberband_set_max_process_size(state, UInt32(maxBlock))
        }
    }

    public var timeRatio: Double {
        get { state.map { rubberband_get_time_ratio($0) } ?? pendingRatio }
        set {
            pendingRatio = newValue
            if let state { rubberband_set_time_ratio(state, newValue) }
        }
    }

    /// Output frames of priming to discard after configure/reset. 2048 for R3.
    public var startDelay: Int {
        guard let state else { return 0 }
        return Int(rubberband_get_start_delay(state))
    }

    public func samplesRequired() -> Int {
        guard let state else { return 0 }
        return Int(rubberband_get_samples_required(state))
    }

    public func available() -> Int {
        guard let state else { return 0 }
        return Int(max(0, rubberband_available(state)))
    }

    public func process(_ input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool) {
        guard let state else { return }
        input.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: 1) { ptr in
            rubberband_process(state, ptr, UInt32(frames), final ? 1 : 0)
        }
    }

    public func retrieve(_ output: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int) -> Int {
        guard let state else { return 0 }
        return output.withMemoryRebound(to: UnsafeMutablePointer<Float>?.self, capacity: 1) { ptr in
            Int(rubberband_retrieve(state, ptr, UInt32(frames)))
        }
    }

    public func reset() {
        guard let state else { return }
        rubberband_reset(state)
    }
}
```

- [ ] **Step 6: Register the targets**

In `Package.swift`, add to `targets`:

```swift
        .target(name: "TimeStretch", dependencies: ["ArtscribeKit", "CRubberBand"]),
        .testTarget(name: "TimeStretchTests", dependencies: ["TimeStretch"]),
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter TimeStretchTests`
Expected: PASS, 8 tests (the parameterised pitch test counts as 2).

If `halfSpeedPreservesPitch` fails by roughly ±1200 cents, `timeRatio` and speed ratio have been swapped somewhere — see Global Constraints.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/TimeStretch Tests/TimeStretchTests
git commit -m "feat: TimeStretcher protocol with Rubber Band and identity implementations"
```

---

### Task 7: Lock-free command ring

**Files:**
- Create: `Sources/Playback/PlaybackCommand.swift`
- Create: `Sources/Playback/CommandRing.swift`
- Test: `Tests/PlaybackTests/CommandRingTests.swift`

**Interfaces:**
- Consumes: `FrameIndex`, `FrameRange` (Tasks 1–2)
- Produces: `PlaybackCommand` enum (`.seek`, `.setTimeRatio`, `.setLoop`, `.setPlaying`); `CommandRing(capacity:)` with `push(_:) -> Bool` and `pop() -> PlaybackCommand?`

- [ ] **Step 1: Write the failing tests**

`Tests/PlaybackTests/CommandRingTests.swift`:

```swift
import Testing
import ArtscribeKit
@testable import Playback

@Test func popOnEmptyRingReturnsNil() {
    let ring = CommandRing(capacity: 8)
    #expect(ring.pop() == nil)
}

@Test func preservesFIFOOrder() {
    let ring = CommandRing(capacity: 8)
    #expect(ring.push(.seek(100)))
    #expect(ring.push(.setTimeRatio(2.0)))
    #expect(ring.push(.setPlaying(true)))

    #expect(ring.pop() == .seek(100))
    #expect(ring.pop() == .setTimeRatio(2.0))
    #expect(ring.pop() == .setPlaying(true))
    #expect(ring.pop() == nil)
}

@Test func rejectsPushWhenFull() {
    let ring = CommandRing(capacity: 4)     // usable slots = capacity - 1
    #expect(ring.push(.seek(1)))
    #expect(ring.push(.seek(2)))
    #expect(ring.push(.seek(3)))
    #expect(!ring.push(.seek(4)))           // full
}

@Test func wrapsAroundCorrectly() {
    let ring = CommandRing(capacity: 4)
    for round in 0..<20 {
        #expect(ring.push(.seek(FrameIndex(round))))
        #expect(ring.pop() == .seek(FrameIndex(round)))
    }
    #expect(ring.pop() == nil)
}

@Test func carriesLoopPayload() {
    let ring = CommandRing(capacity: 4)
    let range = FrameRange(start: 500, count: 1000)
    #expect(ring.push(.setLoop(range, true)))
    #expect(ring.pop() == .setLoop(range, true))
}

@Test func survivesConcurrentProducerAndConsumer() async {
    let ring = CommandRing(capacity: 1024)
    let total = 50_000

    async let producer: Void = {
        var sent = 0
        while sent < total {
            if ring.push(.seek(FrameIndex(sent))) { sent += 1 }
        }
    }()

    async let consumed: Int = {
        var received = 0
        var expected: FrameIndex = 0
        while received < total {
            if case .seek(let v)? = ring.pop() {
                // FIFO must hold exactly, with no drops or reordering.
                if v != expected { return -1 }
                expected += 1
                received += 1
            }
        }
        return received
    }()

    await producer
    let count = await consumed
    #expect(count == total)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PlaybackTests`
Expected: FAIL — `no such module 'Playback'`.

- [ ] **Step 3: Implement PlaybackCommand**

`Sources/Playback/PlaybackCommand.swift`:

```swift
import ArtscribeKit

/// Commands sent from the main actor to the render thread.
///
/// Every payload is trivial (Int64/Double/Bool) so values can live in raw memory
/// with no ARC traffic on the render thread.
public enum PlaybackCommand: Equatable, Sendable {
    case seek(FrameIndex)
    case setTimeRatio(Double)
    case setLoop(FrameRange, Bool)
    case setPlaying(Bool)
}
```

- [ ] **Step 4: Implement CommandRing**

`Sources/Playback/CommandRing.swift`:

```swift
import Synchronization

/// Single-producer / single-consumer lock-free ring buffer.
///
/// `push` is called from the main actor; `pop` from the render thread. One slot is
/// always left empty so full and empty are distinguishable without a count.
public final class CommandRing: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<PlaybackCommand>
    private let head = Atomic<Int>(0)   // next slot to read  (consumer)
    private let tail = Atomic<Int>(0)   // next slot to write (producer)

    public init(capacity: Int = 256) {
        precondition(capacity >= 2)
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    /// Producer side. Returns false if the ring is full rather than blocking.
    @discardableResult
    public func push(_ command: PlaybackCommand) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let next = (t + 1) % capacity
        if next == head.load(ordering: .acquiring) { return false }
        buffer.advanced(by: t).initialize(to: command)
        tail.store(next, ordering: .releasing)
        return true
    }

    /// Consumer side. Allocation-free and wait-free; safe on the render thread.
    public func pop() -> PlaybackCommand? {
        let h = head.load(ordering: .relaxed)
        if h == tail.load(ordering: .acquiring) { return nil }
        let value = buffer.advanced(by: h).move()
        head.store((h + 1) % capacity, ordering: .releasing)
        return value
    }
}
```

- [ ] **Step 5: Register the targets**

In `Package.swift`, add to `targets`:

```swift
        .target(name: "Playback", dependencies: ["ArtscribeKit", "AudioDecode", "TimeStretch"]),
        .testTarget(name: "PlaybackTests", dependencies: ["Playback"]),
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter PlaybackTests`
Expected: PASS, 6 tests.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/Playback Tests/PlaybackTests
git commit -m "feat: lock-free SPSC command ring for the render-thread boundary"
```

---

### Task 8: PlaybackEngine with seamless looping

> **Do not build for stems — just do not preclude them.** Stem separation is a planned
> post-MVP feature (spec §11.3): split the track into drums/bass/vocals/other, stretch each
> independently, remix. Building any of that now would be YAGNI and is explicitly out of
> scope. The single thing this task must get right is to read source audio through **one**
> accessor rather than scattering `audio.channel(c)` through the render path, so that
> swapping one buffer for N is a contained change rather than a rewrite. Nothing more: no
> mixer, no stem types, no abstraction with a single implementation.

The core of the plan. Tested entirely with `IdentityStretcher`, so loop-wrap positions are exactly assertable.

**Files:**
- Create: `Sources/Playback/PlaybackEngine.swift`
- Test: `Tests/PlaybackTests/PlaybackEngineTests.swift`

**Interfaces:**
- Consumes: `DecodedAudio` (Task 4), `TimeStretcher`/`IdentityStretcher` (Task 6), `CommandRing`/`PlaybackCommand` (Task 7)
- Produces: `PlaybackEngine(audio:stretcher:ring:maxBlock:)` with `.currentFrame`, `.isPlaying`, `.render(into:frames:) -> Int`

- [ ] **Step 1: Write the failing tests**

`Tests/PlaybackTests/PlaybackEngineTests.swift`:

```swift
import Testing
import Foundation      // sin
import ArtscribeKit
import AudioDecode
import TimeStretch
@testable import Playback

/// Channel 0 holds sample value == frame index, so any output sample reveals
/// exactly which source frame produced it.
private func makeRampAudio(frames: Int, channels: Int = 1) -> DecodedAudio {
    let storage = AudioStorage(channels: channels, capacityFrames: frames)
    for c in 0..<channels {
        for i in 0..<frames { storage.pointer(c)[i] = Float(i) }
    }
    return DecodedAudio(channels: channels, sampleRate: 44100,
                        frameCount: FrameIndex(frames), storage: storage)
}

/// Renders `frames` frames of channel 0 into a flat array.
private func render(_ engine: PlaybackEngine, frames: Int, channels: Int = 1) -> [Float] {
    var out = [Float](repeating: -1, count: frames)
    _ = out.withUnsafeMutableBufferPointer { buf -> Int in
        var ptr: UnsafeMutablePointer<Float>? = buf.baseAddress
        return withUnsafeMutablePointer(to: &ptr) { engine.render(into: $0, frames: frames) }
    }
    return out
}

private func makeEngine(frames: Int = 10_000) -> (PlaybackEngine, CommandRing) {
    let ring = CommandRing(capacity: 64)
    let engine = PlaybackEngine(audio: makeRampAudio(frames: frames),
                                stretcher: IdentityStretcher(),
                                ring: ring,
                                maxBlock: 512)
    ring.push(.setPlaying(true))
    return (engine, ring)
}

@Test func stoppedEngineRendersSilence() {
    let ring = CommandRing(capacity: 8)
    let engine = PlaybackEngine(audio: makeRampAudio(frames: 1000),
                                stretcher: IdentityStretcher(), ring: ring, maxBlock: 256)
    let out = render(engine, frames: 128)
    #expect(out.allSatisfy { $0 == 0 })
}

@Test func playsSourceFramesInOrderFromTheStart() {
    let (engine, _) = makeEngine()
    let out = render(engine, frames: 256)
    #expect(out[0] == 0)
    #expect(out[100] == 100)
    #expect(out[255] == 255)
}

@Test func seekJumpsToExactFrame() {
    let (engine, ring) = makeEngine()
    ring.push(.seek(5000))
    let out = render(engine, frames: 64)
    #expect(out[0] == 5000)
    #expect(out[63] == 5063)
}

@Test func loopWrapsAtExactSampleBoundary() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), true))
    ring.push(.seek(1000))
    let out = render(engine, frames: 250)

    // First pass through the loop.
    #expect(out[0] == 1000)
    #expect(out[99] == 1099)
    // Must wrap to loop start on the very next frame — no gap, no repeat.
    #expect(out[100] == 1000)
    #expect(out[199] == 1099)
    #expect(out[200] == 1000)
}

@Test func loopedPlaybackNeverLeavesTheLoopRegion() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 2000, count: 500), true))
    ring.push(.seek(2000))
    let out = render(engine, frames: 4000)
    #expect(out.allSatisfy { $0 >= 2000 && $0 < 2500 })
}

@Test func disablingLoopPlaysStraightThrough() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 1000, count: 100), false))
    ring.push(.seek(1050))
    let out = render(engine, frames: 200)
    #expect(out[0] == 1050)
    #expect(out[199] == 1249)      // sails past the disabled loop end
}

@Test func stopsAtEndOfFileWithoutOverrunning() {
    let (engine, ring) = makeEngine(frames: 1000)
    ring.push(.seek(900))
    let out = render(engine, frames: 400)
    #expect(out[0] == 900)
    #expect(out[99] == 999)
    // Past the end: silence, not garbage and not a crash.
    #expect(out[150] == 0)
    #expect(!engine.isPlaying)
}

@Test func currentFrameTracksPlaybackPosition() {
    let (engine, ring) = makeEngine()
    ring.push(.seek(3000))
    _ = render(engine, frames: 512)
    #expect(engine.currentFrame >= 3000)
    #expect(engine.currentFrame <= 3600)
}

@Test func speedChangeMidStreamIsAppliedWithoutDroppingFrames() {
    let (engine, ring) = makeEngine()
    let first = render(engine, frames: 128)
    ring.push(.setTimeRatio(2.0))
    let second = render(engine, frames: 128)
    #expect(first[0] == 0)
    // IdentityStretcher ignores ratio, so continuity is what is under test:
    // no gap and no repeat across the command boundary.
    #expect(second[0] == 128)
}

@Test func outputIsAlwaysFinite() {
    let (engine, ring) = makeEngine()
    ring.push(.setLoop(FrameRange(start: 0, count: 777), true))
    let out = render(engine, frames: 8192)
    #expect(out.allSatisfy { $0.isFinite })
}

@Test func rubberBandLoopProducesNoDiscontinuityAtTheSeam() {
    // A real stretcher over a smooth sine: the loop seam must not click.
    let frames = 44100
    let storage = AudioStorage(channels: 1, capacityFrames: frames)
    for i in 0..<frames {
        storage.pointer(0)[i] = Float(sin(2 * Double.pi * 220 * Double(i) / 44100)) * 0.5
    }
    let audio = DecodedAudio(channels: 1, sampleRate: 44100,
                             frameCount: FrameIndex(frames), storage: storage)
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(audio: audio, stretcher: RubberBandStretcher(engine: .studio),
                                ring: ring, maxBlock: 512)
    ring.push(.setLoop(FrameRange(start: 0, count: 22050), true))
    ring.push(.setPlaying(true))

    let out = render(engine, frames: 88200)
    #expect(out.allSatisfy { $0.isFinite })
    // No sample-to-sample jump larger than a fifth of full scale.
    var worst: Float = 0
    for i in 1..<out.count { worst = max(worst, abs(out[i] - out[i - 1])) }
    #expect(worst < 0.2, "loop seam discontinuity of \(worst)")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PlaybackEngineTests`
Expected: FAIL — `cannot find 'PlaybackEngine' in scope`.

- [ ] **Step 3: Implement PlaybackEngine**

`Sources/Playback/PlaybackEngine.swift`:

```swift
import Synchronization
import ArtscribeKit
import AudioDecode
import TimeStretch

/// Pulls source frames through a `TimeStretcher` and writes rendered output.
///
/// `render` runs on the CoreAudio render thread: no allocation, no locks, no ARC.
/// All mutable state is owned by the render thread; the main actor communicates
/// only through `CommandRing`, and reads position back through an atomic.
public final class PlaybackEngine: @unchecked Sendable {

    private let audio: DecodedAudio
    private let stretcher: TimeStretcher
    private let ring: CommandRing
    private let channels: Int
    private let maxBlock: Int

    // Render-thread-owned state.
    private var readCursor: FrameIndex = 0
    private var loop = LoopRegion()
    private var playing = false
    private var primingRemaining = 0

    // Preallocated scratch for feeding the stretcher.
    private var feedStorage: AudioStorage
    private var feedPointers: UnsafeMutablePointer<UnsafePointer<Float>?>
    private var outPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    private let positionFrame = Atomic<Int64>(0)
    private let playingFlag = Atomic<Bool>(false)

    public init(audio: DecodedAudio, stretcher: TimeStretcher,
                ring: CommandRing, maxBlock: Int = 1024) {
        self.audio = audio
        self.stretcher = stretcher
        self.ring = ring
        self.channels = audio.channels
        self.maxBlock = maxBlock
        self.feedStorage = AudioStorage(channels: audio.channels, capacityFrames: maxBlock)
        self.feedPointers = .allocate(capacity: audio.channels)
        self.outPointers = .allocate(capacity: audio.channels)
        stretcher.configure(sampleRate: audio.sampleRate, channels: audio.channels, maxBlock: maxBlock)
        primingRemaining = stretcher.startDelay
    }

    deinit {
        feedPointers.deallocate()
        outPointers.deallocate()
    }

    /// Audible source position, safe to read from any thread.
    public var currentFrame: FrameIndex { positionFrame.load(ordering: .relaxed) }
    public var isPlaying: Bool { playingFlag.load(ordering: .relaxed) }

    /// Render thread entry point. Returns frames written; always fills `frames`
    /// (with silence where there is nothing to play).
    public func render(into output: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                       frames: Int) -> Int {
        drainCommands()

        // Silence first, so every early return leaves a defined buffer.
        for c in 0..<channels {
            if let dst = output[c] { dst.update(repeating: 0, count: frames) }
        }
        guard playing else { return frames }

        var written = 0
        var guardCounter = 0
        let guardLimit = frames * 8 + 64      // backstop against a stalled stretcher

        while written < frames {
            guardCounter += 1
            if guardCounter > guardLimit { break }

            // 1. Drain whatever the stretcher already has.
            let ready = stretcher.available()
            if ready > 0 {
                if primingRemaining > 0 {
                    discardPriming(min(ready, primingRemaining))
                    continue
                }
                let want = min(ready, frames - written)
                for c in 0..<channels {
                    outPointers[c] = output[c].map { $0 + written }
                }
                let got = stretcher.retrieve(outPointers, frames: want)
                if got <= 0 { break }
                written += got
                continue
            }

            // 2. Otherwise feed it more source.
            if !feedSource() {
                playing = false
                playingFlag.store(false, ordering: .relaxed)
                break
            }
        }

        positionFrame.store(readCursor, ordering: .relaxed)
        return frames
    }

    // MARK: - Private

    private func drainCommands() {
        while let command = ring.pop() {
            switch command {
            case .seek(let frame):
                readCursor = max(0, min(frame, audio.frameCount))
                stretcher.reset()
                primingRemaining = stretcher.startDelay
            case .setTimeRatio(let ratio):
                stretcher.timeRatio = ratio
            case .setLoop(let range, let enabled):
                loop = LoopRegion(range: range.clamped(to: audio.frameCount), isEnabled: enabled)
            case .setPlaying(let value):
                playing = value
                playingFlag.store(value, ordering: .relaxed)
            }
        }
    }

    /// Pushes one block of source into the stretcher, wrapping across the loop
    /// boundary **without** resetting — resetting would flush the overlap state
    /// and click on every repetition (spec §5.1).
    /// Returns false when there is nothing left to play.
    private func feedSource() -> Bool {
        let required = max(1, min(stretcher.samplesRequired(), maxBlock))

        // Where does the current segment end?
        let segmentEnd = loop.isActive ? loop.range.end : audio.frameCount
        if readCursor >= segmentEnd {
            if loop.isActive {
                readCursor = loop.range.start
            } else {
                return false
            }
        }

        var produced = 0
        while produced < required {
            let end = loop.isActive ? loop.range.end : audio.frameCount
            let available = end - readCursor
            if available <= 0 {
                if loop.isActive { readCursor = loop.range.start; continue }
                break
            }
            let n = Int(min(FrameIndex(required - produced), available))
            for c in 0..<channels {
                let src = audio.channel(c) + Int(readCursor)
                (feedStorage.pointer(c) + produced).update(from: src, count: n)
            }
            readCursor += FrameIndex(n)
            produced += n
        }

        guard produced > 0 else { return false }
        for c in 0..<channels {
            feedPointers[c] = UnsafePointer(feedStorage.pointer(c))
        }
        stretcher.process(feedPointers, frames: produced, final: false)
        return true
    }

    /// Throws away the stretcher's start-delay priming so position stays accurate.
    private func discardPriming(_ count: Int) {
        for c in 0..<channels {
            outPointers[c] = feedStorage.pointer(c)
        }
        let got = stretcher.retrieve(outPointers, frames: min(count, maxBlock))
        primingRemaining -= max(got, 1)
        if primingRemaining < 0 { primingRemaining = 0 }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PlaybackEngineTests`
Expected: PASS, 11 tests.

If `loopWrapsAtExactSampleBoundary` shows a repeated or skipped frame at index 100, the wrap in `feedSource` is off by one — the loop end is exclusive.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, all targets.

- [ ] **Step 6: Commit**

```bash
git add Sources/Playback Tests/PlaybackTests
git commit -m "feat: PlaybackEngine with sample-accurate seamless looping"
```

---

### Task 9: Audio output and CLI

Attaches CoreAudio at the outermost edge and gives a way to actually listen to the result.

**Files:**
- Create: `Sources/Playback/AudioOutput.swift`
- Create: `Sources/ArtscribeCLI/main.swift`
- Modify: `Package.swift`
- Test: `Tests/PlaybackTests/AudioOutputTests.swift`

**Interfaces:**
- Consumes: `PlaybackEngine` (Task 8), `AudioFileDecoder` (Task 4), `SpeedState` (Task 3)
- Produces: `AudioOutput(engine:sampleRate:channels:)` with `.start()`, `.stop()`; executable `artscribe-cli`

- [ ] **Step 1: Write the failing test**

`Tests/PlaybackTests/AudioOutputTests.swift`:

```swift
import Testing
import ArtscribeKit
import AudioDecode
import TimeStretch
@testable import Playback

@Test func audioOutputBuildsWithoutStartingHardware() throws {
    let storage = AudioStorage(channels: 2, capacityFrames: 4410)
    let audio = DecodedAudio(channels: 2, sampleRate: 44100,
                             frameCount: 4410, storage: storage)
    let ring = CommandRing(capacity: 16)
    let engine = PlaybackEngine(audio: audio, stretcher: IdentityStretcher(),
                                ring: ring, maxBlock: 512)
    // Constructing the graph must not require a running output device.
    let output = try AudioOutput(engine: engine, sampleRate: 44100, channels: 2)
    #expect(output.isRunning == false)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AudioOutputTests`
Expected: FAIL — `cannot find 'AudioOutput' in scope`.

- [ ] **Step 3: Implement AudioOutput**

`Sources/Playback/AudioOutput.swift`:

```swift
import AVFAudio
import ArtscribeKit

/// The only place CoreAudio touches the engine. The render block does nothing
/// but forward to `PlaybackEngine.render`.
public final class AudioOutput: @unchecked Sendable {
    private let avEngine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    private let engine: PlaybackEngine
    /// Preallocated so the render block never allocates.
    private let scratchPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    public private(set) var isRunning = false

    public init(engine: PlaybackEngine, sampleRate: Double, channels: Int) throws {
        self.engine = engine

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels)) else {
            throw AudioOutputError.unsupportedFormat(sampleRate: sampleRate, channels: channels)
        }

        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
            .allocate(capacity: channels)
        pointers.initialize(repeating: nil, count: channels)
        self.scratchPointers = pointers

        // `unowned(unsafe)` so the render block performs no retain/release. The node
        // is owned by this object and cannot outlive it.
        sourceNode = AVAudioSourceNode(format: format) {
            [unowned(unsafe) engine] _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Swift.min(abl.count, channels)
            for i in 0..<n {
                pointers[i] = abl[i].mData?.assumingMemoryBound(to: Float.self)
            }
            _ = engine.render(into: pointers, frames: Int(frameCount))
            return noErr
        }

        avEngine.attach(sourceNode)
        avEngine.connect(sourceNode, to: avEngine.mainMixerNode, format: format)
        avEngine.prepare()
    }

    public func start() throws {
        guard !isRunning else { return }
        try avEngine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        avEngine.stop()
        isRunning = false
    }

    deinit {
        avEngine.stop()
        scratchPointers.deallocate()
    }
}

public enum AudioOutputError: Error, LocalizedError {
    case unsupportedFormat(sampleRate: Double, channels: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let rate, let channels):
            return "Cannot create an output format for \(channels) channels at \(rate) Hz."
        }
    }
}
```

> Note: the channel-pointer array is allocated once in `init` rather than per
> callback, and the engine is captured `unowned(unsafe)`. Both are deliberate — a
> Swift `Array` built inside the render block would allocate, and a strong capture
> would put ARC traffic on the render thread. Do not "clean these up".

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AudioOutputTests`
Expected: PASS.

- [ ] **Step 5: Implement the CLI**

`Sources/ArtscribeCLI/main.swift`:

```swift
import Foundation
import ArtscribeKit
import AudioDecode
import TimeStretch
import Playback

// artscribe-cli <file> [speed] [loopStartSeconds loopEndSeconds]
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("""
    usage: artscribe-cli <file> [speed] [loopStart loopEnd]
      speed      0.10 - 2.00   (default 1.0)
      loopStart  seconds
      loopEnd    seconds
    """)
    exit(1)
}

let url = URL(fileURLWithPath: args[1])
let speed = args.count > 2 ? Double(args[2]) ?? 1.0 : 1.0

var state = SpeedState()
state.setRatio(speed)

print("Decoding \(url.lastPathComponent)…")
let audio = try await AudioFileDecoder.decode(url: url) { p in
    if Int(p * 100) % 25 == 0 { print("  \(Int(p * 100))%") }
}
print(String(format: "  %.1f s, %d ch, %.0f Hz",
             audio.duration, audio.channels, audio.sampleRate))

let ring = CommandRing(capacity: 64)
let engine = PlaybackEngine(audio: audio,
                            stretcher: RubberBandStretcher(engine: state.engine),
                            ring: ring, maxBlock: 1024)
let output = try AudioOutput(engine: engine,
                             sampleRate: audio.sampleRate, channels: audio.channels)

ring.push(.setTimeRatio(state.timeRatio))

if args.count >= 5, let a = Double(args[3]), let b = Double(args[4]) {
    let start = FrameIndex(a * audio.sampleRate)
    let end = FrameIndex(b * audio.sampleRate)
    ring.push(.setLoop(FrameRange(start: start, count: end - start), true))
    ring.push(.seek(start))
    print(String(format: "Looping %.2f s – %.2f s at %.0f%% speed. Ctrl-C to stop.", a, b, speed * 100))
} else {
    print(String(format: "Playing at %.0f%% speed. Ctrl-C to stop.", speed * 100))
}

ring.push(.setPlaying(true))
try output.start()

while engine.isPlaying {
    let seconds = Double(engine.currentFrame) / audio.sampleRate
    print(String(format: "\r  %6.2f s", seconds), terminator: "")
    fflush(stdout)
    try await Task.sleep(for: .milliseconds(100))
}
output.stop()
print("\nDone.")
```

- [ ] **Step 6: Register the CLI target**

In `Package.swift`, add to `products`:

```swift
        .executable(name: "artscribe-cli", targets: ["ArtscribeCLI"]),
```

and to `targets`:

```swift
        .executableTarget(
            name: "ArtscribeCLI",
            dependencies: ["ArtscribeKit", "AudioDecode", "TimeStretch", "Playback"]),
```

- [ ] **Step 7: Verify the full suite still passes**

Run: `swift test`
Expected: PASS, all targets.

- [ ] **Step 8: Verify by listening — the real acceptance test**

```bash
swift build -c release
TRACK="$ARTSCRIBE_TEST_MEDIA_DIR/03. Wynton Marsalis - Delfeayo's Dilemma.flac"
.build/release/artscribe-cli "$TRACK" 1.0            # full speed, sanity
.build/release/artscribe-cli "$TRACK" 0.5            # half speed, pitch unchanged
.build/release/artscribe-cli "$TRACK" 0.5 30 34      # 4-second loop at half speed
```

Confirm by ear, in order:
1. Full speed sounds identical to any other player — no artefacts, no pitch shift.
2. Half speed keeps pitch: the trumpet stays on the same note, just slower.
3. The 4-second loop repeats with **no click, pop, or gap** at the seam. This is the
   single most important qualitative check in the plan — a click here means
   `feedSource` is resetting the stretcher at the loop boundary.


#### Task 9 addendum: Playback menu and output device selection

Requested directly by the user. There is no stock Apple picker view for audio output
devices on macOS — the idiomatic pattern is a menu of radio-style items — so this is
"standard macOS interface" in the sense of a real menu-bar menu wired to the real HAL, not
a bespoke panel.

**Note:** `AVAudioSession` does **not** exist on macOS; it is iOS-only. Device enumeration
and selection go through the CoreAudio HAL.

- [ ] **Add a top-level `Playback` menu** to the app's menu bar via SwiftUI `Commands`
      (`CommandMenu("Playback")`). It carries an **Output Device** submenu listing every
      available output device, with a checkmark on the active one.

- [ ] **Enumerate devices through the CoreAudio HAL**, not AVFoundation:
      `AudioObjectGetPropertyData` with `kAudioHardwarePropertyDevices` on
      `kAudioObjectSystemObject`, then keep only devices that actually have output streams
      (query `kAudioDevicePropertyStreamConfiguration` on `kAudioObjectPropertyScopeOutput`
      and require a non-zero channel count). Read each device's name from
      `kAudioObjectPropertyName`. A device with input streams only must not appear.

- [ ] **Include a "System Default" entry** that follows
      `kAudioHardwarePropertyDefaultOutputDevice` rather than pinning a specific device.
      This should be the default selection, because it is what a user expects when they
      plug in headphones mid-session.

- [ ] **Switch the device** by setting `kAudioOutputUnitProperty_CurrentDevice` on the
      `AVAudioEngine`'s `outputNode.audioUnit`. The engine must be stopped and restarted
      around the change; **playback position, speed, and loop state must survive it** — a
      device switch is not a reason to lose the user's place.

- [ ] **Observe changes** with `AudioObjectAddPropertyListenerBlock` on both
      `kAudioHardwarePropertyDevices` (device list) and
      `kAudioHardwarePropertyDefaultOutputDevice` (default changed). The menu must update
      live when a device is plugged in or removed, without reopening it.

- [ ] **Handle disappearance without silence.** If the selected device is removed while
      playing (headphones unplugged, interface powered off), fall back to the system default
      and **say so visibly** — spec §8 forbids silent degradation, and audio simply stopping
      with no explanation is exactly that. Do not crash, and do not leave the engine in a
      stopped state the user has to notice themselves.

- [ ] **Test what is testable headlessly.** Device *selection* needs hardware, but the
      device-list filtering (output-capable only), the name resolution, and the
      fallback-on-disappearance decision logic are pure and must be unit-tested against
      synthetic device lists. Do not let untestable AppKit glue absorb the decision logic —
      keep it in a plain type the tests can drive.

**Report:** the actual device list observed on this machine, and what happened when a
device was removed mid-playback (test it for real if you have a pair of headphones or an
external interface available; say plainly if you could not).

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/Playback Sources/ArtscribeCLI Tests/PlaybackTests
git commit -m "feat: AVAudioSourceNode output and artscribe-cli"
```

---

---

### Task 10: Waveform viewer — first runnable GUI (executed out of numeric order, before Task 7)

**Why this task exists and why it is specified differently.** The user asked to drive the
app early, even with reduced functionality. After Task 6 we have decode, peaks, and
viewport math — everything a waveform viewer needs except sound. This task ships a window
you can open a real track in and zoom around, with no audio.

Unlike Tasks 1-9, this task does **not** dictate the implementation code. Every code block
this plan supplied for Tasks 1-6 contained at least one defect found in review (eleven
Important defects total, all controller-authored). For view code, which the plan author
cannot verify by reasoning, prescribing exact SwiftUI would repeat that mistake at higher
cost. Instead: exact module APIs, exact behavioural requirements, exact acceptance
criteria. The implementer writes the view code against the real interfaces.

**Files:**
- Create: `Sources/ArtscribeUI/` — view layer (split into focused files; no single file over ~200 lines)
- Create: `Sources/ArtscribeApp/` — `@main` executable
- Modify: `Package.swift` — add `ArtscribeUI` library target and `ArtscribeApp` executable target, both with `sharedSwiftSettings`
- Test: `Tests/ArtscribeUITests/` — for the pure logic only (see Testing below)

**Interfaces available — these are exact, verified, and already shipped:**

```swift
// ArtscribeKit — imports nothing
public typealias FrameIndex = Int64
public struct FrameRange { init(start: FrameIndex, count: FrameIndex)
    var start, count, end: FrameIndex; var isEmpty: Bool
    func clamped(to: FrameIndex) -> FrameRange; func contains(_: FrameIndex) -> Bool }
public struct Viewport { init(totalFrames: FrameIndex, widthPixels: Int)
    static let minFramesPerPixel: Double
    let totalFrames: FrameIndex
    private(set) var startFrame: FrameIndex, framesPerPixel: Double, widthPixels: Int
    var maxFramesPerPixel: Double, visibleFrames: FrameIndex, endFrame: FrameIndex
    mutating func resize(widthPixels: Int); mutating func fit()
    mutating func zoom(by: Double, anchorFrame: FrameIndex); mutating func zoom(to: FrameRange)
    mutating func scroll(byPixels: Int)
    func pixel(forFrame: FrameIndex) -> Double; func frame(atPixel: Double) -> FrameIndex }
public struct Selection { init()
    private(set) var anchor, head: FrameIndex; var isEmpty: Bool; var range: FrameRange
    mutating func begin(at: FrameIndex); mutating func extend(to: FrameIndex); mutating func clear() }

// AudioDecode
public enum AudioFileDecoder {
    static func decode(url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> DecodedAudio }
public struct DecodedAudio { let channels: Int; let sampleRate: Double
    let frameCount: FrameIndex; var duration: Double
    func channel(_ index: Int) -> UnsafePointer<Float> }
public enum DecodeError: Error, LocalizedError { /* has errorDescription */ }

// Waveform
public struct PeakPyramid { static func build(_ audio: DecodedAudio) -> PeakPyramid
    struct Peak { var min, max: Float }
    func peaks(channel: Int, range: FrameRange, buckets: Int) -> [Peak] }
```

**Behavioural requirements:**

1. `swift run ArtscribeApp` opens a window. Call `NSApplication.shared.setActivationPolicy(.regular)` and activate, so an unbundled SwiftPM executable still gets a menu bar and keyboard focus.
2. **⌘O** opens a file picker filtered to the supported audio types. Drag-and-drop onto the window loads a file too.
3. Decoding runs off the main actor with a visible, determinate progress indicator. Errors surface as an **inline banner** carrying `DecodeError.errorDescription` — never a modal alert, and the previously loaded file stays loaded.
4. **Waveform lane**: min/max peaks per pixel column from `PeakPyramid.peaks`, one lane per channel, stacked. Silence draws as a centre line, not a gap.
5. **Overview strip** above the waveform: whole file at constant scale, with the current viewport drawn as a highlighted window.
6. **Time ruler** with sensible tick spacing that adapts to zoom (mm:ss.SSS at high zoom, mm:ss when zoomed out).
7. **Keyboard** (the agreed left-hand cluster subset): `E` zoom out, `R` zoom in, `Z` scroll left, `X` scroll right, `⌘0` fit whole file, `⌘9` zoom to selection, `Esc` clear selection. Zoom **must anchor on the playhead** (use frame 0 or the selection start until a playhead exists) — never the viewport centre.
8. **Mouse**: drag to select, ⇧-drag to extend, double-click selects all, pinch to zoom, two-finger scroll to pan.
9. **Status readout**: filename, sample rate, channel count, duration, current zoom (frames/pixel or a x-factor), and the selection range as mm:ss.SSS–mm:ss.SSS with its duration.
10. Window resize calls `Viewport.resize(widthPixels:)` and re-renders correctly.

**Visual direction** (dark-first, matching the agreed mockups): background `#131417`, panel `#1B1D22`, waveform `#7A889A`, selection fill `#F0A35E` at ~13% with 2px `#F0A35E` edges, accent/viewport-window `#4FD1C5`, text `#C9CED6`, dimmed text `#6F7783`. Use a monospaced font for all time readouts so digits do not jitter.

**Performance requirement — this is the one that dictates the design:**
The waveform must only be recomputed when the viewport changes, not on every frame.
Render it into a cached layer/image and redraw only on viewport or size change; overlays
(selection, cursor) draw on top cheaply. Zooming and panning must stay smooth on the
25-million-frame reference track. State the approach you chose in your report.

**Explicitly OUT of scope** — do not build these, they belong to Tasks 7-9 and Plan 2:
playback, transport controls, speed control, looping, markers, the inspector panel, the
generated help sheet, the binding table, `.artscribe` session sidecars, and XcodeGen
bundling. A `swift run` executable is sufficient; a double-clickable `.app` comes later.

**Testing:** view rendering is not unit-tested here — that is deliberate, and consistent
with the spec's "not doing SwiftUI snapshot tests" decision. Do test the **pure logic** you
add: ruler tick-interval selection across zoom levels, time formatting at boundaries
(0, <1s, >1h), and the mapping from a drag gesture's pixel range to a `FrameRange`. If you
find yourself unable to test a piece of logic because it is tangled into a view, extract it
— that is the signal the boundary is wrong.

**Acceptance — the implementer must verify all of these by running the app:**
- [ ] `swift run ArtscribeApp` opens a window with a menu bar and keyboard focus
- [ ] ⌘O loads `~/Downloads/Wynton Marsalis - Black Codes (From The Underground)  - 1985-2023 (24-44)/01. Wynton Marsalis - Black Codes.flac` (9:35, 24-bit) and draws its waveform
- [ ] The waveform has visible musical structure — not a solid block, not a flat line
- [ ] E/R zoom smoothly from whole-file down to individual cycles; the anchor frame stays put
- [ ] Z/X pan without stutter, and clamp correctly at both ends
- [ ] Drag-select shows the highlighted region and a correct mm:ss.SSS readout
- [ ] ⌘9 frames the selection; ⌘0 returns to the whole file
- [ ] Resizing the window re-renders correctly at the new width
- [ ] Opening a non-audio file shows the inline error banner and keeps the previous file
- [ ] `make check` green and pre-commit hooks pass

**Report additionally:** a screenshot path if you can capture one, the caching approach you
chose, and the measured time from "file chosen" to "waveform on screen" for the reference
track (spec §1.2 budget: under 2 s; decode alone is ~1.54 s, pyramid ~5 ms).

---

### Task 11: Wire playback into the viewer — the MVP milestone

This is the task that makes the app worth using. After it, the user can load a file, hear
it, select a passage, loop it seamlessly, and change speed — all from the keyboard.

**Depends on:** Tasks 7 (`CommandRing`), 8 (`PlaybackEngine`), 9 (`AudioOutput`), 10 (viewer).

**Files:** extend `Sources/ArtscribeUI/` (view model, commands, status bar, waveform overlay)
and `Sources/ArtscribeApp/`. Add `Tests/ArtscribeUITests/` coverage for the pure logic.

**Requirements:**

- [ ] **Transport**: `Space` play/pause, `Return` to selection start (else 0). The playhead
      is drawn in the waveform and ruler and moves during playback.
- [ ] **Playhead position comes from polling** `PlaybackEngine.currentFrame` on a display
      link, never pushed from the audio thread. The audio thread must not touch the model.
- [ ] **Speed**: `Q`/`W` ∓5%, `⇧Q`/`⇧W` ∓1%, `1`/`2`/`3`/`4` → 100/75/50/33%, `⌥E` toggles
      Studio/Fast. Range 0.10–2.00. Pitch is always preserved.
- [ ] **Loop**: `A` set in at playhead, `S` set out at playhead, `D` toggle, `F` restart
      loop, `G` selection → loop. The loop region is drawn distinctly from the selection.
- [ ] **Auto-scroll is page-flip**, and suppressed while a loop is active and fits on
      screen. Continuous centred scrolling is explicitly rejected — it looks better in a
      demo and is miserable to transcribe against, because the waveform never stops moving.
- [ ] **Status bar** shows speed %, engine, and loop state alongside the existing readouts.
- [ ] **Speed and loop changes take effect on the next render quantum** with no dropout,
      no click, and no loss of position.
- [ ] Degraded engine state (R3 → R2 → passthrough) is **visibly** indicated per spec §8.

- [ ] **A `Playback` menu in the macOS menu bar** carrying the transport and speed actions
      with their shortcuts shown, alongside the Output Device submenu Task 9 added. User
      feedback: discovering these only from a help sheet is not enough — they belong in the
      menu where macOS users look for them. Minimum contents, each showing its key
      equivalent and correctly enabled/disabled when no track is loaded:
      - **Play / Pause** (`Space`) — the title toggles to reflect current state
      - **Stop** — halt and leave the playhead where it is
      - **Play from Start** (`Return`) — from selection start if there is a selection, else 0
      - separator
      - **Faster** (`W`) and **Slower** (`Q`), ∓5%
      - **Faster (Fine)** (`⇧W`) and **Slower (Fine)** (`⇧Q`), ∓1%
      - **Speed presets** 100 / 75 / 50 / 33% (`1`–`4`), with a checkmark on the active one
      - **Studio / Fast engine** toggle (`⌥E`), showing which is active
      - separator
      - **Loop** items: Set Loop In (`A`), Set Loop Out (`S`), Toggle Loop (`D`),
        Restart Loop (`F`), Selection → Loop (`G`)
      Beware: a prior task found that `.disabled()` in a SwiftUI `Commands` body goes stale
      against `@Observable` and silently broke ⌘9. Verify enablement actually updates.

- [ ] **Consume `PlaybackEngine.renderStallCount` and `rejectedCommandCount`.** Task 8
      publishes both atomics and nothing reads them; Task 8's reviewer noted that a counter
      nobody reads is only half a fix for silent degradation, and that the existing §8 line
      above covers only engine *fallback*, not stalls or rejected commands. Poll them
      alongside the playhead and surface a visible indication when either advances. Note
      that after a stall the engine deliberately stays `playing`, so an unsurfaced permanent
      stall presents to the user as "playing, playhead frozen, silence, forever."

- [ ] **Beware the CLI bug Task 9 already hit here**: `isPlaying` is not observable until
      the render thread has drained the command ring, so code that pushes `.setPlaying(true)`
      and immediately checks `isPlaying` will conclude playback ended before a single frame
      was rendered. Task 9 fixed this in the CLI; the UI's play/pause state must not repeat it.

- [ ] **`.setPlaying(true)` at EOF with no loop bounces** — the engine restarts the stream,
      immediately re-finalises, and clears the playing flag within the same render call. The
      play button will visibly flicker unless the UI handles it.

**Acceptance — verify by running, and report what you actually heard:**
- [ ] A 4-second loop at 50% speed repeats with **no click, pop, or gap at the seam**. This
      is the single most important qualitative check in the whole project.
- [ ] Pitch is unchanged at 50% and 200% — a held note is the same note, just longer.
- [ ] Changing speed mid-playback does not click, stutter, or jump position.
- [ ] Setting loop points while playing takes effect on the next pass.
- [ ] The playhead stays visually synchronised with what you hear.

---

### Task 12: Bundle and distribute — make it launchable

`swift run` is fine for development and wrong for daily use. This task produces a real
double-clickable `Artscribe.app`.

**Files:** `project.yml` (XcodeGen), `App/Info.plist`, `App/Artscribe.entitlements`, an app
icon, `Makefile` targets, README updates.

**Requirements:**

- [ ] **`make app`** produces `Artscribe.app` that launches by double-click from Finder,
      with a correct bundle identifier, version, display name, and icon.
- [ ] The `.app` **must not be committed**; `project.yml` is the source of truth and the
      generated `.xcodeproj` stays gitignored, per the project's build-system decision.
- [ ] **Declare supported document types** in `Info.plist` so Artscribe appears in
      Finder's "Open With" for the formats it decodes, and so dropping a file on the dock
      icon works.
- [ ] **Ad-hoc codesign** so it launches on this machine without Gatekeeper friction.
      Document what a real Developer ID signature and notarisation would additionally
      require, but do not attempt notarisation — it needs an Apple Developer account.
- [ ] **`make dist`** produces a distributable archive (zip or DMG) of the signed app.
- [ ] **README** gains a "Running Artscribe" section covering both `make app` for users and
      `swift run` for development.
- [ ] `make check` still passes, and the SwiftPM path keeps working — bundling must not
      become the only way to build.

**Acceptance:** double-click the built app from Finder, open a file through its own ⌘O, and
confirm playback works from the bundled binary — not just from `swift run`.

---

### Task 13: UI polish from acceptance testing — scroll-zoom, speed emphasis, theming

Three items from the user driving the real app, in their stated priority order.

**Files:** `Sources/ArtscribeUI/` (TrackpadMonitor, Palette, WaveformRenderer, StatusBarView,
OverviewStripView, WaveformLanesView, ViewerCommands/PlaybackCommands, ViewerModel),
`Sources/ArtscribeApp/`. Tests for the pure logic in `Tests/ArtscribeUITests/`.

#### P0 — Scroll wheel zooms

Today `TrackpadMonitor` maps every `.scrollWheel` event to `.pan`, without consulting
`NSEvent.hasPreciseScrollingDeltas`. That flag is how macOS distinguishes a physical mouse
wheel (coarse, non-precise) from a two-finger trackpad swipe (precise). The two carry
opposite conventions, so they must be handled differently:

- [ ] **Mouse wheel (`hasPreciseScrollingDeltas == false`) → zoom.** Up zooms in, down zooms
      out. This is the user's request and matches essentially every app with a zoom concept.
- [ ] **Trackpad two-finger scroll (`hasPreciseScrollingDeltas == true`) → keep panning.**
      Reversing this would fight a system-wide macOS convention. (Controller decision; the
      user has been told and can override.)
- [ ] **`⌘` + scroll → zoom regardless of device.** Universal escape hatch, idiomatic from
      browsers and maps, and it gives trackpad users a zoom gesture that isn't a pinch.
- [ ] **Scroll-zoom anchors on the pointer**, not the playhead. Cursor-driven zoom that
      anchors elsewhere feels broken. Keyboard zoom (`E`/`R`) keeps its playhead anchor —
      `Viewport.zoom(by:anchorFrame:)` already takes the anchor, so this is a call-site
      choice, not new machinery.
- [ ] **Works in both the main waveform lane and the overview strip.** In the overview,
      zooming changes the main viewport (the strip itself always shows the whole file).
- [ ] **Respect natural-scrolling direction** so the gesture doesn't invert for users who
      have flipped it.
- [ ] Test the pure mapping: event characteristics → action, for wheel/trackpad/⌘-modified,
      including the direction sign.

#### P1 — Speed readout stands out when it is not 100%

- [ ] When `speed.ratio != 1.0`, render the speed readout **bold and in an accent colour**
      so an altered speed is obvious at a glance. At exactly 100% it returns to the normal
      readout treatment, so the emphasis means something.
- [ ] Use an existing palette accent rather than inventing a colour, and make sure it stays
      legible in **both** themes once P2 lands — a colour that pops on dark and vanishes on
      light is not done.
- [ ] Apply the same treatment in the Playback menu's checked speed preset if it reads well.

#### P2 — Light / Dark / System theme

- [ ] A **Theme** preference with three options — System (default behaviour follows macOS),
      Light, Dark — persisted across launches and reachable from the menu bar (View menu or
      Settings; pick whichever is more idiomatic and say why).
- [ ] Dark stays the default look the user already likes; **Light must be genuinely designed,
      not an inversion.** Waveform, selection, loop region, playhead, ruler, overview lens
      and the inline error banner all need light-mode values with real contrast. Check
      contrast rather than eyeballing it.
- [ ] **The trap:** `WaveformRenderer` rasterises into a cached bitmap with colours baked in
      (see its own doc comment on why it writes pixels directly rather than filling rects).
      A theme change **must invalidate that cache and re-render**, or the waveform will keep
      its old colours against the new background. The same applies to the overview strip's
      cached image. Make the theme part of the render cache key.
- [ ] Switching theme must not disturb playback, position, selection, loop, or zoom.
- [ ] Test the pure part: that the render cache key changes with the theme, so a stale
      bitmap cannot survive a switch.

**Acceptance — verify by running:**
- [ ] Mouse wheel zooms in the main lane and in the overview, anchored under the pointer
- [ ] Trackpad two-finger scroll still pans; pinch still zooms; ⌘+scroll zooms on both devices
- [ ] Speed readout is visibly emphasised at 50% and normal at 100%
- [ ] All three theme settings look deliberate, and switching mid-playback re-renders the
      waveform correctly without interrupting audio

---

### Task 14: Navigation nudges and a Settings window

**Context the implementer needs:** the spec's action catalog (§6.2) has documented three
nudge tiers since day one, but **none of them were ever implemented** — `grep -rn nudge
Sources/` returns nothing. Task 11's brief omitted them and its review checked against that
brief rather than the spec, so the gap survived. This task closes it, with the user's
preferred defaults rather than the spec's original ones.

**Do not add a fourth tier.** The user's "nudge" and "rewind" map onto the existing
`nudge` and `nudge.coarse` actions with new default values. Retune, don't duplicate.

| Action | Binding | Old spec default | **New default** |
|---|---|---|---|
| Nudge fine back/forward | `⇧Z` / `⇧X` | 50 ms | 50 ms (unchanged) |
| **Nudge** back/forward | `Z` / `X`, `←` / `→` | 0.5 s | **2 s** |
| **Rewind/Skip** back/forward | `⌥Z` / `⌥X`, `⌥←` / `⌥→` | 5 s | **10 s** |

- [ ] Implement all three tiers on `ViewerModel`, seeking via `PlaybackCommand.seek`.
- [ ] **Nudging must work whether or not playback is running**, and must not stutter or
      restart audio when it is. Clamp to `[0, frameCount]`; when a loop is active, decide
      and document whether a nudge may leave the loop region (recommended: it may, matching
      Transcribe!, since `F` already exists to jump back into the loop).
- [ ] Add all six to the **Playback menu** in a Navigation section, each showing its key
      equivalent, disabled when no track is loaded.
- [ ] Update spec §6.2's table to the new values so the catalog stops lying.

#### Settings window (⌘,)

- [ ] Use SwiftUI's **`Settings` scene**, which wires ⌘, and the standard
      "Artscribe → Settings…" menu item automatically. That is the idiomatic macOS route —
      do not hand-roll a window and a shortcut.
- [ ] **Playback tab** exposing the three nudge amounts as editable values with sensible
      units and validation. Reject or clamp nonsense (negative, zero, absurdly large) rather
      than storing it — a nudge of 0 s silently does nothing, which is the silent-degradation
      failure this project keeps finding.
- [ ] Persist via `@AppStorage`/`UserDefaults`, applied live without relaunch, with a
      **Restore Defaults** control.
- [ ] **Move Task 13's Theme preference here** if Task 13 has already landed — a Settings
      window is its natural home and two preference surfaces is one too many. Coordinate:
      whichever task lands second owns the consolidation.
- [ ] The menu items' displayed shortcuts must stay correct; only the *amounts* are
      configurable in this task, not the key bindings themselves. (Full rebindable
      bindings are the deferred `BindingTable` work — spec §6.3 — not this.)

**Testing:** the amounts, clamping, validation, and seconds→frames conversion are pure and
must be unit-tested, including at the file's start and end boundaries. The Settings view
itself is not snapshot-tested, consistent with the project's standing choice.

**Acceptance — verify by running:**
- [ ] `Z`/`X` move by 2 s, `⌥Z`/`⌥X` by 10 s, `⇧Z`/`⇧X` by 50 ms, both stopped and playing
- [ ] Nudging near either end of the file clamps instead of misbehaving
- [ ] ⌘, opens Settings; changing the nudge amount takes effect immediately
- [ ] Restore Defaults returns 50 ms / 2 s / 10 s
- [ ] All six navigation items appear in the Playback menu with correct shortcuts

---

### Task 15: Transport bar, uniform menu shortcuts, and loop prominence

Three pieces of UI feedback from the user driving the real app. They are one task because
they touch the same files and the same visual language.

#### A — A DAW-style transport bar (the substantial piece)

The user asked for "a Transport component similar to other DAWs/audio editors so I can
toggle loop on/off and see its state from bigger buttons with relevant icons on top."

- [ ] A horizontal transport bar **directly above the existing status bar**, using SF Symbols
      at a size that reads as a control surface rather than a toolbar afterthought.
- [ ] Contents, grouped with separators: **rewind / nudge-back / play-pause / nudge-forward
      / forward**, **play-from-selection-start**, **loop toggle**, **speed − / + with the
      current speed between them**, **zoom out / in**.
- [ ] **Every button is a second front-end to an action that already exists** on
      `ViewerModel`. Do not reimplement behaviour in the view — if a button needs logic the
      keyboard path does not have, that logic belongs on the model where it can be tested.
- [ ] **State is visible, not just triggerable.** The loop button reads as on/off at a
      glance (filled/tinted vs outline), play/pause reflects the transport, and the speed
      readout carries the same emphasis rule as the status bar.
- [ ] Buttons show their keyboard shortcut in a **tooltip**, so the bar teaches the keyboard
      rather than replacing it. This app is keyboard-first; the transport is for discovery
      and for when a hand is already on the mouse.
- [ ] Correct enablement with no track loaded, and correct behaviour in both themes.
- [ ] The bar must not steal keyboard focus — pressing Space must still play, not re-trigger
      whichever button was last clicked. Verify this explicitly; it is the classic defect of
      adding buttons to a keyboard-driven app.

#### B — Uniform menu shortcut presentation

Menus currently mix two styles: some items carry a real key equivalent (right-aligned, grey,
system-drawn) and others spell the shortcut into the title text, e.g. `"Play  (Space)"`.
The user wants one convention: **the system one — right-aligned and grey, everywhere.**

- [ ] Convert the parenthesised-title items to real key equivalents.
      `.keyboardShortcut("q", modifiers: [])` is the documented way to declare a
      no-modifier shortcut; SwiftUI defaults to ⌘ otherwise.
- [ ] **First, re-measure the reason the split exists.** `PlaybackCommands` documents that a
      plain-letter menu key equivalent "is claimed application-wide and flashes the menu bar
      on every keystroke, which during a held `Q`/`W` speed sweep is a strobe." Establish
      whether that is still true. If it is, the fix is not to give up on the convention —
      find the real remedy and report what it was. If it is not reproducible, say so and
      convert everything.
- [ ] **No action may fire twice.** The current design deliberately splits handling between
      the menu (modified chords) and `DocumentView` (unmodified keys) so nothing is handled
      by both. Whatever you change, verify each action fires exactly once per keypress —
      there are existing tests asserting single-fire; keep them meaningful.
- [ ] Watch for genuine conflicts: a plain-letter equivalent registered application-wide can
      fire while a text field has focus. Settings has editable fields. Check that typing in
      Settings does not trigger transport actions.

#### C — Loop state prominence

- [ ] When looping is active, the loop readout gets the same treatment the speed readout
      already gets when it is not 100%: **bold, in an accent colour**, legible in both
      themes. An engaged loop is a mode, and modes should be obvious.

**Acceptance — verify by running:**
- [ ] Every menu item in View and Playback shows its shortcut right-aligned and grey; none
      spell it into the title
- [ ] Each action still fires exactly once per keypress
- [ ] Typing in Settings does not trigger transport actions
- [ ] Transport buttons drive the same model actions as the keys, show live state, and do
      not steal focus from Space
- [ ] Loop-on and speed≠100% both read as clearly modal in Light and Dark

---

### Task 18: Selection movement, menu reorganisation, and configurable zoom direction

All P0 feedback from the user driving the app.

#### A — Flip the zoom direction, and make it a preference

- [ ] **Drag down now zooms in** (the reverse of today). The previous direction was chosen on
      internal consistency because neither Ableton's nor Melodyne's manual states which way
      theirs runs; the user has driven it and prefers down-to-zoom-in. Their hand beats our
      reasoning.
- [ ] Make it a **Settings preference** — an "Invert zoom drag direction" toggle — so it is a
      one-click change rather than a rebuild. Apply to the ruler drag and the ⌥-lane drag
      alike, and say in the report whether it should also affect the scroll-wheel zoom
      (recommendation: yes, consistency within one window matters more than matching any
      particular other app).

#### B — A bigger ruler hit area

- [ ] The ruler is about to carry a frequently-used gesture, so make it a comfortable drag
      target. Increase its height, and consider whether the hit area can extend slightly
      beyond the drawn ruler without stealing from the waveform lanes. Keep it visually
      proportionate — this is a hit-target change, not an invitation to make the ruler loud.

#### C — Move the selection, in two step sizes

Mirrors the transport nudge/rewind pair, but moves the **selection** rather than the playhead.

- [ ] Four actions: move selection left/right by a **gentle** amount, and left/right by an
      **aggressive** amount. The whole selection translates — both edges move together,
      preserving its length.
- [ ] Shortcuts, chosen to stay left-hand-driveable and not collide with anything existing.
      Propose them in your report with your reasoning; `⇧←`/`⇧→` are already extend-selection
      and `←`/`→` are already nudge-playhead, so these need different chords.
- [ ] **Both amounts configurable in Settings, in seconds with fractional support** (so a
      user can set 20 ms). Validate as the nudge amounts already are: reject or clamp
      nonsense rather than storing a zero that silently does nothing.
- [ ] Clamp at the file bounds — a selection pushed against either end stops rather than
      shrinking or inverting. Test both ends.
- [ ] Menu items alongside the other selection actions (see D).

#### D — Reorganise the menus

The Playback menu now carries 36 items and has become a catch-all. Split it so each menu has
one coherent identity:

- [ ] **Edit** — the selection actions. `Select All`, `Clear Selection`, `Extend Selection`,
      and the four new `Move Selection` items. Selection belongs in Edit by long-standing
      macOS convention; `Select All` is already expected there.
- [ ] **Loop** (new top level) — `Set Loop In`, `Set Loop Out`, `Toggle Loop`, `Restart Loop`,
      `Selection → Loop`. This is the app's signature feature and deserves to be findable.
      It is also where the Practice hub will land later.
- [ ] **Playback** (slimmed) — transport, navigation nudges, speed, engine, volume, output
      device.
- [ ] Every item keeps its right-aligned system-drawn shortcut. Nothing regresses to a
      shortcut spelled into the title.

#### E — `Play from selection start` moves to `⇧Space`

- [ ] Rebind from `Return` to `⇧Space`, so the whole transport is left-hand driveable.
- [ ] **Update every reference**: the menu, the transport bar tooltip, `README.md`, the
      spec's §6.2 action catalog, and any test or acceptance check asserting the old binding.
      A stale reference here is exactly the drift that has already bitten this project twice.
- [ ] Decide whether `Return` keeps a role (recommendation: leave it bound as a synonym, or
      free it deliberately — say which and why).

---

### Task 19: Session persistence — the `.artscribe` sidecar, Save, and Save As

**This is a documented feature that was never built.** Spec §7 has promised it since the
design was approved and `grep -rn sidecar Sources/` returns nothing. That makes it the second
such gap found by the user rather than by our own review, after the nudge tiers.

What spec §7 requires:

> A visible `<track>.artscribe` file written next to the audio file, JSON, containing speed,
> loop region, loop enabled, viewport, playhead, and active engine. Written on close and
> debounced during editing.
>
> If the containing directory is not writable — a read-only volume, a NAS, a mounted image —
> fall back to Application Support keyed by file URL, and surface the fallback. Loop points
> must never be silently lost because a directory was read-only.

The user additionally asks for the standard document behaviour:

- [ ] **File ▸ Save (⌘S)** and **Save As… (⇧⌘S)**, behaving as a Mac user expects.
- [ ] **A dirty flag**, reflected in the window's close button and title as macOS does it.
- [ ] **Closing with unsaved changes prompts** — Save / Don't Save / Cancel — and Cancel
      genuinely cancels the close.
- [ ] **Reopening a track restores its session**: speed, loop, viewport, playhead, engine.
- [ ] The read-only-directory fallback from spec §7, surfaced visibly, never silent.
- [ ] Round-trip safety: the JSON is user-editable by design, so **decoding must clamp or
      reject nonsense rather than trusting it**. `SpeedState` and `Selection` already have
      validating decoders for exactly this reason — follow that precedent for everything new.

**Testing:** encode/decode round-trip, clamping of out-of-range and malformed values, the
read-only fallback path, and dirty-tracking transitions are all pure and must be tested. The
save panel and the close prompt are AppKit and are not.

---

### Task 20: The inspector — a reusable side panel, and the shortcut reference

The user asked for "a side-window that can be toggled to show/hide" for the shortcut
reference, and for the Practice hub to use "a similar mechanism". That mechanism already
exists in the approved design and was never built: a **collapsible inspector**, specified in
§1.1 (MVP scope), §2 (architecture decisions), §6.2 (`view.toggleInspector`, `⌥⌘I`), and §8
(where the read-only sidecar fallback is supposed to be surfaced). This is the **fourth**
documented-but-unbuilt feature the user found rather than our reviews.

Build the mechanism once, then two clients land on it: Shortcuts here, Practice in Task 21.

#### A — The inspector mechanism

- [ ] SwiftUI's `.inspector()` — the native trailing-sidebar idiom, collapsible, resizable,
      with its width persisted. Do not hand-roll a panel.
- [ ] **Pages**, switchable within the one inspector rather than competing for the trailing
      edge: **Session**, **Shortcuts**, and later **Practice**. Xcode's inspector is the
      reference for how this reads.
- [ ] `⌥⌘I` toggles the inspector, per spec §6.2. Each page additionally gets its own
      shortcut that opens the inspector *to that page* — pick them, justify them, and make
      sure they do not collide with the now-large keymap.
- [ ] Entries in the **View** menu, with right-aligned system-drawn shortcuts like every
      other menu item.
- [ ] Collapsing it must return the full width to the waveform, and the viewport must
      re-render correctly at the new width (`Viewport.resize` already exists).

#### B — The Session page — spec §1.1's "inspector showing speed, loop points, and active engine"

- [ ] Speed, loop in/out/enabled, and the active stretch engine, live.
- [ ] **This is where spec §8's read-only-sidecar fallback belongs.** Task 19 had to put that
      indicator in the title bar because no inspector existed; move it here and remove the
      workaround.

#### C — The Shortcuts page — and the anti-drift requirement that shapes it

- [ ] A clean, scannable reference: grouped by category, key on the right in the same
      system style the menus use, scrollable, legible in both themes.
- [ ] **It must be generated from a single source of truth that the menus also consume.**
      A hand-written list is guaranteed to drift — this project has already shipped four
      features whose documentation and implementation disagreed. Introduce an
      `ActionCatalog`: one list of (action id, display name, category, default shortcut) that
      **both** the menu builders and this panel read from. A shortcut must be impossible to
      change in one place and not the other.
- [ ] This is also the foundation spec §6.3 needs for the deferred rebindable `BindingTable`
      and for MIDI mapping later. Build it as that foundation, but **do not build rebinding
      now** — one list, consumed twice, is the whole scope.
- [ ] Add a test asserting every action in the catalog appears in exactly one menu, and that
      no menu item exists outside the catalog. That test is the drift guard.

---

### Task 21: The Practice hub

The user's idea, and the most genuinely novel thing in the product — Transcribe! has no
equivalent. Lands as a third page in the Task 20 inspector.

- [ ] **Ramping loops.** Play a loop repeatedly while the speed climbs. MVP behaviour the
      user described: increase by a fixed percentage each repetition.
- [ ] **The better form they asked for**: give **start speed**, **end speed** and **number of
      repetitions**, and compute the per-repetition delta. Sane defaults (e.g. 50% → 100%
      over 10 repetitions), each field overridable.
- [ ] **Live state while running**: which repetition you are on, the current speed, and how
      many remain. A practice tool whose progress is invisible is a stopwatch you cannot see.
- [ ] Start / stop, and a clear indication when the ramp completes. Decide what happens at
      the end — hold the final speed, or stop — and justify it.
- [ ] The ramp drives the **existing** speed and loop actions on `ViewerModel`. Do not
      duplicate transport logic; if the ramp needs behaviour the manual path lacks, that
      behaviour belongs on the model where it is testable.
- [ ] Speed changes must not click or interrupt playback — the engine already applies a
      ratio change on the next render quantum, so drive it the same way the keyboard does.
- [ ] Its own shortcut and View-menu entry, consistent with the other pages.

**Testing:** the ramp schedule is pure and must be tested — the computed deltas for a given
start/end/count, behaviour when start equals end, count of 1, an inverted range (end below
start, which is a legitimate way to practise *slowing down*), and clamping to the 0.10–2.00
speed range. Verify the ramp advances on loop wrap rather than on a timer, so it stays
correct when the loop length or speed changes underneath it.

---

### Task 22 (P0): Play-from-start precedence, and double-click plays instead of selecting all

Two behaviours the user hit while driving the app. Both are small; both are wrong in a way
that makes the app feel arbitrary.

#### A — `Play from start` (`⇧Space`) must follow one precedence rule

Observed: with no selection it plays from the **track** start even when a loop is set; with a
selection it plays from the selection start *or* the loop start depending on circumstances.

**Diagnosis (already established — do not re-derive):** `returnToStart()`, which
`playFromStart()` delegates to, is

```swift
seek(to: selection.isEmpty ? 0 : selection.range.start)
```

It never considers the loop. The "or from loop start" behaviour is not a second code path —
it is `PlaybackEngine` *containing* the seek: seeking outside an active loop makes the engine
pull the cursor into the region (it "wraps in from after, falls in from before", by design
from Task 8). So the UI aims at the track start, the engine drags it to the loop, and the
result reads as two competing rules.

- [ ] Implement one precedence, in this order:
      1. **A selection exists** → play from the selection start
      2. **No selection but a loop is active** → play from the loop start
      3. **Otherwise** → play from the track start
- [ ] Fix it in `returnToStart()` so the aim point is right at source, rather than relying on
      the engine to correct a bad target. `returnToStart` is also bound on its own, so both
      callers benefit.
- [ ] Decide whether "a loop is active" means `isEnabled` or merely "loop points are set",
      and say which and why. (Recommendation: `isActive` — an existing but disabled loop
      should not steer the playhead, because the user has explicitly turned it off.)
- [ ] Test all four combinations: selection only, loop only, both, neither. The both case is
      the one that was broken.
- [ ] Update the spec's §6.2 catalog entry for `transport.returnToStart`, which currently
      says "To selection start, else 0" and will now be wrong.

#### B — Double-click plays from the click point instead of selecting all

Observed today at `ViewerModel+Interaction.swift:259-262`: a second click within the
double-click window calls `selectAll()`.

- [ ] Double-click now **moves the playhead to the click point and starts playing**. Single
      click continues to place the playhead without playing.
- [ ] `⌘A` remains Select All, so nothing is lost — only the mouse gesture is reassigned.
- [ ] The click state machine (`isSecondClick`, the time window, the slop distance) is
      covered by tests added in an earlier fix round. **Keep them meaningful** — update what
      they assert rather than deleting them, and confirm a third click still does not chain.
- [ ] Confirm this composes with the precedence rule in A: a double-click sets an explicit
      cursor position, so it should play from *there*, not be re-routed to a selection or
      loop start.
- [ ] Update `README.md`, which currently documents "double-click to select all".

---

### Task 23 (P0): Draggable loop and selection edges

Standard in Ableton, Logic and every serious editor, and the user calls it a must-have.
Grab the left or right edge of the loop region — or the selection — and drag it.

#### Behaviour

- [ ] **Drag either edge of the loop region** to move it; the opposite edge stays put.
- [ ] **Drag either edge of the selection** the same way.
- [ ] **Drag the body** of the loop region to move the whole loop, preserving its length.
      (Judgement call: propose whether the selection body should also be draggable, and say
      why. `C`/`V` already move the selection by keyboard.)
- [ ] Dragging one edge past the other must not produce an inverted region. Decide between
      **swapping** the edges (the drag continues, now grabbing the other edge — what most
      DAWs do) and **clamping** at zero length, and justify the choice.
- [ ] While dragging, show the edge's time as a live readout, in the same monospaced style
      the rest of the app uses for time.
- [ ] Loop edges dragged while playing must take effect without a click or dropout — push
      through the existing `PlaybackCommand.setLoop` path rather than inventing another.

#### The interaction hazard — this is the part most likely to go wrong

The waveform lanes already carry: plain drag (select), ⇧-drag (extend selection), ⌥-drag
(zoom), single click (place playhead), double click (play from here), pinch, and wheel. The
ruler carries a vertical zoom drag. **Adding edge-dragging to a surface with seven live
gestures is where this task will fail if it fails.**

- [ ] **Edge grab must win over starting a new selection** when the pointer is inside an
      edge's grab zone, and must lose to it everywhere else. Decide the precedence
      explicitly and write it down.
- [ ] Decide what happens when the loop edge and a selection edge are at or near the same
      pixel, since `G` (selection → loop) makes that common. Pick one and make it
      predictable.
- [ ] **Before finishing, enumerate every gesture on the lanes and the ruler and confirm each
      still does exactly what it did.** A regression here is instantly visible to the user.

#### The visual and pointer treatment

The user asked for something "nuanced but palpable", following iOS/macOS design language.
Consider loading the `frontend-design` skill for direction.

- [ ] **Grab zone wider than the drawn edge** — the loop edge is 2 pt; a grab zone of roughly
      8–10 pt on each side makes it reliably hittable (Fitts's law). The hit area is not the
      visual.
- [ ] **Hover** gives a restrained but unmistakable response: the edge brightens and
      thickens slightly, optionally with a narrow gradient wash falling away from it. Nothing
      that jumps.
- [ ] **Active drag** is stronger than hover — a full-height guide line reads well and shows
      exactly where the edge will land.
- [ ] **Pointer style** via `pointerStyle(_:)`, as Task 17 established. `.frameResize(position:)`
      is the semantically correct choice for resizing a region from one edge;
      `.columnResize(directions:)` is the alternative. Pick one, say why, and make it appear
      on hover — not only once dragging starts.
- [ ] Legible and correct in **both** themes.
- [ ] Respect **Reduce Motion** for any animated transition.

**Testing:** hit-testing (which edge, if any, is under a given pixel, including the
overlapping-edges case), the drag→new-region maths, inversion handling, and clamping at the
file bounds are all pure and must be tested. Views are not snapshot-tested — extract the
logic. Drive the real gestures in the acceptance harness; the screen is unlocked and real
`NSEvent`s reach SwiftUI.

## Plan Complete

At this point `swift test` covers decode, peaks, stretch quality, the command ring, and
sample-accurate looping, and `artscribe-cli` plays any supported file at any speed on a
seamless loop.

**Plan 2 (app shell and UI)** builds on this: `InputBindings` (Action, BindingTable,
ActionDispatcher, KeyboardSource), `DocumentModel`, the SwiftUI lane views, the inspector,
the generated help sheet, the `.artscribe` sidecar, and the XcodeGen app target.
