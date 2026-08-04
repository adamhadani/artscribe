# Now Playing — lock-screen controls on iOS

**Date:** 2026-08-04
**Status:** Approved
**Target:** iOS / iPadOS 26+. macOS deliberately unchanged.

---

## 1. Purpose

Artscripture declares `UIBackgroundModes: [audio]` and sets `AVAudioSession`'s category to
`.playback`, so audio keeps running when the screen locks. Nothing tells the system *what*
is playing: `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` appear nowhere in the
codebase. So a locked iPad shows an empty lock screen, and the only way to stop the audio is
to unlock the device and return to the app.

That is the gap this closes. A locked screen should name the track, say how fast it is
playing and whether a loop is running, and offer play/pause and a way back to the top of the
passage.

### 1.1 In scope

- Title, subtitle, elapsed and duration published to `MPNowPlayingInfoCenter`
- Play, pause and toggle
- Skip backward / forward, wired to the app's existing coarse "Rewind / skip" amount
- Skip backward **restarts the loop** when one is enabled

### 1.2 Out of scope, deliberately

- **macOS.** The window is already on screen and the app is keyboard-first. Worse,
  `MPRemoteCommandCenter` is claimed system-wide by whichever app registered most recently —
  a transcription tool silently capturing ⏯ from Spotify is a bug report, not a feature.
- **Scrubbing.** `MPChangePlaybackPositionCommand` stays unregistered, so the progress bar
  displays but does not drag. Dragging into or out of a loop has no obvious right answer and
  this is not the release to invent one.
- **Artwork.** There is no artwork to show. An audio file's embedded art is not read
  anywhere in the app, and adding a decoder for this alone is not worth it.
- **Cue-sheet track names.** The app parses `.cue` sheets and could name the current track
  inside an album file. Considered and dropped: it makes the title change under the user
  mid-passage, and the file name is what they opened.

---

## 2. Architecture

The codebase already has the right shape for this in `AudioSessionPolicy.response(to:wasPlaying:)`:
every rule is a pure function, and the `AVAudioSession` observer only translates notification
payloads into an event vocabulary. The behaviour that is expensive to get wrong on a device is
therefore unit-tested on the Mac it is developed on. This follows that exactly.

| Type | Platform | Responsibility |
|---|---|---|
| `NowPlayingInfo` | **all** | Pure value type. Title, subtitle, elapsed, duration, rate. No `MediaPlayer` import. |
| `NowPlayingCommand` | **all** | Pure. What a remote command *means*, given the loop state. |
| `NowPlayingController` | iOS only | Adapter. Registers commands, writes the info centre, forwards to the model. No policy. |

All three live in `ArtscribeUI`, which builds for iOS as well as macOS. `Playback` cannot own
this: it has no concept of a track title, and it must never reach back into actions.

**The two pure types are not platform-guarded, and that is load-bearing.** A test behind
`#if !os(macOS)` in `ArtscribeUITests` runs on *no platform at all* — `make check` is macOS so
it compiles out, and `ArtscribeUITests` is not in the iOS test bundle. That has already
happened once in this project, and the only clue was a test count that did not move. Only
`NowPlayingController` is guarded.

---

## 3. What is published

```
┌──────────────────────────────────┐
│  Artscripture                    │
│                                  │
│  Black Codes                     │   title    — file name, extension dropped
│  50% · looping 1:23–1:27         │   subtitle — see below
│                                  │
│  ─────●───────────────────────   │
│  1:25                     7:44   │   whole-track position
│                                  │
│      ⟲10      ⏸      ⟳10        │
└──────────────────────────────────┘
```

| Field | Value |
|---|---|
| `MPMediaItemPropertyTitle` | `trackURL.deletingPathExtension().lastPathComponent` |
| `MPMediaItemPropertyArtist` | the subtitle, below |
| `MPMediaItemPropertyPlaybackDuration` | track duration in seconds |
| `MPNowPlayingInfoPropertyElapsedPlaybackTime` | playhead in seconds, clamped to `0...duration` |
| `MPNowPlayingInfoPropertyPlaybackRate` | **the real rate** — see §3.2 |

### 3.1 The subtitle

Speed always; then loop or practice state when either applies.

| State | Subtitle |
|---|---|
| Plain playback | `100%` |
| Slowed | `50%` |
| Loop enabled | `50% · looping 1:23–1:27` |
| Practice ramp running | `65% · practice, rep 4 of 12` |

Speed and loop are exactly what the user cannot see with the screen locked, and both change
while practising. `SpeedRamp` already exposes `isRunning`, `repetition` and `total`, and lives
in `ArtscribeKit`, so the practice case costs no new plumbing.

