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
