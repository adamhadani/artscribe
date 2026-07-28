# Artscribe — working notes

A keyboard-first music transcription app for macOS. Load a track, select a passage, loop it,
slow it down without changing pitch.

- Design spec: `docs/superpowers/specs/2026-07-27-artscribe-design.md`
- Implementation plan: `docs/superpowers/plans/2026-07-27-artscribe-audio-core.md`

## Commands

```sh
make bootstrap   # brew: rubberband, swiftlint, xcodegen, pre-commit (+ installs hooks)
make check       # THE GATE: swift-format lint, swiftlint --strict, full test suite
make test        # tests only
swift test --filter <TargetName>    # one module while iterating

swift run -c release ArtscribeApp   # the app

# The acceptance harness: a live window driven through ~600 checks.
swift run -c release ArtscribeAcceptance --list
swift run -c release ArtscribeAcceptance --acceptance <audio> [--bad-file <f>] [--out <dir>] \
    [--only <groups>] [--skip <groups>] [--quick]
```

`make check` must be green before every commit. Pre-commit hooks enforce the same checks, so
a commit that skips them is rejected.

## Acceptance runs — the same rule as the unit suite

Run the **relevant group** while iterating; run the **full harness once** before committing.
It is the acceptance equivalent of `swift test --filter <Target>` during the loop and
`make check` at the end, and it exists because it is worth minutes per iteration:

| Run | Wall clock | Against a full run |
|---|---|---|
| everything | **134 s** | — |
| `--quick` (drops `playback`, `start`) | 96 s | 1.4× |
| `--only transport` | 13.3 s | 10× |
| `--only menu` | 6.2 s | 22× |
| `--only selection` | 4.6 s | 29× |
| `--only loop` | 3.4 s | **40×** |

Measured on 2026-07-28, release build, the same 108 MB FLAC each time. The floor is about
3 s: the load and the window checks in front of the first group always run. `--quick` is the
weakest of these — the two slow groups are only 39 s of the 134 — so prefer `--only`.

- `--list` prints the sixteen groups, what each covers, and roughly how many checks it
  carries. Use it rather than reading `AcceptanceGroups.swift`.
- `--only` and `--skip` take comma-separated names and compose — `--only` chooses the field,
  `--skip` narrows it, `--quick` drops the slow groups from whatever is left.
- **An unknown name is fatal**, and so is a combination that selects nothing. A typo that
  reported success would be worse than useless.
- **A partial run is not an acceptance pass, and cannot exit 0.** Exit 1 is a failure, 2 is
  "nothing failed but not everything was checked" — which now covers both the environment
  skips and the groups a flag left out. The summary names them individually.
- The harness silences itself; see the audio rules below. `--quick` still drives real audio
  in `edge` and `navigation`, just not the long timed sweeps.

## Rules learned the hard way

**Measure in release, never debug.** A debug build decodes roughly 4× slower. Debug numbers
have already produced two false conclusions here — a "6 s" decode that was really 1.5 s, and
a performance panic that evaporated on re-measurement.

**Never `git add -A`.** Several agents share this worktree. Staging everything once swept a
running agent's in-flight work into an unrelated docs commit (`dd03ff4`), whose message
describes 2 files while its contents are 16. Stage explicit paths.

**The spec's action catalog (§6.2) is the source of truth for what exists**, not a task
brief. Three nudge tiers sat documented-but-unimplemented for several tasks because a brief
omitted them and the review checked the implementation against that brief rather than the
spec.

**Observation notifies on `_modify` whether or not the value changed.** Assigning to an
`@Observable` property is compared first and stays silent when the value is equal (measured on
Swift 6.2). Calling a `mutating` method on one *is not* — `_modify` cannot know what the callee
did, so it notifies every time. `transport.poll(…)` on the display link therefore invalidated
`isPlaying` 62 times a second with the track paused, SwiftUI reapplied the Playback menu's items
just as often, and the Output Device submenu never survived long enough for AppKit's submenu-open
delay to elapse. Poll a copy; write it back only if it moved.

**An automated run must never make a sound.** Agents launch this app to check their own
work, on a machine that is usually in a room with a person in it; turning the system volume
down does not help, because the run happens whether or not anyone remembered. So it is
enforced in the audio graph, not by convention: `OutputAudibility` (in `Playback`) is a
process-wide gate that `AudioOutput`'s render block reads, and when it is closed the block
zeroes its output **after** `PlaybackEngine.render` has run. The engine still advances, so
every position-based check still measures the real render thread; `mainMixerNode.outputVolume`
is untouched, so the volume checks still read back the value the user's control asked for.

- `ArtscribeAcceptance` closes the gate itself, twice — in `AcceptanceMain.init` and again
  in `AcceptanceRun.runIfRequested` — and the run asserts `OutputAudibility.shared.isSilenced`
  as its first check. **Do not make this an opt-in flag.**
