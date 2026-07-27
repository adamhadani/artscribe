# Artscribe

A keyboard-first music transcription tool for macOS. Load a track, select a passage,
loop it, and slow it down without changing its pitch — driven almost entirely from the
keyboard, because when you transcribe, your hands are usually on an instrument.

The reference point is [Transcribe!](https://www.seventhstring.com/xscribe/overview.html),
which is functionally excellent and ergonomically dated. Artscribe targets its core loop
with a modern treatment: native Apple Silicon, better time-stretch quality, and an
architecture that admits MIDI pedals and spectral analysis without a rewrite.

**Status: in development.** The audio core works and is covered by tests. The first window —
a waveform viewer with no sound yet — runs today:

```sh
swift run -c release ArtscribeApp
```

## Why it sounds better

Slowing audio down without changing pitch is the hard part, and it is where Transcribe!
shows its age. Artscribe uses [Rubber Band](https://breakfastquay.com/rubberband/) 4.0's
**R3 "Finer"** engine — a multiresolution, phase-locked spectral stretcher in the same
class as Ableton's Complex Pro.

Measured pitch error at half speed, FFT peak against a 440 Hz reference:

| Engine | Mode | Pitch error |
|---|---|---|
| Rubber Band R3 | Studio (default) | ~0.00 cents |
| Rubber Band R2 | Fast | frequency-dependent, up to ~26 cents (worst found: -25.95 at 300 Hz) |

Studio is the default. Fast exists for low-CPU scrubbing and trades pitch accuracy for speed.

## Running the viewer

`swift run -c release ArtscribeApp` opens a window. Release, not debug: a debug build
decodes roughly four times slower.

| Key | Action |
|---|---|
| `⌘O` | Open a file (dropping one on the window works too) |
| `R` / `E` | Zoom in / out, anchored on the playhead |
| `X` / `Z` | Pan right / left |
| `⌘0` | Fit the whole file |
| `⌘9` | Zoom to the selection |
| `Esc` | Clear the selection |

Drag in the lanes to select, shift-drag to extend, double-click to select all, click to
place the playhead. Pinch to zoom and two-finger scroll to pan. Dragging the overview
strip moves the visible window. There is no playback yet.

## Formats

Everything is decoded natively by macOS — no ffmpeg, no bundled codecs:
MP3, AAC, M4A/MP4, ALAC, FLAC (including 24-bit), WAV, AIFF, CAF, **Ogg Vorbis**, and **Opus**.

## Building

Requires macOS 26+, Xcode 26+ (Swift 6.3), and Apple Silicon.

```sh
make bootstrap   # brew: rubberband, swiftlint, xcodegen, pre-commit (+ installs hooks)
make check       # format check, lint, and the full test suite
```

Everything except the (not yet written) app shell builds and tests headlessly under
`swift test` — no Xcode project, no scheme, no audio hardware.

### Tests against real media

Integration tests read `$ARTSCRIBE_TEST_MEDIA_DIR` and **skip cleanly when it is unset**,
so CI stays green without it. Point it at a directory of real music to exercise the
decode and waveform paths at full scale:

```sh
ARTSCRIBE_TEST_MEDIA_DIR=~/Music/SomeAlbum swift test -c release
```

Measure performance in **release** mode. A debug build is roughly 4x slower and will
mislead you.

## Architecture

Eight SwiftPM modules across three execution contexts. Dependencies point one way only.

```
BACKGROUND (load)       MAIN ACTOR (model & UI)     RENDER THREAD (real-time)
AudioDecode             InputBindings               AVAudioSourceNode
    ↓                        ↓                          ↓
DecodedAudio  ─────────► ArtscribeKit               PlaybackEngine
    ↓                        ↓                          ↓
Waveform      ─────────► ArtscribeUI                TimeStretch (Rubber Band)
```

`ArtscribeKit` imports nothing. The main actor and the render thread communicate through
exactly one boundary: a lock-free command ring going down, and a single atomic frame
counter polled going up. The audio thread never allocates, never locks, and never touches
the model.

Design documents live in `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

Artscribe links Rubber Band, which is GPL-2.0-or-later, so a distributed binary must be
GPL-compatible. This is a deliberate trade: R3 is the best open time-stretching engine
available, and quality at low speeds is the whole point of the product.
