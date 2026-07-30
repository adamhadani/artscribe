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
| everything | **188 s** | — |
| `--quick` (drops `playback`, `start`, `practice`) | 96 s | 1.7× |
| `--only transport` | 13.3 s | 12× |
| `--only practice` | 23 s | 7× |
| `--only menu` | 6.2 s | 27× |
| `--only selection` | 4.6 s | 36× |
| `--only loop` | 3.4 s | **48×** |

Measured on 2026-07-28, release build, the same 108 MB FLAC each time; the full-run figure is
from 2026-07-29, after the checks below started actually running. The floor is about 3 s: the
load and the window checks in front of the first group always run. `--quick` is the weakest
of these — the three slow groups are only ~65 s of the total — so prefer `--only`.

**The run needs the audio file, and it takes the front.** `--acceptance <audio>` is not
optional: given only `--only`, the harness opens its window and parks in the AppKit run loop
forever — no output, no error, no timeout. And it now calls
`NSApp.activate(ignoringOtherApps: true)`, so it *will* come to the foreground and take the
keyboard for the pointer, cursor, edge and transport groups. That is what makes those checks
real rather than skipped; it also means the run is not something to launch while typing
elsewhere. Redirect to a file rather than piping through `tail`, which buffers away progress.

- `--list` prints the seventeen groups, what each covers, and roughly how many checks it
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

**Match the fix to the tool.** Small contained changes — a layout tweak, a one-file fix, a
doc correction — should just be made. Spawning a subagent costs 20–80 minutes and 200–400k
tokens because it re-reads this file, re-establishes context, runs the acceptance harness and
writes a report; for a one-line change that overhead dwarfs the work. Six dispatches went into
the keyboard-shortcut window, more than the entire audio engine. Batch several pieces of
feedback into one pass rather than one dispatch each.

**Ask how UI should look before building it.** The shortcut reference was built as an
inspector page, shown, and rebuilt as a separate window — a whole task discarded because
nobody asked first.

**Check you can verify before you build.** Four fixes to that window were made blind, because
`NSApp.activate()` silently fails from a background shell and no window could become key
(`activate(ignoringOtherApps: true)` works). Blind fixes address symptoms and leave causes.

**The harness must come to the front, with `ignoringOtherApps: true`.** The line above was
written down and then not applied on the acceptance path: `regainKeyWindow` called the plain
`activate()`, spun its thirty attempts, gave up, and **seventeen** pointer, cursor and
edge-drag checks skipped themselves on every run for want of one argument. The transport
group had the same fault by another route. Fixing both took the full run from
`0 failures, 17 NOT CHECKED` to `0 failures, every group ran` — 704 checks, exit 0.

**A check that asserts a return to the prior state passes when nothing happened at all.**
`pressing Zoom Out zooms back out` asserted `framesPerPixel >= fitted`, and read green
through an entire run in which not one click was delivered. Assert the **transition**
(`after > before && after >= fitted`), and print both numbers in the check's name — the
`19821.6 -> 19821.6` in a skipped line is what makes a dead path obvious at a glance.

**A red acceptance run is more often the harness than the app — check that first.** On
2026-07-30 two separate failures were escalated as product bugs and both were the harness. A
"99% CPU freeze" was `nohup`: launched in the background the app can never come to the front,
so `regainKeyWindow`'s retries and `activate(ignoringOtherApps:)` spin forever — the identical
command in the foreground finished in 237 s. And eleven failures headed by `0 wraps observed
over 18 s`, the signature of the *one* feature already proven by a differential render test,
never reproduced in isolation. Two cheap discriminators, in order: **run the group alone**
(`--only playback` is 37 s — passing alone but failing in the full run means ordering, timing
or environment, not the feature), and **run the same groups at the merge-base** (byte-identical
failures mean it is not your change). Then ask the user; "looping is fine, I use it daily"
outweighed two `sample` traces here.

**A check that hard-codes a magnitude is betting on its input.** `checkAutoScroll` zoomed
`for _ in 0..<14 { press(.r) }` for "a page a few seconds wide". Fourteen steps give 2.27 s on
a short track and **25.6 s** on a seventy-minute album; the check then watched 6 s for a flip
that needed ~22 s, and reported "the view did not follow the playhead" — blaming the app for
its own arithmetic, on every run against album-length input. Drive to a **measured target**
instead, and print what was reached (`2.27 s after 21 zoom steps`) so a changed zoom step
surfaces as a number rather than a mystery.

