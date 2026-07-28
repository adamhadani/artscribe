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
make app && open .build/xcode/Build/Products/Release/Artscribe.app
```

Not yet built: markers, pitch shift, spectrum analysis, and MIDI input. See the plan under
`docs/superpowers/plans/`.

## Running Artscribe

There are two ways in, and they are for different people.

### `make app` — to use it

```sh
make app
open .build/xcode/Build/Products/Release/Artscribe.app
```

That produces `Artscribe.app`: a real, double-clickable bundle with an icon, a version, and
a bundle identifier. Drag it to `/Applications` or `~/Applications` and it behaves like any
other Mac app — it appears in Finder's **Open With** for every format it decodes, and a
file dropped on its dock icon opens in it.

`make dist` wraps the signed bundle in `dist/Artscribe-<version>.zip` for handing to
somebody else.

`project.yml` is the source of truth for the bundle. The `Artscribe.xcodeproj` that
XcodeGen generates from it is disposable and gitignored — never edit or commit it. The app
icon is likewise generated, from `App/GenerateIcon.swift`.

### `swift run` — to work on it

```sh
swift run -c release ArtscribeApp
```

No Xcode project, no bundle, no signing. Every module except the app shell also builds and
tests headlessly under `swift test`. Bundling is an additional path, not a replacement:
`make check` never touches Xcode.

Release, not debug — a debug build decodes roughly four times slower.

> An unbundled `swift run` binary is not an app bundle, so macOS starts it as an accessory.
> The app asks for the regular activation policy at startup to get its menu bar and keyboard
> focus back. It also never receives Launch Services open events, so "Open With" and dock
> drops only work from the bundle.

### What it links, and where that runs

Artscribe links [Rubber Band](https://breakfastquay.com/rubberband/) and, through it,
libsamplerate. Both come from Homebrew at build time, and **`make app` copies them into
`Artscribe.app/Contents/Frameworks`** and repoints the binary's load commands at
`@rpath`, so the finished bundle does not need Homebrew on the machine that runs it. The
build fails rather than shipping a bundle that still references anything outside itself —
see `App/embed-dependencies.sh`.

Their licences travel with them, in `Contents/Resources` alongside Artscribe's own.

Apple Silicon only. Homebrew ships arm64-only libraries and the project has never been an
Intel product, so the bundle is built `arm64` rather than universal.

### Signing

`make app` signs the bundle **ad-hoc** (`codesign --sign -`). That is enough to run it on
the machine that built it, and enough for anyone who copies it across by hand.

It is *not* enough for a download. A zip fetched from the internet arrives with a quarantine
flag, and Gatekeeper rejects an ad-hoc signature outright — `spctl --assess` says
`rejected`, and the recipient sees "Artscribe cannot be opened". They can get past it with
right-click ▸ **Open**, or `xattr -d com.apple.quarantine Artscribe.app`, but they should
not have to.

Doing it properly needs an Apple Developer account, which this project does not have. With
one, the additional steps would be:

1. A **Developer ID Application** certificate in the login keychain, and
   `CODE_SIGN_IDENTITY` in `project.yml` set to it instead of `-`.
2. **Hardened runtime on** (`ENABLE_HARDENED_RUNTIME: YES`). The entitlements file already
   carries `com.apple.security.cs.disable-library-validation`, which a hardened process
   needs before it will load the embedded Homebrew dylibs; without it they would have to be
   re-signed with the same Team ID.
3. Every embedded dylib signed with that same identity, inside-out, before the bundle —
   which is the order `App/embed-dependencies.sh` already uses.
4. **Notarisation**: `xcrun notarytool submit dist/Artscribe-<version>.zip --wait` with an
   app-specific password or an App Store Connect API key, then `xcrun stapler staple
   Artscribe.app` and re-zip so the ticket travels with the app.

None of that has been attempted here, and none of it is wired into the Makefile.

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
| `⇧Space` | Play from start (of selection, else the file) |
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
| `Z` / `X` | Nudge the playhead back / forward (2 s, configurable) |
| `⇧Z` / `⇧X` | Nudge finely (50 ms) — `⌥Z` / `⌥X` rewind and skip (10 s) |
| `⌘A` | Select the whole file |
| `⇧←` / `⇧→` | Extend the selection |
| `C` / `V` | Move the whole selection left / right (250 ms, configurable) |
| `⌥C` / `⌥V` | Move it further (2 s, configurable) |
| `⌘0` / `⌘9` | Fit the whole file / zoom to selection |
| `Esc` | Clear the selection |

Drag in the lanes to select, shift-drag to extend, double-click to select all, click to
place the playhead. Pinch to zoom, two-finger scroll to pan. Dragging the overview strip
moves the visible window. **Drag down** on the time ruler — or ⌥-drag in the waveform — to
zoom in smoothly; Settings ▸ Playback ▸ *Invert zoom direction* reverses that and the scroll
wheel together.

Every shortcut above also appears beside its item in the menus — selection in **Edit**,
looping in **Loop**, the transport, speed, volume and output device in **Playback**.

## Formats

Everything is decoded natively by macOS — no ffmpeg, no bundled codecs:
MP3, AAC, M4A/MP4, ALAC, FLAC (including 24-bit), WAV, AIFF, CAF, **Ogg Vorbis**, and **Opus**.

## Building

Requires macOS 26+, Xcode 26+ (Swift 6.3), and Apple Silicon.

```sh
make bootstrap   # brew: rubberband, swiftlint, xcodegen, pre-commit (+ installs hooks)
make check       # format check, lint, and the full test suite — the gate for every commit
make app         # the double-clickable Artscribe.app
make dist        # a zip of the signed bundle
```

Every module except the app shell builds and tests headlessly under `swift test` — no Xcode
project, no scheme, no audio hardware. See **Running Artscribe** above for which path to
use when.

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
