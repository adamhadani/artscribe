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

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/Playback Sources/ArtscribeCLI Tests/PlaybackTests
git commit -m "feat: AVAudioSourceNode output and artscribe-cli"
```

---

## Plan Complete

At this point `swift test` covers decode, peaks, stretch quality, the command ring, and
sample-accurate looping, and `artscribe-cli` plays any supported file at any speed on a
seamless loop.

**Plan 2 (app shell and UI)** builds on this: `InputBindings` (Action, BindingTable,
ActionDispatcher, KeyboardSource), `DocumentModel`, the SwiftUI lane views, the inspector,
the generated help sheet, the `.artscribe` sidecar, and the XcodeGen app target.