**`model.playhead` is not the engine's position.** It is polled by `PlayheadClock`'s
`CADisplayLink` on `NSScreen.main`. If that link stops — display asleep — the value freezes
while audio renders normally at 130%+ CPU on CoreAudio threads, and every position-based check
fails while nothing is wrong. If the position cluster ever goes red again, assert
`PlayheadClock.isRunning` and **skip** rather than fail.

**Deliverability is a fact about the machine; never infer it from the result.** A press that
does nothing must fail on a machine that *can* deliver presses, or a broken button excuses
itself. Ask `screenIsLocked()` and `NSApp.isActive`, collect "did any press land" across
*all* the presses rather than the first, and skip only when nothing landed **and** the
session cannot deliver.

**Sample the resting state before claiming a signal.** The menu-strobe check compared an
absolute count against zero. Once the app was properly frontmost it emerged that performing
*any* key equivalent — ⌘0 as much as a plain letter — leaves `highlightedItem` set for the
duration: resting 0/20, every chord 20/20. The check now measures against ⌘0, and menu
*opening* (`didBeginTracking`) is what it guards.

**Anything a control changes belongs in the harness's fingerprint.** `activate` treats
"nothing landed" as licence to try the next delivery path, so a press the fingerprint could
not see got silently delivered twice. `prerollEnabled` was missing, and every preroll press
read as not landing *while it was working*.

**Let SwiftUI catch up before clicking.** `activate` settles first. A press that races the
render pass hits a button still drawn **disabled** — a disabled SwiftUI button swallows the
click in silence — and the loop button read as broken for a whole run purely because
`loopFromSelection()` had given it a region the view had not yet been told about.

**Mutation-test the harness, not just the unit suite.** Three deliberate defects — the loop
button's action removed, the preroll button's action removed, the edge drag ignoring where
the pointer moved to — were each confirmed to turn the run red before the work was trusted.

**Signing and notarisation: nested code is judged on its own terms.** The bundle can be
signed, verified and hardened, and Apple will still reject the archive because an embedded
dylib lacks a *secure timestamp*. `embed-dependencies.sh` re-signs the two Homebrew dylibs
after `install_name_tool` invalidates them, and its flags follow the identity: ad-hoc keeps
`--timestamp=none` (Apple's timestamp server is a network round trip nobody wants on every
local build), a real identity gets `--timestamp` **and** `--options runtime`.

**`notarytool submit --wait` exits 0 on a rejected verdict.** It reports `Current status:
Invalid` and returns success, so a recipe that trusts the exit code walks on to `stapler`
and dies with "Record not found" and error 65 — an error about the wrong thing, three steps
after the real one. Read `status` out of `--output-format json` and print `notarytool log`
on anything but `Accepted`. Both `make notarize` and the release workflow do this.

**`spctl --assess` is the only check that means anything.** `codesign --verify --strict`
passes on a build Gatekeeper will refuse. The verdict also names the *reason* — `rejected
(source=Unnotarized Developer ID)` says the signature is right and only notarisation is
missing, which is a different problem from `rejected` with no source. To test what a
recipient actually gets, stamp a copy with `com.apple.quarantine` and assess that.

**An `Apple Development` certificate is not a `Developer ID Application` one.** The first is
what Xcode issues from a free Apple ID and signs for your own machines; only the second is
accepted from a download, and it needs an *active paid* membership. Worse, the bracketed
name in an Apple Development certificate is a **per-person identifier, not the team ID** —
copying it into `ARTSCRIBE_TEAM_ID` disagrees silently with what the signature carries. Read
the real one with `codesign -dv --verbose=4 <app> 2>&1 | grep TeamIdentifier`.

**Never echo the signing identity.** `make app` used to print `$(ARTSCRIBE_SIGN_IDENTITY)`,
which puts a developer's name and team into every build log — including one pasted into a
chat. It prints the certificate *kind* now, read back off the bundle.

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

**There is a second boundary crossing the same diagram: platform.** Everything up to and
including `Playback` builds for **iOS as well as macOS**, and CI builds it for iOS on every
push so it stays that way. `ArtscribeUI` and above are AppKit and are macOS-only. When adding
to `Playback`, that is the line to keep — `swift build --destination` will not tell you, but
`make ios-check` will.

The two platform differences in the audio stack are both narrow, and both are behind a seam
rather than sprayed through the code as `#if`:

