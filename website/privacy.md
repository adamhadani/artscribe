---
layout: page
permalink: /privacy/
title: Privacy Policy
nav: privacy
standfirst: >-
  Artscribe collects no data. There are no accounts, no analytics, no telemetry
  and no network requests of any kind. This page explains, in detail, what that
  means and what is stored on your own device.
description: >-
  Artscribe collects no personal data, contains no analytics or tracking, and
  makes no network requests. Everything stays on your device.
---

<p class="updated">Last updated: 31 July 2026</p>

This policy covers the Artscribe application for macOS and iPadOS, and this
website.

## The short version

**Artscribe collects nothing, transmits nothing, and contains no code capable of
doing either.**

- No personal data is collected.
- No usage analytics, crash reporting, telemetry or diagnostics are collected or
  sent.
- No accounts, no sign-in, no user identifiers of any kind.
- No advertising, and no advertising or tracking identifiers.
- No third-party SDKs, frameworks or services are embedded.
- The app makes **no network requests at all**, so there is no server for your
  data to reach.

## Your audio files

Audio files you open are read from your device's local storage — or from a
location you explicitly grant access to through the system file picker — and are
decoded in memory for playback and waveform display.

**Your audio never leaves your device.** It is not uploaded, copied to any
server, streamed, analysed remotely or shared with anyone. Artscribe has no
mechanism to do so.

Artscribe does not modify your audio files. It reads them; it never writes to
them.

## What is stored, and where

Everything below is stored **locally, on your own device**, and nothing is ever
transmitted from it.

### Preferences

Stored in the system preferences store (`UserDefaults`), the standard place a
Mac or iPad app keeps its settings:

- Your chosen theme (system, light or dark).
- Playback preferences: the preroll amount and whether preroll is on.
- Navigation and editing amounts: nudge, selection-move and loop-move step
  sizes.
- Whether the zoom drag direction is inverted.
- Practice-window settings: start speed, end speed and repetition count.
- Window layout, such as where you last dragged the divider in the keyboard
  shortcut window.

### Recently opened files

Artscribe keeps a list of the **eight** most recently opened files so they can
be reopened from the resting screen or the Open Recent menu. This list is a set
of file paths, stored in the same local preferences store.

On iPadOS, a *security-scoped bookmark* is stored alongside each path. This is a
system-provided token that lets the app reopen a file you already chose after a
relaunch — a file picked out of the Files app lives outside the application's
container, and its plain path stops being readable. The bookmark is created by
the operating system, is only meaningful on your device, and grants access to
nothing you have not already picked yourself.

Clearing the recent-file list removes both.

### Session sidecars

When you save a session (<kbd>⌘S</kbd>), Artscribe writes a small plain-text
JSON file recording where you were working: the loop region, the speed, the
pitch, the playhead position, the visible viewport, and whether the track-mark
lane is showing. It records the track's identity so it can tell it is the right
file; it does not contain any audio.

It is written **next to your audio file**, named by appending `.artscribe` to
the file's full name — so `Blackbird.flac` gets `Blackbird.flac.artscribe`.

If that folder is not writable — a read-only volume, for instance — the file
falls back to:

```
~/Library/Application Support/Artscribe/Sessions/
```

and the app tells you plainly that it did. These files are yours: readable,
editable and deletable with any text editor or file manager.

## What Artscribe does *not* do

- It does not read your other files, your music library, your contacts, your
  location, your microphone or your camera.
- It does not fingerprint your device or your hardware.
- It contains no advertising, analytics, attribution or crash-reporting SDK.
- It does not phone home to check for updates. New versions are published on the
  [GitHub releases page]({{ site.releases_url }}) and you fetch them yourself,
  when you choose to.

## Third-party components

Artscribe links two audio libraries — [Rubber
Band](https://breakfastquay.com/rubberband/) on macOS and [Signalsmith
Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) on iPadOS —
which perform time-stretching arithmetic on audio in memory. They are
open-source signal-processing code with no network capability, no analytics and
no data collection. They are not services and have no servers.

Audio decoding is performed by the operating system's own frameworks. No codecs
or media libraries are bundled.

## This website

This site is static HTML served by GitHub Pages. It sets no cookies, runs no
JavaScript, and loads no fonts, scripts, images or stylesheets from any other
host — precisely so that a page claiming zero data collection is not itself
contradicting the claim.

GitHub, as the host, may process standard server request logs (such as IP
addresses) as part of serving the page. That is outside this project's control
and is covered by [GitHub's Privacy
Statement](https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement).
Following any link from this site to GitHub takes you to a service with its own
policy.

## Children

Artscribe collects no data from anyone, of any age. It is not directed at
children and contains no content or feature that would make it so.

## Verifying any of this

Artscribe is open source. If you would rather check than take a policy's word
for it, the entire application is readable at
[github.com/adamhadani/artscribe]({{ site.repo_url }}). A search of the source
tree for networking APIs returns nothing, which is the fact this page rests on.

## Changes to this policy

If this policy changes, the revised version will be published here with a new
date at the top, and the change will be visible in this repository's commit
history.

## Contact

Questions about privacy, or anything else, are welcome as a GitHub issue:

**[github.com/adamhadani/artscribe/issues]({{ site.issues_url }})**

See the [support page]({{ '/support/' | relative_url }}) for what is useful to
include.
