# Artscripture — Design Spec

**Date:** 2026-07-27
**Status:** Approved
**Target:** macOS 26+, Apple Silicon, Swift 6.3

---

## 1. Purpose

A modern music-transcription tool for macOS: load a track, see its waveform, select a
passage, loop it, and slow it down without changing pitch — driven almost entirely from
the keyboard, because the user's hands are usually on an instrument.

The reference point is [Transcribe!](https://www.seventhstring.com/xscribe/overview.html),
which is functionally excellent and visually and ergonomically dated. Artscripture targets its
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
- ~~Collapsible inspector~~ — **cut in Task 25.** It was built in Task 20 and removed one
  task later, and the reason is worth keeping: *the status bar and the transport bar came
  to cover its content.* This line originally asked the inspector to show speed, loop
  points and the active engine; by the time it existed, `StatusBarView` showed all three
  (speed emphasised when it is not 100%, the engine label beside it, loop state tinted
  when active) and the transport bar showed two of them as live controls. That left the
  panel with one page — the shortcut reference — which Task 25 moved into a window of its
  own, and the Practice hub (Task 21), which is better as a window too and costs the
  waveform no width there. An inspector with nothing in it is a menu item that opens an
  empty panel, which is worse than no menu item; the user spotted it. `⌥⌘I` and
  `view.toggleInspector` went with it. **This is a deliberate removal, not a missing
  feature** — if a side panel is ever wanted again, the genuinely non-duplicative content
  is **precise numeric entry** (typing `1:23.456` for a loop point instead of dragging to
  it) plus file info
- Full menu-bar coverage plus a **shortcut window** (`⌘/`) generated from the live action
  catalog: the bindings drawn on a picture of a keyboard, tinted by category, changing
  layer as you hold `⇧`/`⌥`/`⌘`, with a searchable list beside it
- Per-file session persistence via a visible `.artscripture` sidecar

Explicitly out (see §11):

- Pitch shift / transpose, markers, spectrum, note and chord guessing, piano roll,
  EQ, karaoke/mono mixing, video display, MIDI input, `.xsc` import

### 1.2 Success criteria

- A 10-minute 24-bit FLAC opens and renders a full waveform in under 2 s. Measured
  baseline: CoreAudio decodes the 9:35 reference track to Float32 in **1.03 s**
  single-threaded, leaving roughly 1 s of budget for the peak pyramid and first paint
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
| UI | SwiftUI, dark-first, time-aligned lanes; **no side panel** | Lanes are the structure a transcription tool converges on; a spectrum or marker lane cannot live anywhere else and still align with the audio. A collapsible inspector was specified here, built in Task 20 and **cut in Task 25**: the status bar and transport bar had come to carry everything it was for, and anything left that wants a panel (the shortcut reference, the Practice hub) is better as its own window, where it costs the waveform no width |
| Waveform rendering | SwiftUI `Canvas`, cached layer + cheap overlay | The waveform only changes on viewport change; the playhead changes every frame. Caching the former and overlaying the latter keeps this trivial. Metal is a documented escape hatch behind `TimelineLane` |
| Build | SwiftPM modules + XcodeGen app shell | `.pbxproj` is never committed; ~90% of the code builds and tests under plain `swift test` |
| Keymap default | Left-hand cluster (QWER / ASDF / ZXCV + Space) | The user has an instrument in their hands. Transcribe! needs foot pedals precisely because its keymap assumes two free hands |
| Session state | Visible `.artscripture` sidecar next to the track | Matches Transcribe!'s `.xsc` model; portable, shareable, survives moves when kept alongside |

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
| `ArtscribeUI` | `TimelineLane`, `WaveformLane`, `OverviewStrip`, `Ruler`, `Transport`, `ShortcutWindow` (`KeyboardLayout`, `ShortcutLayers`, `ShortcutSearch`) | all of the above | SwiftUI |

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

**Memory:** 194 MB measured for the 9:35 reference track (575 s × 44100 × 2 ch × 4 B). Acceptable
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

**The loop captures on arrival, not on entry.** An explicit seek is always honoured:
playback starts exactly where the user asked, and the loop takes hold only when playback
*reaches* the out point from below. Three cases, matching Ableton and Logic:

| Seek lands | What happens |
|---|---|
| **Before** the loop | Plays from there, runs on, is captured at the out point, then loops |
| **Inside** the loop | Plays from there and loops normally |
| **After** the loop | Plays from there to the end of the file, never wrapping |

The loop is never cleared or disabled as a side effect; `loop.restart` (`F`) is one key
away from being back inside it.

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

**`Space` and `⇧Space` were swapped after first release and swapped back.** Task 28 made
the bare `Space` play-from-start; the user drove that build and asked for the original pair
returned, so `Space` toggles play/pause again and `⇧Space` is the variant of it that starts
from the top. The precedence rule behind play-from-start never changed.

**Preroll.** `transport.prerollToggle` (`H`) flips it on and off, preserving the amount —
distinct from an amount of 0, which is a permanent "resume exactly where I stopped". Shown as
a checkable Playback item and a transport-bar button beside the loop.

**Preroll.** Resuming with `Space` starts from `position − preroll` rather than from exactly
where playback stopped: you stop on a note, and hearing it in context means starting
slightly before it. Default **2 s**, configurable in Settings ▸ Playback in seconds with
fractions, and **0 is an allowed value meaning off** — unlike the nudge amounts, where 0
would be a key that silently does nothing, 0 preroll is a coherent choice and is the
behaviour the app had before the feature. It clamps at the file start, and at an **active**
loop's in point whenever the playhead is inside that loop, so a resume never leaves the
passage the user set. It compounds: pause-resume twice rolls back twice, because each press
is a fresh resume from wherever the playhead now is.

| ActionID | Default binding | Action |
|---|---|---|
| `transport.playPause` | `Space` | Play / pause. A resume rolls back by the preroll (above) |
| `transport.returnToStart` | `⇧Space` | To the selection start; else an **active** loop's in point; else 0 — and play from there. **No preroll**: the target is explicit |
| `transport.nudge.back` / `.forward` | `Z` / `X`, `←` / `→` | Nudge **2 s** (configurable) |
| `transport.nudge.back.fine` / `.forward.fine` | `⇧Z` / `⇧X` | Nudge 50 ms (configurable) |
| `transport.nudge.back.coarse` / `.forward.coarse` | `⌥Z` / `⌥X`, `⌥←` / `⌥→` | Rewind/skip **10 s** (configurable) |
| `loop.setIn` | `A` | Set loop in at playhead |
| `loop.setOut` | `S` | Set loop out at playhead |
| `loop.toggle` | `D` | Toggle looping |
| `loop.restart` | `F` | Restart loop |
| `loop.fromSelection` | `G` | Selection → loop |
| `loop.moveIn.left` / `.right` | `⇧A` / `⇧S` | Move the loop **in** point **250 ms** (configurable) |
| `loop.moveIn.left.far` / `.right.far` | `⌥⇧A` / `⌥⇧S` | Move the loop **in** point **2 s** (configurable) |
| `loop.moveOut.left` / `.right` | `⇧D` / `⇧F` | Move the loop **out** point **250 ms** (configurable) |
| `loop.moveOut.left.far` / `.right.far` | `⌥⇧D` / `⌥⇧F` | Move the loop **out** point **2 s** (configurable) |
| `loop.move.left` / `.right` | `⇧C` / `⇧V` | Move the whole loop, length preserved, **250 ms** (configurable) |
| `loop.move.left.far` / `.right.far` | `⌥⇧C` / `⌥⇧V` | Move the whole loop, length preserved, **2 s** (configurable) |
| `speed.down` / `speed.up` | `Q` / `W` | ∓5% |
| `speed.down.fine` / `speed.up.fine` | `⇧Q` / `⇧W` | ∓1% |
| `speed.preset.100/75/50/33` | `1` / `2` / `3` / `4` | Speed presets |
| ~~`speed.engineToggle`~~ | ~~`⌥E`~~ | **Removed.** Choosing between Rubber Band R3 and R2 was never a user's decision to make — R2 drifts pitch by up to 26 cents at half speed and 108 at the extremes, and it means nothing on iOS, where Rubber Band cannot be linked. Engine selection is developer-only now: Playback ▸ Developer ▸ Stretch Engine, present only under `ARTSCRIBE_DEV_MENU`, and `artscribe-cli --engine`. |
| `zoom.out` / `zoom.in` | `E` / `R` | Zoom, playhead-anchored. `⌘−` / `⌘=` were listed here and never built; they are **not** bound, and the catalog rather than this table is now the record of what is |
| `zoom.fit` | `⌘0` | Fit whole file |
| `zoom.toSelection` | `⌘9` | Zoom to selection |
| `selection.extendLeft` / `.extendRight` | `⇧←` / `⇧→` | Extend selection by the normal nudge amount |
| `selection.moveLeft` / `.moveRight` | `C` / `V` | Move the whole selection **250 ms** (configurable) |
| `selection.moveLeft.far` / `.moveRight.far` | `⌥C` / `⌥V` | Move the whole selection **2 s** (configurable) |
| `selection.selectAll` | `⌘A` | Select all |
| `selection.clear` | `Esc` | Clear selection |
| `file.open` | `⌘O` | Open… |
| `transport.stop` | — | Playback ▸ Stop. Menu only: `Space` already pauses, and a third way to say it would be a key spent on nothing |
| `loop.clear` | — | Loop ▸ Clear Loop. Menu only |
| `view.scrollLeft` / `.scrollRight` | — | View ▸ Scroll. Menu only: `Z`/`X` are the nudge keys and a nudge brings the view with it, so moving the view alone is left to these, the trackpad and the overview strip |
| `file.save` / `file.saveAs` | `⌘S` / `⇧⌘S` | Write the sidecar; write it somewhere else (§7.1) |
| `edit.cut` / `.copy` / `.paste` | `⌘X` / `⌘C` / `⌘V` | The standard pasteboard chords, re-declared because Artscripture **replaces** the standard group. They exist for the numeric fields in Settings |
| `volume.up` / `.down` | `↑` / `↓` | Volume ∓5%, linear in amplitude, default 0.5 |
| `volume.up.fine` / `.down.fine` | `⇧↑` / `⇧↓` | Volume ∓1% |
| `volume.mute` | `M` | Mute, restoring the prior level |
| `file.openRecent` | — | File ▸ Open Recent, 8 entries, de-duplicated by resolved path |
| `transport.preroll` | — | How far a `Space` resume rolls back; **in Settings ▸ Playback**, seconds with fractions, default **2 s**, `0` allowed and means off. No key of its own: it is a property of `transport.playPause`, not an action |
| `view.zoomDragDirection` | — | Invert zoom direction; **in Settings ▸ Playback**, and it governs the ruler drag, the ⌥-drag and the wheel alike |
| `view.theme` | — | Light / Dark / System; **in Settings ▸ Appearance**, consolidated there from the View menu |
| `practice.show` | `⌘P` | Open the **Practice** window — the ramping loop (Task 21). A separate, resizable window whose frame is remembered, closable on its own, for a sharper version of `help.shortcuts`'s reason: it is watched *alongside* the waveform, so it must cost the waveform no width. `⌘P` is free — this app has no Print command |
| `practice.ramp.toggle` | `⌥P` | Start / stop the speed ramp, in **Loop ▸ Speed Ramp**, without leaving the waveform. Pairs with the window's `⌘P` on the same letter: `⌘` opens the thing, `⌥` runs it |
| `help.shortcuts` | `⌘/` | Open the **Keyboard Shortcuts** window — a separate, resizable window whose frame is remembered, closable on its own. Not a toggle: it has a close button and answers ⌘W |
| `app.settings` | `⌘,` | Settings — in the **app menu** (Artscripture ▸ Settings…), the macOS convention since Ventura, wired automatically by SwiftUI's `Settings` scene |

**A nudge may leave an active loop region.** All three tiers move the playhead freely, loop
or no loop, matching Transcribe!: the tier you reach for when the phrase starts a beat
earlier than you set the in point is exactly the one that has to be able to cross the
boundary. The loop itself is untouched — still set, still enabled — and `F`
(`loop.restart`) is one key away when you want to be back inside it. Nudging is otherwise
transport-neutral: it works stopped or playing, and pushes nothing but `seek`, so it never
starts, stops or restarts playback.

**The loop-move keys, and why they are these.** `A S D F` is the loop row and already reads
left to right, so the *left* pair drives the loop's *left* (in) edge and the *right* pair
its *right* (out) edge, and within each pair the left key moves left. `⇧` is what turns
"set this edge at the playhead" into "nudge it from where it is". `⇧C`/`⇧V` then move the
whole loop, on the very keys that already move the whole selection — the keyboard
equivalent of the loop *body* that §6.1's pointer catalog makes draggable, and of the
selection body it deliberately does not. `⌥` still means "the bigger step" and therefore
*adds* to the chord rather than replacing the `⇧`. The whole cluster stays under the left
hand, so the right one can stay on the mouse.

**The loop moves share the selection's two amounts**, rather than carrying a third and
fourth preference. Nudging a region into place is one job with one pair of sizes — a touch
and a lot — and it is the same job whether the region is the passage you are looking at or
the one you are hearing. Settings edits both at once.

**Loop edges swap rather than invert**, by keyboard exactly as by pointer: pushing the in
point past the out point hands over to the other edge and keeps going. The keyboard calls
the same function the drag does, so the two cannot drift. A whole-loop move clamps as a
unit at either end of the file, keeping its length rather than shrinking against the wall.

**The Practice hub (Task 21), and the three decisions inside it.** The ramping loop is
stated as *start speed*, *end speed* and *number of repetitions*, and the per-repetition
delta is computed — not as "add a fixed percentage each pass", which was the first form of
the idea. The three-number form is strictly better because it is stated in the terms the
practice session actually has: where I start, where I need to get to, and how long I am
prepared to spend. The delta divides by `repetitions − 1`, so both endpoints are played;
dividing by `repetitions` would give a last pass at 95% and never reach the tempo the whole
exercise aimed at. An **end below the start** is a first-class case — practising by
progressively slowing down is a real thing musicians do — so nothing in the schedule assumes
ascent.

It **advances on the loop wrap, never on a timer**. A timer needs a duration derived from
the loop length and the speed ratio, and this is the one feature that changes both of those
underneath itself. The wrap is read out of the audible position the UI already polls, so no
new channel crosses the render-thread boundary (§5). The detector requires the *middle* of
the loop to have been visited between wraps as well as a backward jump: a ratio change
briefly mis-scales the engine's in-flight backlog, which makes the reported position step
back over the boundary it has just crossed, and without that condition one lap is counted as
two. Measured, at 50% → 75% on a four-second loop — see `LoopWrapTracker`.

At the end it **holds the final speed and leaves the transport running**. A ramp is a speed
automation, not a transport: it does not own the play state, it was very likely started while
something was already playing, and the end of a ramp is the moment you have arrived at the
passage, at tempo, in the loop — which is what the exercise was for. The completion is stated
in the window rather than left to be inferred from a speed that stopped changing.

**Note on ⇧, which is deliberately inconsistent between the two nudge bindings.** On the
arrow keys ⇧ *extends the selection*, following the macOS text-editing convention every Mac
user already has. On `Z`/`X` it means *finer increment*, matching `⇧Q`/`⇧W` in the speed
cluster. This is intentional: the arrows belong to the system-conventions layer and the
left-hand cluster belongs to the ergonomic layer, and each is internally consistent. It is
recorded here so it is not later "fixed" as an oversight.

**Pointer input.** The full catalog, since it is now large enough that "drag to select" no
longer covers it. Everything that zooms anchors on the frame under the pointer; the keyboard
zoom is the only one that anchors on the playhead.

| Gesture | Where | Action |
|---|---|---|
| Left-drag | Lanes | Select a passage. **The core gesture — not negotiable** |
| ⇧ left-drag | Lanes | Extend the selection, keeping its anchor |
| Click | Lanes | Place the playhead, clear the selection |
| Double-click | Lanes | Place the playhead there **and play from it** — never re-routed to a selection or loop start (`⌘A` remains Select All) |
| **⌥ left-drag, vertically** | **Lanes** | **Zoom, smooth and continuous, anchored at the drag's start** |
| **Left-drag, vertically** | **Time ruler** | **The same zoom, with no modifier — Ableton's and Melodyne's ruler convention** |
| Click / drag | Overview strip | Centre the viewport there |
| Pinch | Anywhere | Zoom |
| Wheel (coarse deltas) | Anywhere | Zoom |
| Two-finger scroll (precise deltas) | Anywhere | Pan |
| ⌘ + scroll | Anywhere | Zoom on either device, at **⅓ the bare rate** — the careful gear |
| ⇧ + scroll | Anywhere | Pan on either device, so a plain mouse can still pan |

Drag-to-zoom is **up to zoom in, down to zoom out**, and is anchored on the pointer's
horizontal position when the drag began, so the frame under the cursor holds still for the
whole gesture. Horizontal travel during it is ignored rather than panning as Ableton's ruler
does: holding the anchor still is the gesture's contract, and panning at the same time — or
any sideways wobble during what the hand meant as a vertical drag — would break it. What a
lane drag *means* is decided when the mouse goes down and held for the gesture's life, so a
modifier pressed or released halfway through can never silently convert a selection into a
zoom or the reverse.

**Pointer affordances.** None of the drags above is visible, and an affordance nobody can
see is not one, so the cursor names what the region under it can do. Three shapes, and no
more — a cursor that changed everywhere would stop meaning anything:

| Region | Cursor | What it says |
|---|---|---|
| Time ruler | `rowResize` (up/down arrows) | This can be dragged, and vertically |
| Waveform lanes | `rectSelection` (crosshair) | Drag out a passage |
| Waveform lanes, ⌥ held | `zoomIn` (magnifier) | This drag changes the zoom |

Everything else — the overview strip, the transport bar, the status bar — keeps the ordinary
arrow. The lanes' cursor follows ⌥ **live**, changing under a pointer that has not moved, so
the modifier is discoverable before the user has committed to a drag rather than after. Once
a drag is in flight the *latch* wins over the modifier: an ⌥-drag that outlives the ⌥ that
began it keeps the magnifier, because it is still zooming.

### 6.3 Bindings

`BindingTable` maps `InputBinding` → `ActionID` and is `Codable` to JSON in Application
Support, user-editable. `InputBinding` is an enum with a `keyChord` case in the MVP; MIDI
note and CC cases are added later without touching `Action`, `ActionDispatcher`, or the
shortcut reference.

**Its foundation exists as of Task 20 and rebinding does not.** `ActionCatalog` is one
list of (`ActionID`, title, category, default chords, menu placement) that the menu
builders, the window's key handler and the shortcut reference all read; `MenuPlan`
describes the menu bar as data and the menus render it. A shortcut therefore cannot be
changed in one place and left stale in another, and `ActionCatalogTests` asserts that
every catalog action appears in exactly one menu and that no menu item exists outside the
catalog. What is still deferred is the *rebinding* — a persisted `BindingTable` replacing
the fixed reverse index in `KeyBindings`, and nothing else.

**There is no separate modal help sheet, and there should not be one.** §6.2 listed
`help.shortcuts` as a modal sheet and it was never built. Task 20 made it an inspector
page; Task 25 made it **its own window**, because a reference you keep open while you
learn a keymap cannot live in a panel that takes width from the waveform. There is still
exactly one shortcut surface — two overlapping ones is the arrangement that lets one of
them drift — and it is generated from `ActionCatalog`, so it cannot show a binding the app
does not have. `⌘/` keeps its binding and opens that window.

**The window is a keyboard, not a list.** Every bound key is drawn in place, tinted by
category, with its action named under the glyph; unbound keys are dimmed. The keymap has
base, `⇧`, `⌥`, `⌥⇧` and two `⌘` layers and one keyboard cannot show them, so **holding a
modifier changes the layer live** — which teaches the keymap the way using it does. A
layer can also be pinned from a picker, for anyone who cannot hold two keys at once; that
is an accessibility requirement and not a nicety. A filter field narrows the keyboard and
the list beside it together, and the list includes actions with no shortcut (Stop, Clear
Loop, the two Scroll items) rather than pretending they do not exist.

---

## 7. Session persistence

A visible `<track>.artscribe` file written next to the audio file, JSON, containing speed,
loop region, loop enabled, viewport, playhead, and active engine. Written on close and
debounced during editing.

If the containing directory is not writable — a read-only volume, a NAS, a mounted image —
fall back to Application Support keyed by file URL, and **surface the fallback**. Loop
points must never be silently lost because a directory was read-only. It is shown as a
standing inline banner in the document window, beside the decode and device notices —
Task 20 put it in the inspector's chrome and Task 25 rehomed it when the inspector was
cut. What this requires is that the fallback be *visible*, not that it live in a
particular container.

### 7.1 Save, Save As, and the close prompt

The sidecar behaves the way modern macOS treats a document that has a location: **once
`<track>.artscribe` exists it is kept up to date** — written a couple of seconds after an edit
and again on close — so nothing has to be saved by hand. **⌘S** is therefore a checkpoint that
writes immediately rather than waiting, and **⇧⌘S** is Save As.

What Artscripture will not do is create that file unasked, because it lands in the user's music
folder where they can see it. So the first time a track with no session file is edited,
leaving it — closing the window, quitting, or loading another track — asks **Save / Don't Save
/ Cancel**, and Cancel really cancels. After the file exists it never asks again.

This resolves the tension between "written on close and debounced during editing" above and a
classic save prompt, which cannot both hold for the same document state: a file that always
matches the working state has nothing to prompt about. The macOS rule — ask about a document
with no location, autosave one that has a location — keeps both halves meaningful.

**An edit is speed, stretch engine, or loop.** The playhead, the viewport and the selection
are persisted but never mark the document modified: they are where you are looking, not a
decision about the track, and a playhead that ticks sixty times a second would leave the
window permanently modified and the prompt meaningless.

**Save As** writes wherever it is pointed. Pointed at the canonical `<track>.artscribe` it
adopts that file as the live session; anywhere else it writes a **copy** for sharing or
archiving and says so, because reopening the track only ever looks beside the track. The
sidecar is named by appending to the whole file name — `Blackbird.flac.artscribe` — so two
encodings of one song in one folder cannot overwrite each other's loop points.

**The JSON is user-editable by design, so it is never trusted.** Every field decodes
independently and is clamped into the loaded recording; a field that cannot be read falls back
to its default and is named to the user. A malformed sidecar opens the track on defaults and
says so — it never crashes, hangs, or installs a nonsensical state.

---

## 8. Error handling

The rule is **never degrade silently**.

| Failure | Behaviour |
|---|---|
| Unsupported or corrupt file | Inline banner in the window with the real reason; the previously loaded file stays loaded. Not a modal alert |
| Very large file | Decode with progress and cancel. Above ~1.5 GB decoded, warn with the actual figure and let the user choose |
| Sidecar not writable | Fall back to Application Support; indicate the fallback as a standing inline banner in the document window, alongside the decode and device notices, which cannot be dismissed while the condition holds (`SessionFallbackBanner`) |
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
├── project.yml            # XcodeGen → Artscripture.xcodeproj (gitignored)
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
3. **Stem separation** — run an ML separator (HTDemucs or similar) to split the track into
   drums/bass/vocals/other, then stretch each stem independently and remix. Two reasons this
   is worth real investment: transient smearing is worst when percussion and sustained
   instruments share spectral bins, so separating them removes the conflict at its source;
   and soloing an individual stem is independently one of the most useful things a
   transcriber can do. Uses ML where it is strong (separation) rather than where it is weak
   (resynthesis) — a generative stretcher that invents plausible detail is disqualifying
   here, because the user would be transcribing the model's invention.

   **Architectural constraints this places on the MVP** (see §5 and the note in Task 8):
   - `PlaybackEngine` must read source audio through a single, replaceable accessor rather
     than scattering `DecodedAudio.channel(_:)` calls through the render path. Swapping one
     buffer for N stem buffers should touch one place.
   - All stems must be driven with **identical ratios and identical frame counts every
     render quantum**. Independent stretchers fed slightly different amounts will drift out
     of sample alignment, and the result is phasing — the failure mode is subtle and
     cumulative, not immediately obvious.
   - CPU scales with stem count. Four R3 instances is a very different budget from one;
     expect to need R2 for unfocused stems, or to pre-render.
   - Separation is offline and slow (tens of seconds for a 10-minute track). It needs the
     same background-task, progress, and breadcrumb treatment as decoding, plus a disk cache
     keyed off the source file so it runs once per track, not once per open.

4. **Markers lane** — named positions, next/previous navigation.
5. **Pitch shift / transpose** — Rubber Band already supports it; UI and action IDs only.
6. **Spectrum / piano-roll lane** — a new `TimelineLane`; the shared viewport already exists.
7. **EQ and mono/karaoke mixing.**
8. **Varispeed** (pitch follows speed) as a menu option.
9. **ffmpeg conversion fallback** for exotic formats (WMA, MKV/WebM), if `ffmpeg` is on PATH.
10. **Video display.**

---

## 12. Open risks

| Risk | Mitigation |
|---|---|
| Rubber Band R3 CPU cost at extreme ratios on a single core | R2 fast mode is one keystroke away; profile early with a real 10-minute track |
| Swift 6 concurrency vs. a real-time render block | One explicit boundary (§5), rules documented in `CLAUDE.md`, offline harness proves behaviour without hardware |
| `Canvas` redraw cost during continuous zoom | Waveform layer is cached and invalidated only on viewport change; animate with a scale transform during the transition and re-render sharp at the end. Metal is the escape hatch |
| Native Ogg Vorbis support is undocumented and could regress | Covered by a decode fixture test that fails loudly if it disappears |
| 200 MB resident per loaded track | Acceptable on Apple Silicon; memory-mapped decode scratch is the documented fallback for very long files |
