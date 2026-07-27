# Artscribe — Design Spec

**Date:** 2026-07-27
**Status:** Approved
**Target:** macOS 26+, Apple Silicon, Swift 6.3

---

## 1. Purpose

A modern music-transcription tool for macOS: load a track, see its waveform, select a
passage, loop it, and slow it down without changing pitch — driven almost entirely from
the keyboard, because the user's hands are usually on an instrument.

The reference point is [Transcribe!](https://www.seventhstring.com/xscribe/overview.html),
which is functionally excellent and visually and ergonomically dated. Artscribe targets its
core loop with a 2026 treatment: native Apple Silicon, better time-stretch quality, a
keyboard-first interaction model, and an architecture that admits MIDI pedals and spectral
analysis later without a rewrite.

### 1.1 MVP scope

In:

- Open any natively-decodable audio file (⌘O, drag-and-drop, Recents)
- Waveform lane, overview strip, and time ruler sharing one viewport
- Zoom and pan — keyboard, pinch, scroll; always playhead-anchored
- Selection by keyboard and mouse drag
- Seamless, sample-accurate A/B looping
- Speed 10–200%, pitch preserved, with a Studio/Fast engine switch
- Collapsible inspector showing speed, loop points, and active engine
- Full menu-bar coverage plus a help sheet generated from the live binding table
- Per-file session persistence via a visible `.artscribe` sidecar

Explicitly out (see §11):

- Pitch shift / transpose, markers, spectrum, note and chord guessing, piano roll,
  EQ, karaoke/mono mixing, video display, MIDI input, `.xsc` import

### 1.2 Success criteria

- A 10-minute 24-bit FLAC opens and renders a full waveform in under 2 s
- Speed and loop changes are audible on the next render quantum, with no dropout
- The core loop — select, loop, slow, nudge, zoom — is fully reachable by the left
  hand alone
- `swift test` runs the entire non-UI test suite headlessly in seconds, with no audio
  hardware and no Xcode

---

## 2. Decisions and rationale

| Decision | Choice | Why |
|---|---|---|
| Distribution | Personal / open-source | GPL dependencies are acceptable; no sandbox required |
| Time-stretch | Rubber Band 4.0 — R3 "Finer" as *Studio*, R2 as *Fast* | Best available open engine; multiresolution and phase-locked, in the class of Ableton Complex Pro. R2 as the fast mode means **one dependency and one code path** rather than a second AVAudioUnit topology with different seek/loop semantics — and R2 already beats `AVAudioUnitTimePitch` on quality |
| Rubber Band binding | C API (`rubberband-c.h`) via SwiftPM `systemLibrary` | Verified present; **no C++ interop shim needed**. `pkg-config` links `-framework Accelerate`, confirming vDSP FFTs on Apple Silicon |
| Decoding | AVFoundation / `AVAssetReader` only | **Verified**: macOS 26 natively decodes MP3, AAC, M4A/MP4, ALAC, FLAC (incl. 24-bit), WAV, AIFF, CAF, AC3, W64, **Ogg Vorbis**, and **Opus**. Zero external decoders, no ffmpeg bundle, hardware-accelerated |
| Playback node | `AVAudioSourceNode` (pull-based) | Sample-accurate looping, instant seek, instant speed change without rescheduling buffers — none of which `AVAudioPlayerNode` gives cleanly |
| UI | SwiftUI, dark-first, time-aligned lanes + collapsible inspector | Lanes are the structure a transcription tool converges on; a spectrum or marker lane cannot live anywhere else and still align with the audio |
| Waveform rendering | SwiftUI `Canvas`, cached layer + cheap overlay | The waveform only changes on viewport change; the playhead changes every frame. Caching the former and overlaying the latter keeps this trivial. Metal is a documented escape hatch behind `TimelineLane` |
| Build | SwiftPM modules + XcodeGen app shell | `.pbxproj` is never committed; ~90% of the code builds and tests under plain `swift test` |
| Keymap default | Left-hand cluster (QWER / ASDF / ZXCV + Space) | The user has an instrument in their hands. Transcribe! needs foot pedals precisely because its keymap assumes two free hands |
| Session state | Visible `.artscribe` sidecar next to the track | Matches Transcribe!'s `.xsc` model; portable, shareable, survives moves when kept alongside |

---

## 3. Architecture

Three execution contexts, eight modules.

```
BACKGROUND (load)          MAIN ACTOR (model & UI)        RENDER THREAD (real-time)
─────────────────          ───────────────────────        ─────────────────────────
AudioDecode                InputBindings                  AVAudioSourceNode
    ↓                          ↓                              ↓
DecodedAudio  ──────────►  ArtscribeKit                   PlaybackEngine
    ↓                      (DocumentModel)                    ↓
Waveform      ──────────►      ↓                          TimeStretch
(PeakPyramid)              ArtscribeUI                    (Rubber Band R3/R2)
                                                              │
                                          reads DecodedAudio ─┘
```

`DecodedAudio` is built once on a background task and is immutable thereafter. Both the
UI (via `Waveform`) and the render thread read it; neither mutates it.

---

## 4. Module reference

| Module | Responsibility | Depends on | Platform deps |
|---|---|---|---|
| `ArtscribeKit` | `TimeRange`, `Viewport`, `Selection`, `LoopRegion`, `SpeedState`, `DocumentModel` | — | none |
| `AudioDecode` | `AVAssetReader` → `DecodedAudio`; `DecodeError` | ArtscribeKit | AVFoundation |
| `Waveform` | `PeakPyramid` build (Accelerate) and query | ArtscribeKit | Accelerate |
| `CRubberBand` | `systemLibrary` target, `pkgConfig: "rubberband"` | — | librubberband |
| `TimeStretch` | `TimeStretcher` protocol; `RubberBandStretcher` (R3/R2) | CRubberBand | — |
| `Playback` | `PlaybackEngine` (headless), `CommandRing`, `AudioOutput` | ArtscribeKit, TimeStretch | AVFAudio (edge only) |
| `InputBindings` | `Action`, `ActionID`, `InputEvent`, `BindingTable`, `ActionDispatcher`, `KeyboardSource` | ArtscribeKit | AppKit (key events) |
| `ArtscribeUI` | `TimelineLane`, `WaveformLane`, `OverviewStrip`, `Ruler`, `Transport`, `Inspector`, `HelpSheet` | all of the above | SwiftUI |

**Boundary rule:** dependencies point one way, left to right in the table. `ArtscribeKit`
imports nothing. `Playback` must not import `ArtscribeUI`. Anything that would require an
upward import is a signal the type belongs in `ArtscribeKit`.

### 4.1 DecodedAudio

```swift
struct DecodedAudio: Sendable {
    let channels: Int
    let sampleRate: Double
    let frameCount: Int
    let storage: AudioStorage   // owns one preallocated planar Float32 allocation
}
```

Planar `Float32`, one allocation, never resized. The render thread reads it through an
`UnsafePointer` with no retain/release traffic.

**Requirement:** `AVAssetReaderTrackOutput` must be configured with an explicit output
setting of `kAudioFormatFlagIsFloat`, 32-bit, non-interleaved. The default path can yield
Int16 and silently discard 8 bits of a 24-bit source — which is exactly the reference
material (24-bit/44.1 FLAC). Covered by a test.

**Memory:** ~200 MB for a 10-minute stereo track (575 s × 44100 × 2 ch × 4 B). Acceptable
on Apple Silicon. For very long files a memory-mapped decode scratch file is the documented
escape hatch; not implemented in the MVP.

### 4.2 Waveform

Multi-resolution min/max peak pyramid: levels at ÷256, ÷1024, ÷4096, ÷16384, ÷65536
samples per bucket, built with Accelerate (`vDSP_minv` / `vDSP_maxv`). Total ≈ N/192
floats — about 600 KB for 10 minutes. Query selects the coarsest level whose bucket size
is ≤ the current samples-per-pixel, then aggregates.

### 4.3 TimeStretch

```swift
protocol TimeStretcher: AnyObject {
    func configure(sampleRate: Double, channels: Int, maxBlock: Int)
    var ratio: Double { get set }        // realtime-safe
    func process(input: UnsafePointer<UnsafePointer<Float>?>, frames: Int, final: Bool)
    func available() -> Int
    func retrieve(into: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, frames: Int) -> Int
    func reset()
}
```

`RubberBandStretcher` wraps the C API in real-time mode with `OptionProcessRealTime`.
`setMaxProcessSize` is called at configure time so no allocation occurs during rendering.
Engine selection is `OptionEngineFiner` (Studio) or `OptionEngineFaster` (Fast); switching
engines rebuilds the stretcher off the render thread and swaps it in via the command ring.

---

## 5. The real-time boundary

The single highest-risk area of the codebase, and deliberately the only place where
cross-thread coordination happens.

**Main actor → render thread:** a lock-free single-producer/single-consumer ring buffer of
small POD command structs — `seek(frame:)`, `setSpeed(ratio:)`, `setLoop(range:enabled:)`,
`setEngine(_:)`. No locks, no allocation, no ARC.

**Render thread → main actor:** a single atomic frame counter. The UI **polls** it on a
display-link tick at refresh rate. The audio thread never pushes, never calls back, never
touches `DocumentModel`.

**Rules inside the render block** (to be restated in `CLAUDE.md`):

- No allocation, no locks, no `async`/`await`, no actor access
- No Swift retain/release — no class instances created or released
- No Objective-C message sends, no Foundation collections
- Rubber Band pre-sized via `setMaxProcessSize` at configure time

Swift 6 strict concurrency will not stop you from capturing an actor in a render block; it
will simply glitch under load. Confining this to one explicit, tested boundary — rather
than letting the convention diffuse — is the primary structural decision in this design.

### 5.1 Seamless looping

On reaching the loop end, `PlaybackEngine` continues feeding the stretcher **across** the
boundary from the loop start rather than resetting it. Resetting flushes the stretcher's
internal overlap state and produces an audible click on every repetition — the single most
important detail for a tool whose core use is listening to the same four bars fifty times.

---

## 6. Interaction model

### 6.1 Principles

- **Zoom anchors on the playhead**, never the viewport centre. This is what makes
  keyboard-only zooming usable.
- **Auto-scroll is page-flip**, suppressed while a loop is active and fits on screen.
  Continuous centred scrolling looks better in a demo and is miserable to transcribe
  against, because the waveform never stops moving.
- **Speed always preserves pitch.** Varispeed is a deferred menu option, not a mode.
- **Every action has a stable `ActionID`.** Menus, keyboard, and later MIDI all dispatch
  the same identifiers, and the help sheet is rendered from the live binding table so it
  cannot drift.

### 6.2 Action catalog (MVP)

| ActionID | Default binding | Action |
|---|---|---|
| `transport.playPause` | `Space` | Play / pause |
| `transport.returnToStart` | `Return` | To selection start, else 0 |
| `transport.nudge.back` / `.forward` | `Z` / `X`, `←` / `→` | Nudge 0.5 s |
| `transport.nudge.back.fine` / `.forward.fine` | `⇧Z` / `⇧X` | Nudge 50 ms |
| `transport.nudge.back.coarse` / `.forward.coarse` | `⌥Z` / `⌥X` | Nudge 5 s |
| `loop.setIn` | `A` | Set loop in at playhead |
| `loop.setOut` | `S` | Set loop out at playhead |
| `loop.toggle` | `D` | Toggle looping |
| `loop.restart` | `F` | Restart loop |
| `loop.fromSelection` | `G` | Selection → loop |
| `speed.down` / `speed.up` | `Q` / `W` | ∓5% |
| `speed.down.fine` / `speed.up.fine` | `⇧Q` / `⇧W` | ∓1% |
| `speed.preset.100/75/50/33` | `1` / `2` / `3` / `4` | Speed presets |
| `speed.engineToggle` | `⌥E` | Studio ⇄ Fast |
| `zoom.out` / `zoom.in` | `E` / `R`, `⌘−` / `⌘=` | Zoom, playhead-anchored |
| `zoom.fit` | `⌘0` | Fit whole file |
| `zoom.toSelection` | `⌘9` | Zoom to selection |
| `selection.extendLeft` / `.extendRight` | `⇧←` / `⇧→` | Extend selection |
| `selection.selectAll` | `⌘A` | Select all |
| `selection.clear` | `Esc` | Clear selection |
| `file.open` | `⌘O` | Open… |
| `view.toggleInspector` | `⌥⌘I` | Toggle inspector |
| `help.shortcuts` | `⌘/` | Help sheet |
| `app.settings` | `⌘,` | Settings |

Pointer input: drag to select, ⇧-drag to extend, double-click to select all, pinch to
zoom, two-finger scroll to pan.

### 6.3 Bindings

`BindingTable` maps `InputBinding` → `ActionID` and is `Codable` to JSON in Application
Support, user-editable. `InputBinding` is an enum with a `keyChord` case in the MVP; MIDI
note and CC cases are added later without touching `Action`, `ActionDispatcher`, or the
help sheet.

---

## 7. Session persistence

A visible `<track>.artscribe` file written next to the audio file, JSON, containing speed,
loop region, loop enabled, viewport, playhead, and active engine. Written on close and
debounced during editing.

If the containing directory is not writable — a read-only volume, a NAS, a mounted image —
fall back to Application Support keyed by file URL, and surface the fallback in the
inspector. Loop points must never be silently lost because a directory was read-only.

---

## 8. Error handling

The rule is **never degrade silently**.

| Failure | Behaviour |
|---|---|
| Unsupported or corrupt file | Inline banner in the window with the real reason; the previously loaded file stays loaded. Not a modal alert |
| Very large file | Decode with progress and cancel. Above ~1.5 GB decoded, warn with the actual figure and let the user choose |
| Sidecar not writable | Fall back to Application Support; indicate the fallback in the inspector |
| Stretcher init failure | R3 → R2 → 1.0× passthrough, each step **visibly** indicated in the transport bar |
| Audio device / route change | Reconfigure the engine, preserving position and speed |

---

## 9. Testing strategy

In priority order. Everything below runs headlessly under `swift test`, with no audio
hardware and no Xcode.

1. **Playback offline harness** — the highest-value tests. `PlaybackEngine` is
   "frames in, frames out", with CoreAudio attached only at the edge, so tests pull frames
   directly and assert:
   - loop wrap lands on the exact expected sample index
   - output frame count matches the speed ratio within tolerance
   - no NaN and no denormals in the output
   - no sample-to-sample discontinuity above threshold at the loop seam
   - a mid-render speed change neither drops nor duplicates frames
2. **Stretch quality regression** — a 440 Hz sine at 0.5×: FFT peak within ±2 cents of 440,
   duration 2× ±1 frame. The only automated check that catches a misconfigured Rubber Band,
   which is otherwise merely audible.
3. **Decode fixtures** — one small generated file per format checked in
   (`sine.{wav,mp3,m4a,flac,ogg,opus}`); assert frame count and RMS against a WAV reference
   within codec tolerance. Includes a **24-bit FLAC** fixture asserting Float32 output
   preserves more than 16 bits of resolution. Doubles as the regression guard on the
   assumption that macOS decodes Ogg Vorbis natively.
4. **Viewport and selection math** — zoom clamping, playhead-anchored zoom, scroll bounds,
   selection arithmetic.
5. **Peak pyramid** — golden values against a naive reference implementation; correct
   decimation level chosen per samples-per-pixel.
6. **Bindings** — `BindingTable` JSON round-trip; no duplicate bindings; every `Action` has
   a display name, so the help sheet can never render a blank row.

**Integration tests** against real material use the album at
`$ARTSCRIBE_TEST_MEDIA_DIR` (locally: the 24-bit/44.1 Wynton Marsalis *Black Codes* FLACs,
~9–11 min each). These are copyrighted and ~1.1 GB, so they are **never** committed; the
tests skip cleanly when the variable is unset, and CI stays green without them.

Not doing: SwiftUI snapshot tests. High maintenance, low signal.

---

## 10. Repo layout and build

```
artscribe/
├── Package.swift          # all modules + tests — `swift test` works standalone
├── project.yml            # XcodeGen → Artscribe.xcodeproj (gitignored)
├── Makefile               # bootstrap · generate · build · test · run
├── CLAUDE.md              # module boundaries, real-time rules, test commands
├── Sources/               # the eight modules of §4
├── App/                   # @main, menu Commands, Info.plist — the only XcodeGen-built part
├── Tests/                 # + Tests/Fixtures/
└── docs/superpowers/specs/
```

`brew install rubberband xcodegen` is the only prerequisite, wrapped by `make bootstrap`.
`CRubberBand` declares `providers: [.brew(["rubberband"])]`. A vendored static build is the
migration path if distribution ever changes.

Everything except `App/` builds and tests under plain `swift test`. This is the concrete
mechanism behind "agent-friendly": a fast, headless, deterministic feedback loop over the
large majority of the code, and no `.pbxproj` in version control to corrupt.

---

## 11. Deferred

Ordered by expected value.

1. **`.xsc` import** — Transcribe! session files are plain line-oriented ASCII
   (`SoundFileName,…`, `Loops,0:`, `SoundFileInfo,…`). A few dozen lines of parsing carries
   existing loops and markers across. High value, low cost; the user has live `.xsc` files.
2. **MIDI input** — a `MIDIInputSource` emitting `InputEvent`, plus note/CC cases on
   `InputBinding`. No changes to `Action`, dispatch, or the help sheet.
3. **Markers lane** — named positions, next/previous navigation.
4. **Pitch shift / transpose** — Rubber Band already supports it; UI and action IDs only.
5. **Spectrum / piano-roll lane** — a new `TimelineLane`; the shared viewport already exists.
6. **EQ and mono/karaoke mixing.**
7. **Varispeed** (pitch follows speed) as a menu option.
8. **ffmpeg conversion fallback** for exotic formats (WMA, MKV/WebM), if `ffmpeg` is on PATH.
9. **Video display.**

---

## 12. Open risks

| Risk | Mitigation |
|---|---|
| Rubber Band R3 CPU cost at extreme ratios on a single core | R2 fast mode is one keystroke away; profile early with a real 10-minute track |
| Swift 6 concurrency vs. a real-time render block | One explicit boundary (§5), rules documented in `CLAUDE.md`, offline harness proves behaviour without hardware |
| `Canvas` redraw cost during continuous zoom | Waveform layer is cached and invalidated only on viewport change; animate with a scale transform during the transition and re-render sharp at the end. Metal is the escape hatch |
| Native Ogg Vorbis support is undocumented and could regress | Covered by a decode fixture test that fails loudly if it disappears |
| 200 MB resident per loaded track | Acceptable on Apple Silicon; memory-mapped decode scratch is the documented fallback for very long files |
