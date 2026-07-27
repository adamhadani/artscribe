# Artscribe

A keyboard-first music transcription tool for macOS. Load a track, select a passage,
loop it, and slow it down without changing its pitch — driven almost entirely from the
keyboard, because when you transcribe, your hands are usually on an instrument.

The reference point is [Transcribe!](https://www.seventhstring.com/xscribe/overview.html),
which is functionally excellent and ergonomically dated. Artscribe targets its core loop
with a modern treatment: native Apple Silicon, better time-stretch quality, and an
architecture that admits MIDI pedals and spectral analysis without a rewrite.

**Status: in development, and playable.** Load a file, hear it, select a passage, loop it
seamlessly, and change speed — all from the keyboard.

```sh
make bootstrap
swift run -c release ArtscribeApp
```

Not yet built: a double-clickable `.app` bundle, markers, pitch shift, spectrum analysis,
and MIDI input. See the plan under `docs/superpowers/plans/`.

## Why it sounds better

Slowing audio down without changing pitch is the hard part, and it is where Transcribe!
shows its age. Artscribe uses [Rubber Band](https://breakfastquay.com/rubberband/) 4.0's
**R3 "Finer"** engine — a multiresolution, phase-locked spectral stretcher in the same
class as Ableton's Complex Pro.

Measured pitch error, FFT peak against a reference tone:

| Engine | Mode | At 50% speed | At 200% speed |
|---|---|---|---|
| Rubber Band R3 | Studio (default) | ~0.00 cents | a fraction of a cent |
| Rubber Band R2 | Fast | up to ~26 cents (worst: −25.95 at 300 Hz) | up to **−108 cents** at 220 Hz |

Studio is the default and earns it. Fast exists for low-CPU scrubbing and trades pitch
accuracy for speed — it is not a pitch reference, especially above 1×.

Looping is sample-accurate and feeds the stretcher *continuously across the seam* rather
than resetting it. That detail is the difference between a clean loop and a click on every
repetition: forcing a reset at the boundary produces a 28× discontinuity against the
signal's natural step size.

## Using it

Release, not debug — a debug build decodes roughly four times slower.

### Transport and speed

| Key | Action |
|---|---|
| `Space` | Play / pause |
| `Return` | Play from start (of selection, else the file) |
| `Q` / `W` | Slower / faster (5%) |
| `⇧Q` / `⇧W` | Slower / faster (1%) |
| `1` `2` `3` `4` | 100% / 75% / 50% / 33% |
| `⌥E` | Toggle Studio / Fast engine |
| `↑` / `↓` | Volume up / down |
| `M` | Mute |

### Selection, looping and view

| Key | Action |
|---|---|
| `⌘O` | Open a file (dropping one on the window works too) |
| `A` / `S` | Set loop in / out at the playhead |
| `D` | Toggle looping |
| `F` | Restart the loop |
| `G` | Turn the selection into the loop |
| `R` / `E` | Zoom in / out, anchored on the playhead |
| `X` / `Z` | Pan right / left |
| `⌘0` / `⌘9` | Fit the whole file / zoom to selection |
| `Esc` | Clear the selection |

Drag in the lanes to select, shift-drag to extend, double-click to select all, click to
place the playhead. Pinch to zoom, two-finger scroll to pan. Dragging the overview strip
moves the visible window.

Everything above also appears in the **Playback** menu with its shortcut, along with output
device selection.

## Formats

Everything is decoded natively by macOS — no ffmpeg, no bundled codecs:
MP3, AAC, M4A/MP4, ALAC, FLAC (including 24-bit), WAV, AIFF, CAF, **Ogg Vorbis**, and **Opus**.

## Building

Requires macOS 26+, Xcode 26+ (Swift 6.3), and Apple Silicon.

```sh
make bootstrap   # brew: rubberband, swiftlint, xcodegen, pre-commit (+ installs hooks)
make check       # format check, lint, and the full test suite — the gate for every commit
```

Every module except the app shell builds and tests headlessly under `swift test` — no Xcode
project, no scheme, no audio hardware.

### Tests against real media

Integration tests read `$ARTSCRIBE_TEST_MEDIA_DIR` and **skip cleanly when it is unset**,
so CI stays green without it. Point it at a directory of real music to exercise the
decode, waveform and playback paths at full scale:

```sh
ARTSCRIBE_TEST_MEDIA_DIR=~/Music/SomeAlbum swift test -c release
```

Measure performance in **release**. A debug build is roughly 4× slower and will mislead you.

> Known issue: the full suite hangs when `$ARTSCRIBE_TEST_MEDIA_DIR` is set. `make check`
> is unaffected. Being tracked.

## Architecture

Nine SwiftPM modules across three execution contexts. Dependencies point one way only.

```
BACKGROUND (load)       MAIN ACTOR (model & UI)     RENDER THREAD (real-time)
AudioDecode             ArtscribeUI                 AVAudioSourceNode
    ↓                        ↓                          ↓
DecodedAudio  ─────────► ArtscribeKit               PlaybackEngine
    ↓                        ↓                          ↓
Waveform      ─────────► ArtscribeApp               TimeStretch (Rubber Band)
```

`ArtscribeKit` imports nothing — not even Foundation. The main actor and the render thread
communicate through exactly one boundary: a lock-free SPSC command ring going down, and
atomics the UI polls going up. The audio thread never allocates, never locks, never calls
back, and never touches the model.

Design documents live in `docs/superpowers/specs/` and `docs/superpowers/plans/`;
`CLAUDE.md` carries the working conventions.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

Artscribe links Rubber Band, which is GPL-2.0-or-later, so a distributed binary must be
GPL-compatible. This is a deliberate trade: R3 is the best open time-stretching engine
available, and quality at low speeds is the whole point of the product.
