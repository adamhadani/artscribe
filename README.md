<div align="center">

# 🎼 Artscribe

**A keyboard-first music transcription tool for macOS.**

Load a track · select a passage · loop it seamlessly · slow it down without changing pitch.

[![CI](https://github.com/adamhadani/artscribe/actions/workflows/ci.yml/badge.svg)](https://github.com/adamhadani/artscribe/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/adamhadani/artscribe?include_prereleases&sort=semver)](https://github.com/adamhadani/artscribe/releases)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%20·%20Apple%20Silicon-lightgrey)](#-quick-start)
[![Swift](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://swift.org)

</div>

---

When you transcribe, your hands are on an instrument — not on a mouse. Artscribe is built
around that: **every operation has a key**, the window is one uninterrupted waveform, and
the passage you are working on stays where you put it.

## ✨ What it does

| | |
|---|---|
| 🔁 **Seamless looping** | The stretcher is never reset at a loop boundary, so a repeat is *inaudible* — verified as byte-identical to a continuous render, not just "sounds fine" |
| 🐢 **Studio-grade slowdown** | Rubber Band R3 "Finer": **~0.00 cents** of pitch error at half speed |
| ⌨️ **Keyboard-first** | ~90 actions, all rebindable-by-design, with a searchable shortcut window (`⌘/`) |
| 🎯 **Preroll** | A resume rolls back a couple of seconds, so you land *before* the note you stopped on |
| 📈 **Practice ramp** | Loop a phrase from slow to tempo automatically |
| 💿 **CUE track markers** | One-file albums show where each track begins |
| 📝 **Visible session files** | A plain `.artscribe` sidecar you can read and hand-edit |

**Status: in development, and playable.** Load a file, hear it, select, loop, change speed —
all from the keyboard. Not yet built: pitch shift, spectrum analysis, MIDI input, and
[stem separation](docs/superpowers/research/2026-07-28-stem-separation.md) (researched in
depth, deliberately not started).

## 🚀 Quick start

```sh
make bootstrap
make app && open .build/xcode/Build/Products/Release/Artscribe.app
```

Or grab a signed, notarised build from [**Releases**](https://github.com/adamhadani/artscribe/releases).

## 🎹 The keys that matter

| Key | Does |
|---|---|
| `Space` | Play / pause (with preroll) |
| `⇧Space` | Play from the start of the loop, selection or track |
| `A` `S` | Set loop in / out at the playhead |
| `D` | Loop on / off |
| `Q` `W` | Slower / faster |
| `1` `2` `3` `4` | 100% · 75% · 50% · 33% |
| `Z` `X` | Nudge back / forward |
| `⌘9` `⌘0` | Zoom to selection (or loop) · fit whole file |
| `⌘/` | The full shortcut reference |

## 🔍 Alternatives

Artscribe is not the only option, and for many people it should not be the first one tried.

- **[Transcribe!](https://www.seventhstring.com/xscribe/overview.html)** (Seventh String) —
  the long-standing standard, and genuinely excellent: deep, fast, thoroughly documented,
  actively maintained, and cross-platform. Its feature set still goes well beyond this
  project's. The interface simply feels of an earlier era, and that — not the engineering —
  is what Artscribe reacts to. If you want a mature, supported, commercially backed tool
  today, buy it; it is inexpensive and very good.
- **[Amazing Slow Downer](https://www.ronimusic.com/)** — a focused, reliable
  slow-down-and-loop player, on desktop and mobile.
- **[Anytune](https://anytune.com/)** — macOS and iOS, strong on practice tooling.
- **A full DAW** (Logic, Ableton, Reaper) — if you already live in one, it will slow audio
  down and loop it perfectly well. It is simply a lot of software to open to learn eight
  bars.

## Running Artscribe

There are three ways in, and they are for different people.

### Download a release — to just use it

Grab the newest `Artscribe-<version>.zip` from
[Releases](https://github.com/adamhadani/artscribe/releases), unzip it, and drag
`Artscribe.app` to `/Applications`.

**macOS 26 on Apple Silicon.** Homebrew ships arm64-only libraries and this has never been
an Intel product, so the bundle is `arm64` rather than universal.

> **If macOS says the app "cannot be opened"** the build was not notarised. Right-click it ▸
> **Open** and confirm, or `xattr -d com.apple.quarantine Artscribe.app`. See
> [Signing](#signing) for why, and for what makes it stop happening.

### `make app` — to build it yourself

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

#### The developer menu — comparing stretch engines

Artscribe has two time-stretching backends, and which one is running is **not** a user-facing
choice. It is one for whoever is working on the audio:

```sh
ARTSCRIBE_DEV_MENU=1 swift run -c release ArtscribeApp
```

That adds **Playback ▸ Developer ▸ Stretch Engine**: Rubber Band R3 (Studio), Rubber Band R2
(Fast), Signalsmith, Signalsmith (Cheaper). Switching rebuilds the audio graph, so you will
hear a short gap — you are comparing two renders separated by a reload, not crossfading
between them.

An environment variable rather than a `DEBUG`-only build, deliberately: the menu exists to
judge engines *by ear*, and a debug build decodes about four times slower, so it would make
both engines sound bad and the comparison worthless. The gate has to survive `-c release`.

A bundle launched from Finder inherits no shell environment and so never shows it, which is
the point — the menu cannot appear for someone who did not ask for it from a terminal.

For a headless A/B, with the render-thread degradation counters a menu cannot show you:

```sh
swift run -c release artscribe-cli --engine signalsmith track.flac 0.5 10 14
```

#### Running the tests on an iPad simulator

```sh
make ios-test              # or: make ios-test SIM='iPad Pro 13-inch (M4)'
```

248 tests — everything portable, which is all of `ArtscribeKit`, `Waveform`, `TimeStretch` and
`Playback` except the suites that need Rubber Band. Those are behind
`#if canImport(CRubberBand)` and simply do not exist on iOS.

`make ios-check` only *compiles* for iOS. This runs, which is a different claim: Signalsmith is
the only stretcher on iOS, so its loop-seam proof belongs on the platform that uses it.

`--engine` takes `studio`, `fast`, `signalsmith` or `signalsmithCheaper`, and the chosen
engine is printed on every run — listening to the wrong one without knowing is the mistake
the tool exists to prevent.

### Running it on an iPad

There is an iPad target — `ArtscribeiPad` — and it needs no App Store, no TestFlight and no
review to get onto your own device. What it can do so far: open a track, draw the waveform,
select, loop and play. What it **cannot** do is change speed, because there is no Rubber Band
build for iOS yet; the control moves and nothing happens. See [Formats](#formats) and
`PlatformStretcher`.

**Once, on the iPad:** Settings ▸ Privacy & Security ▸ **Developer Mode** ▸ on, then restart.
(iOS 17 or newer; `devicectl` does not support older devices.)

**Once, on the Mac:** export `ARTSCRIBE_TEAM_ID` — the same one signing already uses. Device
builds are signed automatically with an *Apple Development* certificate, which Xcode mints
from your account; this is not the Developer ID path the Mac release uses.

Connect the iPad by USB and find its identifier:

```sh
xcrun devicectl list devices
```

The column you want is **Identifier** — a UUID like `00008103-000A1B2C3D4E5F00`, not the
device name and not the serial number. If nothing is listed, the iPad is locked, has never
trusted this Mac (unlock it and answer *Trust*), or Developer Mode is still off.

Then build, install and launch:

```sh
xcodegen generate                       # regenerate the project; it is gitignored
xcodebuild build -scheme ArtscribeiPad -destination 'id=<identifier>' \
    -derivedDataPath .build/xcode-ipad

xcrun devicectl device install app --device <identifier> \
    .build/xcode-ipad/Build/Products/Debug-iphoneos/Artscribe.app

xcrun devicectl device process launch --device <identifier> com.artscribe.Artscribe
```

To iterate without a device, build for a simulator instead — no signing, no team:

```sh
xcodebuild build -scheme ArtscribeiPad \
    -destination 'platform=iOS Simulator,name=iPad (A16)' CODE_SIGNING_ALLOWED=NO
```

> The provisioning profile lasts a year with a paid Apple Developer membership, and seven days
> with a free Apple ID — after which the app stops launching until you reinstall it.

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

<details>
<summary><b>Full signing &amp; notarisation guide</b> — Developer ID, notarytool, CI secrets (click to expand)</summary>

`make app` signs the bundle **ad-hoc** (`codesign --sign -`). That is enough to run it on
the machine that built it, and enough for anyone who copies it across by hand.

It is *not* enough for a download. A zip fetched from the internet arrives with a quarantine
flag, and Gatekeeper rejects an ad-hoc signature outright — `spctl --assess` says
`rejected`, and the recipient sees "Artscribe cannot be opened". They can get past it with
right-click ▸ **Open**, or `xattr -d com.apple.quarantine Artscribe.app`, but they should
not have to.

Doing it properly needs an **Apple Developer account** ($99/yr). The build is already wired
for one: signing comes from three environment variables, so switching it on changes **no
tracked file**.

#### Locally, once you have the account

Get a **Developer ID Application** certificate into your login keychain (Xcode ▸ Settings ▸
Accounts ▸ Manage Certificates ▸ +, or developer.apple.com ▸ Certificates). Then find its
exact name and your team ID:

```sh
security find-identity -v -p codesigning
# 1) A1B2C3... "Developer ID Application: Your Name (TEAMID)"
```

Two ways this goes wrong, both of which produce a bundle that builds, signs and
verifies cleanly and is still rejected on the recipient's Mac:

- **`Apple Development: …` is the wrong certificate.** It is what Xcode creates
  from a free Apple ID, and it signs for your own machines only. A
  **Developer ID Application** certificate needs an *active, paid* Apple
  Developer Program membership — a lapsed one will not offer it, and Xcode ▸
  Manage Certificates ▸ **+** simply will not list it. Only the Account Holder
  can create one, and you get five.
- **The bracketed name in an `Apple Development` certificate is not the team
  ID.** It is a per-person identifier, so copying it into `ARTSCRIBE_TEAM_ID`
  silently disagrees with what the signature actually carries. Read the real one
  off a built bundle:

  ```sh
  codesign -dv --verbose=4 <path>/Artscribe.app 2>&1 | grep TeamIdentifier
  ```

`make app` prints the certificate kind it used and says plainly when it is not a
Developer ID, so this is caught at build time rather than by a user who cannot
open the app.

Export those and build. The Makefile defaults to ad-hoc, so these are the whole change:

```sh
export ARTSCRIBE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export ARTSCRIBE_TEAM_ID=TEAMID
export ARTSCRIBE_HARDENED_RUNTIME=YES

make dist        # signs with the real identity, hardened runtime on
```

Store notarisation credentials once, then notarise:

```sh
xcrun notarytool store-credentials artscribe-notary \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

make notarize    # submits, waits, staples, re-zips, and runs spctl
```

The password is an **app-specific password** (appleid.apple.com ▸ Sign-In and Security ▸
App-Specific Passwords), not your Apple ID password. It is stored in your keychain under the
profile name, so this is a once-per-machine step.

A successful run ends like this, and all three lines matter:

```
status: Accepted                       ← Apple's verdict
The staple and validate action worked  ← the ticket is now inside the .app
accepted (source=Notarized Developer ID)  ← what Gatekeeper tells the recipient
```

`codesign --verify --strict` passing means very little on its own — it passes on builds
Gatekeeper refuses. `spctl --assess` is the check that counts, and its *reason* is
diagnostic: `rejected (source=Unnotarized Developer ID)` means the signature is right and
only notarisation is missing, which is a different problem from a bare `rejected`.

To test what a recipient actually experiences, quarantine a copy the way a browser would:

```sh
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" Artscribe.app
spctl --assess --type execute --verbose=4 Artscribe.app   # must still say: accepted
```

**Nested code is notarised on its own terms.** The first real submission here was rejected
with *"The signature does not include a secure timestamp"* against both embedded dylibs,
while the app itself was fine. `App/embed-dependencies.sh` re-signs those dylibs after
`install_name_tool` invalidates them, and its flags follow the identity — ad-hoc keeps
`--timestamp=none`, a real identity gets `--timestamp` and `--options runtime`. Nothing to
configure; it is recorded here because the error names the symptom and not the cause.

Note that `notarytool submit --wait` **exits 0 even when the verdict is `Invalid`**.
`make notarize` reads the status out of the JSON instead of trusting the exit code, and
prints Apple's own reasons on failure. If you script this yourself, do the same.

#### In CI

`.github/workflows/release.yml` builds and publishes on a `v*` tag. Without secrets it
falls through to an ad-hoc build, so the path stays exercised.

Put the signing secrets in an **environment** named `release`, not on the repository —
Settings ▸ Environments ▸ **New environment** ▸ `release`, then add them there. The job
declares `environment: release`, so it will not see them anywhere else. The reason to prefer
an environment is that it can be scoped: under **Deployment branches and tags**, select
*Selected branches and tags* and add the tag pattern `v*`, and the Developer ID key becomes
unreachable from a workflow run on an ordinary branch. Repository secrets have no such
scoping — every workflow in the repo can read them. Adding **Required reviewers** puts a
human approval in front of every release as well.

The secrets to add:

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | The Developer ID cert as a base64 `.p12`: export from Keychain Access, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set on that `.p12` export |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `MACOS_TEAM_ID` | The 10-character team ID |
| `APPLE_API_KEY` | An App Store Connect API key (`.p8`), base64-encoded |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER_ID` | The issuer ID from App Store Connect ▸ Users and Access ▸ Integrations |

**The API key must be a Team Key with the `Developer` role.** App Store Connect ▸ Users and
Access ▸ Integrations offers *Team Keys* and *Individual Keys* on separate tabs, and an
individual key **cannot use the Notary API** — it authenticates and then fails, which is a
confusing way to spend an hour. `Developer` is sufficient; nothing broader is needed. The
`.p8` downloads exactly once. The Key ID is the 10-character string beside the key; the
Issuer ID is the UUID above the table, shared across every key on the team.

An API key rather than an app-specific password in CI, because it is scopeable and
revocable on its own, and independent of anyone's Apple ID. The workflow imports the
certificate into a **throwaway keychain** that dies with the job, never the login keychain.

Cutting a release is then:

```sh
git tag -a v0.1.0 -m "Artscribe 0.1.0" && git push origin v0.1.0
```

The job refuses a tag whose version disagrees with `MARKETING_VERSION`, runs the full gate
before building — "CI was green on main" is not the same statement as "this tag is green" —
and publishes the notarised zip to Releases. With no secrets set it still runs end to end and
produces an ad-hoc build, so the path stays exercised before the certificate exists.

#### Keep the private key, not the password

The two secrets are not equally precious:

- The **app-specific password** is disposable. You cannot read it back after creating it, and
  you do not need to: revoke it and make another in under a minute. Losing the Mac it was
  stored on costs nothing.
- The **Developer ID private key** cannot be recreated. Without it you cannot sign or re-sign
  anything, and recovering means revoking the certificate and spending one of the **five**
  Developer ID Application certificates an account ever gets. Export it once
  (Keychain Access ▸ **My Certificates** ▸ the identity ▸ Export ▸ `.p12`) and keep it in a
  password manager or other durable secret storage.

`.p12` greyed out on export means you selected the certificate rather than the *identity*.
Use the **My Certificates** category, or expand the certificate and select it together with
its private key.

#### Secrets in a public repository

Making the repository public does not expose them. Secrets are **write-only**: once saved,
nobody can read them back through the UI or the API — not collaborators, not even the owner.
You can only overwrite or delete.

The real exposure on a public repo is a workflow that runs untrusted code *with* secrets in
scope. Two facts keep this one safe:

- Workflows triggered by `pull_request` from a fork **never** receive secrets. This is
  GitHub's default and it is why `pull_request_target` — which does — should be avoided.
- This workflow only triggers on `push` of a `v*` tag and on `workflow_dispatch`, both of
  which require write access to the repository.

The honest caveat: **write access is effectively secret access.** Anyone who can merge a
workflow change to the default branch can write one that prints a decoded secret. GitHub
masks known secret values in logs, but that is best-effort, not a boundary. Scope the
environment to `v*` tags and require a reviewer if the repository ever gains collaborators.

#### What already works regardless

The entitlements file carries `com.apple.security.cs.disable-library-validation`, which a
hardened process needs before it will load the embedded Homebrew dylibs, and
`App/embed-dependencies.sh` already signs those dylibs inside-out before the bundle — the
order notarisation requires. Neither needs changing.

The one thing an account will never buy: **the Mac App Store is permanently out**. Artscribe
links Rubber Band under the GPL, and the GPL is incompatible with the App Store's terms.
Developer-ID-signed downloads, a Homebrew cask, or source are the routes.

</details>

## 🎧 Why it sounds better

Slowing audio down without changing pitch is the hard part, and it is the reason this
project exists at all. Artscribe uses [Rubber Band](https://breakfastquay.com/rubberband/) 4.0's
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
| `Space` | Play / pause. Resuming rolls back by the **preroll** — 2 s by default, configurable in Settings ▸ Playback — so you hear the note you stopped on in context |
| `⇧Space` | Play from start — of the selection, else of an active loop, else of the file. No preroll: it already has an explicit target |
| `H` | Preroll on / off — flips the mode without forgetting the amount |
| `Q` / `W` | Slower / faster (5%) |
| `⇧Q` / `⇧W` | Slower / faster (1%) |
| `1` `2` `3` `4` | 100% / 75% / 50% / 33% |
| `↑` / `↓` | Volume up / down — `⇧↑` / `⇧↓` in finer steps |
| `M` | Mute |

**Preroll.** You stop on a note; to hear it in context you have to start slightly before it.
`Space` therefore resumes from `position − preroll` rather than from exactly where it
stopped. Two seconds by default, editable in **Settings ▸ Playback** in seconds with
fractions, and **0 turns it off** — that is an allowed value, not a rejected one. It clamps
at the start of the file, and when a loop is active and the playhead is inside it, at the
loop's in point, so a resume never steps outside the passage you set. Pausing and resuming
twice rolls back twice: each press is a fresh resume, which is how you inch back through a
phrase. `⇧Space` never prerolls.

`H` turns it off and on again. That is not the same as setting it to 0: zero is a permanent
"resume exactly where I stopped", whereas the toggle is the mode you flip while working and
it remembers your seconds. It is also a **Playback** menu item and a transport-bar button
beside the loop, both of which show the current state.

### Selection, looping and view

| Key | Action |
|---|---|
| `⌘O` | Open a file (dropping one on the window works too) |
| `A` / `S` | Set loop in / out at the playhead |
| `D` | Toggle looping |
| `F` | Restart the loop |
| `G` | Turn the selection into the loop |
| `R` / `E` | Zoom in / out, anchored on the playhead |
| `Z` / `X` | Nudge the playhead back / forward (2 s, configurable) — `←` / `→` do the same |
| `⇧Z` / `⇧X` | Nudge finely (50 ms) — `⌥Z` / `⌥X` (or `⌥←` / `⌥→`) rewind and skip (10 s) |
| `⌘A` | Select the whole file |
| `⇧←` / `⇧→` | Extend the selection |
| `C` / `V` | Move the whole selection left / right (250 ms, configurable) |
| `⌥C` / `⌥V` | Move it further (2 s, configurable) |
| `⌘0` / `⌘9` | Fit the whole file / zoom to selection |
| `Esc` | Clear the selection |
| `⇧A` `⇧S` / `⇧D` `⇧F` | Move the loop's in / out point (add `⌥` for the bigger step) |
| `⇧C` / `⇧V` | Move the whole loop, keeping its length |
| `⌘S` / `⇧⌘S` | Save the session sidecar / save it elsewhere |
| `⌘P` | Show or hide the Practice window — the ramping loop |
| `⌥P` | Start / stop the speed ramp |
| `⌘/` | Show or hide the keyboard shortcut window |
| `⌘,` | Settings — preroll, nudge and move amounts, zoom direction, theme |

Drag in the lanes to select, shift-drag to extend, click to place the playhead, double-click
to place it and play from there (`⌘A` is still Select All). Pinch to zoom, two-finger scroll
to pan. Dragging the overview strip
moves the visible window. **Drag down** on the time ruler — or ⌥-drag in the waveform — to
zoom in smoothly; Settings ▸ Playback ▸ *Invert zoom direction* reverses that and the scroll
wheel together.

### The Practice hub

Press `⌘P` — or **View ▸ Practice** — for a separate window that plays your loop over and
over while the speed climbs, so you can take a passage from slow to tempo without touching
anything.

Give it three numbers and it works out the rest:

* **Start speed**, **end speed** and **number of repetitions**. The default is 50% → 100%
  over ten passes; the per-repetition step is computed and shown under the fields. Both
  endpoints are played, so ten repetitions from 50% to 100% is nine steps of 5.6%, not ten.
* **An end speed below the start speed ramps down**, which is a real way to practise — you
  take something you can just about play at tempo and slow it down to hear what your fingers
  are actually doing.
* **Start speed equal to end speed** drills one tempo for a set number of passes.

While it runs the window shows which repetition you are on, the speed you are hearing, and
how many are left. **It advances when the loop comes round, not on a timer** — a timer would
drift the moment the loop length or the speed changed underneath it, and the ramp changes the
speed on purpose.

When the last repetition finishes the ramp **holds the final speed and keeps playing**. It
does not stop you: a ramp is a speed automation, not a transport, and the end of one is the
moment you have arrived at the passage, at tempo, in the loop — which is what the whole
exercise was for. The window says *Ramp complete — holding 100%* so it is not a silent
ending.

A ramp needs a loop. With none set, the window says so and names the keys that fix it (`A`
and `S`, or `G` from a selection) rather than offering a Start button that would do nothing.
Starting a ramp switches looping on for you if the region is set but disabled.

Like the shortcut window it is a separate window rather than a panel, and for a sharper
reason: this is a thing you watch the waveform while using, so it must cost the waveform no
width.

### The shortcut window

Press `⌘/` — or **View ▸ Keyboard Shortcuts** — for a separate window with the whole keymap
drawn on a keyboard, and a searchable list beside it.

* **The keyboard shows one modifier layer at a time, and follows the modifiers you hold.**
  Hold `⇧` and `A S D F` change from setting the loop's edges to moving them; add `⌥` and
  they move further. Six actions live on the `A` and `Z` caps alone, which is why a picture
  that stacked them all would teach nothing. Layers are derived from the bindings that
  exist, so a new chord gets a layer without anyone maintaining a list.
* **A layer can also be pinned** from the picker, for anyone who cannot hold two modifiers
  at once. Holding wins while you hold; the pin is what you come back to.
* **One filter narrows both surfaces.** Type "loop" and the list shows the loop actions
  while every key that is not one goes quiet. It matches the action's name, its group, its
  note, and the chord both written (`⌥⇧A`) and spoken ("option shift").
* Keys are tinted by category and unbound keys are dimmed. Actions with no shortcut at all —
  Stop, Clear Loop, the two Scroll items — still appear in the list.

Drag the divider between the keyboard and the list to resplit it; it stays where you left it
between launches. The window is separate rather than a panel inside the document on purpose:
a panel can only exist by taking width from the waveform.

It is generated from the same `ActionCatalog` the menus and the keyboard are built from, so
it cannot fall out of step with what the keys actually do — see `Sources/ArtscribeUI/
ActionCatalog.swift`, and `ActionCatalogTests` for the test that enforces it.

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

### The acceptance harness

`make check` tests the modules headlessly. The other half is `ArtscribeAcceptance`, a
separate executable that opens a real window and drives it through about six hundred checks
with genuine `NSEvent`s — menus, key equivalents, pointer drags and real playback.

```sh
swift run -c release ArtscribeAcceptance --list
swift run -c release ArtscribeAcceptance --acceptance <audio-file> --only loop
```

`--list` names the sixteen groups it is split into. `--only` and `--skip` take
comma-separated names, and `--quick` drops the two groups that wait on timed playback. A
single group takes seconds where the full run takes minutes — but a run that skipped
anything says so in its summary and exits 2 rather than 0, because a partial acceptance run
is not an acceptance pass.

The harness never makes a sound: it closes a process-wide audibility gate in the audio graph
itself, before any output can exist. `ARTSCRIBE_ACCEPTANCE_AUDIBLE=1` is the deliberate
override.

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

**Artscribe's own source is Apache-2.0.** See [LICENSE](LICENSE) and [NOTICE](NOTICE).

**A distributed binary may be a different matter, and which one depends on what it links.**
The GPL binds the combined work at the moment it is distributed, not the repository:

| Build | Time stretcher | The binary may be distributed as |
|---|---|---|
| macOS | Rubber Band (GPL-2.0-or-later) | **GPLv3 only** — no App Store |
| iOS / iPadOS | none yet | Apache-2.0, unencumbered |

Rubber Band is the best open time-stretching engine available and quality at low speeds is
the whole point of the product, so the macOS build takes that trade deliberately. Its "or
later" clause is what makes the arrangement legal at all — Apache-2.0 is compatible with
GPLv3 and **not** with GPLv2, so the combination is taken as v3.

[docs/LICENSING.md](docs/LICENSING.md) has the full reasoning, including what changes when a
permissively-licensed backend lands.