The ramp case supersedes the loop case rather than adding to it: a ramp always runs on a loop,
so printing both would say the same thing twice in a field with room for one line.

### 3.2 The playback rate is the *real* rate

`MPNowPlayingInfoPropertyPlaybackRate` must be the user-facing speed ratio while playing, and
`0` while paused:

| State | Rate |
|---|---|
| Paused | `0` |
| Playing at 100% | `1.0` |
| Playing at 50% | `0.5` |

The system extrapolates the position between updates from `(elapsed, rate, timestamp)`.
Publishing `1.0` while playing at half speed makes the lock-screen timer run at twice the true
rate and visibly outrun the audio. This is the **speed-ratio-versus-time-ratio** trap already
documented in `CLAUDE.md`, in a new place — and it is the reason §5 mutation-tests this
specifically. Note it is the *speed* ratio (`speed.ratio`), not Rubber Band's time ratio, which
is its reciprocal.

### 3.3 When it publishes

On state change only, never on a timer:

- a track is opened or closed
- play, pause
- seek
- speed change
- loop change — set, cleared, moved, enabled, disabled
- loop wrap
- ramp step

The display link polls the playhead 60 times a second; republishing at that rate would burn CPU
to tell the system something it already extrapolates correctly.

**A loop wrap does republish**, so the scrubber genuinely jumps back on every repetition. That
is honest rather than noisy — it is what the audio is doing — and without it the position would
drift further from the truth on every lap.

---

## 4. The commands

Registered: `playCommand`, `pauseCommand`, `togglePlayPauseCommand`, `skipBackwardCommand`,
`skipForwardCommand`. Everything else is explicitly disabled, including
`changePlaybackPositionCommand`, `nextTrackCommand` and `previousTrackCommand` — an enabled
command with no handler is a button that does nothing.

`preferredIntervals` for both skip commands is the app's **coarse nudge**, the tier already
named "Rewind / skip" in Settings (10 s by default, user-editable). Changing it in Settings
changes the lock screen. There is no second number to keep in sync.

| Button | No loop, or loop disabled | Loop enabled |
|---|---|---|
| ⟲ back | seek −10 s | **`model.restartLoop()`** — the app's existing `F` |
| ⏯ | play / pause | play / pause |
| ⟳ forward | seek +10 s | seek +10 s, leaving the loop |

Inside a four-second loop a ten-second skip-back lands outside the passage the user
deliberately fenced off. What they want without looking is "again, from the top", which the app
already has as one action.

Seeks clamp to the track: a skip-back near the start lands at 0 rather than refusing, and a
skip-forward near the end lands at the last frame rather than stopping playback. This is the
same rule the keyboard's rewind/skip already follows, and the reason skip resolution returns a
*target frame* rather than a delta — the clamping is then one pure function with one test,
not a decision repeated at each call site.

**Known cosmetic imprecision, accepted:** iOS draws the skip button with its interval baked
into the icon (`⟲10`). While a loop is enabled that button restarts the loop, so the digit is
wrong. The alternative — swapping to `previousTrackCommand`, which has no digit — makes the
control row asymmetric, and asymmetry is more noticeable than a stale number on a glyph.

Handlers return `.success`, or `.noSuchContent` when no track is open.

---

## 5. Testing

Everything except the adapter is pure and runs in `make check` on macOS.

| Check | Why |
|---|---|
| Subtitle for each state: plain, slowed, looping, ramping | The one piece of text a user reads |
| **Rate is `0` paused and `speed.ratio` playing** | §3.2. Mutation-test by publishing `1.0` — it must go red |
| Skip-back resolves to restart-loop only when the loop is **enabled**, not merely present | A loop region exists with `isEnabled == false`; treating that as enabled is the plausible bug |
| Skip-back resolves to a seek when there is no loop | The other branch |
| Elapsed clamps to `0...duration` | A playhead past the end publishes a nonsense scrubber |
| Title drops the extension and handles a name with dots | `My.Song.v2.flac` |

**Not** acceptance-tested: the harness drives a macOS window and cannot reach a lock screen.
The device checks join the manual background-audio checklist — in particular that the position
tracks correctly at 50% speed, which is where §3.2 fails visibly if it is wrong.

---

## 6. Risks

**Registering remote commands is process-global and sticky.** Commands stay registered until
explicitly disabled. If the app is backgrounded with no track open, the lock screen should not
show stale information from the previous track — closing a track clears
`nowPlayingInfo` to `nil`.

**`MPNowPlayingInfoCenter` writes are not free.** Building the dictionary allocates. It is
never touched from the render thread; every write happens on the main actor in response to a
state change, which §3.3 bounds.