- To hear an acceptance run on purpose: `ARTSCRIBE_ACCEPTANCE_AUDIBLE=1`.
- To silence any other Artscribe binary — `ArtscribeApp`, `artscribe-cli` — export
  `ARTSCRIBE_SILENT=1`. **Launch the app this way when verifying a change.** Do *not*
  export it for `swift test`: the gate is process-wide, so it silences the deliberately
  audible control in `aSilencedGraphEmitsExactlyZero` and three tests fail. The suite
  renders offline and never reaches a device, so it needs no gate.
- Verified by `aSilencedGraphEmitsExactlyZero`, which renders the real graph offline and
  asserts every sample is exactly 0 against a control that is not.

**Plan code is not pre-verified.** Reviews found well over a dozen genuine defects in
plan-authored code, including three separate silent-truncation bugs. Treat code in a plan as
a proposal to check, not an answer.

## Module boundaries — dependencies point one way only

```
ArtscribeKit ← AudioDecode / Waveform / TimeStretch ← Playback ← ArtscribeUI ← ArtscribeApp
                                                                            ← ArtscribeAcceptance
```

`ArtscribeKit` imports **nothing** — not even Foundation. If a type needs an upward import,
it belongs in `ArtscribeKit`. `Playback` must never import UI. `ArtscribeApp` is the shell
only; the acceptance harness has its own target and must stay out of the product binary.

## Speed vs time ratio

User-facing **speed ratio** (0.5 = half speed) is the reciprocal of Rubber Band's **time
ratio** (2.0 = twice as long). `timeRatio == 1.0 / speedRatio`. The easiest bug to introduce
here, and it is *audible* rather than caught by the type system.

## Real-time rules — `PlaybackEngine.render` and the `AVAudioSourceNode` block

No allocation. No locks. No `async`/`await`. No actor access. No Swift retain/release. No
Foundation collections. No `String` — including in `precondition` messages, so check they
are `@autoclosure`. Rubber Band is pre-sized via `setMaxProcessSize` at configure time so it
never allocates while rendering.

Main actor → render thread is `CommandRing` only. Render thread → main actor is atomics the
UI **polls**. The audio thread never pushes, never calls back, never touches the model.

The position the engine publishes is the **audible** position — already compensated for
stretcher latency and buffered output. Do not add another correction on top.

## Looping — the most important detail in the project

**Never `reset()` the stretcher at a loop boundary.** Feed continuously across it. Resetting
flushes Rubber Band's overlap state and clicks on *every* repetition, in a tool whose whole
purpose is repetition.

Measured, not assumed: forcing a reset at the wrap gives a 0.439 sample-to-sample step
against a signal whose natural maximum step is 0.0157 — a 28× discontinuity. `reset()`
appears in exactly one place, reachable only from seek and EOF-resume.

**The test that guards it is a differential one, not a step threshold.** Because
`feedSource` wraps by feeding continuously, the stream it pushes into the stretcher when
looping `0..<L` is byte-for-byte the stream it pushes when playing a file that already has
that passage laid out end to end. So `rubberBandLoopingIsIndistinguishableFromAContiguousRender`
renders both and compares them in a window around every wrap: measured difference is
**exactly zero** at all eight loop lengths swept (0.2 s to 9.1 s), and a forced `reset()`
at the wrap scores 0.94–1.05 of signal RMS at every one of them.

That replaced a worst-single-sample-step bound, which a sweep showed missing the forced
reset in 5 of 13 realistic loop lengths — a global maximum only sees a click louder than
the material's loudest natural transient, and at L=50003 the reset actually *lowered* the
worst step. Do not go back to a step threshold, and do not "simplify" the control away.

## Audio quality facts

| Engine | Mode | Pitch error at 50% | At 200% |
|---|---|---|---|
| Rubber Band R3 | Studio (default) | ~0.00 cents | fraction of a cent |
| Rubber Band R2 | Fast | up to ~26 cents | up to **−108 cents** |

Studio is the default and earns it. Fast is for low-CPU scrubbing, not pitch reference.

## Formats

Decoded natively by macOS — no ffmpeg, no bundled codecs: MP3, AAC, M4A/MP4, ALAC, FLAC
(incl. 24-bit), WAV, AIFF, CAF, Ogg Vorbis, Opus. `AVAssetReader` must be explicitly
configured for Float32; the default path can return Int16 and silently discard 8 bits of a
24-bit source.

## Test media

Integration tests read `$ARTSCRIBE_TEST_MEDIA_DIR` and **skip cleanly when unset**, so CI is
green without it. Never commit audio over 100 KB — pre-commit enforces this.

Known issue: the full suite hangs when `$ARTSCRIBE_TEST_MEDIA_DIR` is set. `make check` is
unaffected. Root-causing is tracked.

## Testing conventions

- Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest
- Views are not snapshot-tested — extract the pure logic and test that
- A test that cannot fail is worse than none. Verify a new regression test actually fails
  against the defect it targets before trusting it.