- **Choosing an output device is a macOS idea.** The HAL enumeration
  (`CoreAudioDeviceSource`) is wholly inside `#if os(macOS)`; iOS gets
  `CurrentRouteDeviceSource`, which reports the one route the system chose, because routing
  there belongs to the user via Control Centre and an app that fought that would be wrong.
  `AudioOutput.setOutputDevice` is a HAL call on macOS and a **documented no-op** on iOS —
  it must *succeed*, because a throw would make `OutputDeviceController` publish "could not
  switch output" about a switch nobody asked for.
- **Being interrupted is an iOS idea.** `AudioSessionCoordinator` is injected into
  `AudioOutput`; it is `AVAudioSessionCoordinator` on iOS and `UnmanagedAudioSession` — inert,
  and *correctly* inert rather than a stub — on macOS. `PlatformAudio` is the single place
  that picks, so call sites say `PlatformAudio.makeDeviceSource()` and carry no `#if`.

**The decision about an interruption is a pure function, and that is the point.**
`AudioSessionPolicy.response(to:wasPlaying:)` holds every rule; the `AVAudioSession` observer
only translates notification payloads into the event vocabulary. So the behaviour that is
expensive to get wrong on a device is unit-tested on the Mac it is developed on, where a phone
call cannot arrive. Two rules there are worth knowing before touching it:

- **Resuming needs both halves** — the system's `shouldResume` *and* having actually been
  playing when the interruption began. The flag alone resumes something the user had paused;
  `wasPlaying` alone resumes out of a phone call, which is the case the flag exists to veto.
- **`isRunning` is already false by the time an interruption ends.** What was true when it
  *began* has to be remembered (`wasPlayingWhenInterrupted`) and consumed once, or a repeated
  `interruptionEnded` — the system does repeat them — resumes a track the user has since
  paused.

**Rubber Band is macOS-only, and that is a Homebrew fact, not a design one.** The formula
builds a macOS dylib and nothing else, so `CRubberBand` is a `.when(platforms: [.macOS])`
dependency and `RubberBandStretcher.swift` sits behind `#if canImport(CRubberBand)`. On iOS
`TimeStretch` is the protocol plus `IdentityStretcher` — enough for `Playback` to compile, and
exactly the seam a second backend plugs into.

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
(incl. 24-bit), WAV, AIFF, CAF, Ogg Vorbis, Opus.

**That list is a macOS fact, not an Apple-platform one. iOS does not decode Ogg Vorbis.**
Measured 2026-07-30 on an iPad simulator: `decodesEveryNativeFormat` passes for every format
above except `sine.ogg`, which fails `.unreadable("Operation Stopped")`. So
`AudioDecodeTests` is the one portable suite CI does *not* run on iOS — the supported-format
expectation has to become platform-aware first, and dropping the case to make the suite green
would hide a difference a user would meet as "this file just will not open". `AVAssetReader` must be explicitly
configured for Float32; the default path can return Int16 and silently discard 8 bits of a
24-bit source.

## Test media

Integration tests read `$ARTSCRIBE_TEST_MEDIA_DIR` and **skip cleanly when unset**, so CI is
green without it. Never commit audio over 100 KB — pre-commit enforces this.

That hang is **fixed**, and it was never about the media: Swift Testing runs tests
concurrently and every `@MainActor` test serialises on the main actor, so one test blocking
it leaves the rest queued forever. Setting the media directory brought more tests into the
schedule and made the deadlock reliable; without it, it surfaced as the intermittent ~1-in-10
`make check` failure that was being blamed on audio hardware. `swift test --no-parallel` runs
all 838 in 26 s with the media directory set. CI and the release workflow both pass it.

**`swift test` runs in parallel, and `@MainActor` tests serialise behind each other.** On a
GitHub runner that deadlocked outright: 886 tests started, 506 finished, and every one of the
~380 that never finished was `@MainActor`. It is not a bad test — it is the scheduling. Use
`--no-parallel` when a run hangs or when you need the log to name a culprit, because under
parallelism the blocked test is invisible among hundreds of others that merely never got a
turn. Both workflows pass it, and the suite is *faster* serially anyway (14.9 s).

## Testing conventions

- Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest
- Views are not snapshot-tested — extract the pure logic and test that
- A test that cannot fail is worse than none. Verify a new regression test actually fails
  against the defect it targets before trusting it.
