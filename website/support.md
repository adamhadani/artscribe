---
layout: page
permalink: /support/
title: Support
nav: support
standfirst: >-
  Every question, bug report and feature request goes to the same place: GitHub
  Issues. It is public, it is searchable, and it is read.
description: >-
  How to get help with Artscripture: where to report a bug, what to include, and
  answers to the common questions.
---

## Getting help

**[Open an issue on GitHub →]({{ site.new_issue_url }})**

That is the support channel — for bug reports, questions about how something
works, and requests for things Artscripture does not do yet. There is no separate
email queue, no forum and no ticket system to sign up for; a public issue tracker
means the answer to your question is also the answer to the next person's.

Before opening one, it is worth a quick search of [the existing
issues]({{ site.issues_url }}) — including closed ones, which often contain the
answer already.

## Reporting a bug

The more of this you can include, the faster it gets fixed. None of it is
mandatory; a short report is much better than no report.

- **What you did, what you expected, and what happened instead.** In that order,
  and as concretely as you can — "pressing <kbd>D</kbd> with a loop set does
  nothing" is worth more than "looping is broken".
- **The Artscripture version.** Artscripture ▸ About Artscripture, or the name of the
  release you downloaded.
- **Your macOS or iPadOS version, and your Mac or iPad model.**
- **The audio file's format and roughly its length** — 24-bit FLAC, seventy
  minutes, that sort of thing. Several past bugs only appeared on
  album-length files or on one particular container.
- **Whether it happens every time**, or only sometimes, or only after some
  particular sequence of steps.
- **Whether a `.cue` sheet or a `.artscripture` session file was sitting next to
  the audio.** Both are read automatically, and both have been the culprit
  before.
- **A screenshot**, if the problem is something you can see.

Please do **not** attach copyrighted music. It is almost never needed — the
format and duration usually are enough, and if a specific file really is
required, that can be worked out in the issue.

## Requesting a feature

Open an issue and describe the *problem*, not only the proposed solution — what
you were trying to do when you wanted it, and what you do instead today. That is
consistently the part that decides whether and how something gets built.

Some things are known gaps rather than oversights: spectrum analysis, MIDI input
and stem separation are all deliberately not started. Saying you want one of them
is still useful.

## Frequently asked

### What audio formats does Artscripture open?

MP3, AAC, M4A/MP4, ALAC, FLAC (including 24-bit), WAV, AIFF, CAF, Ogg Vorbis and
Opus. Everything is decoded by the operating system's own frameworks — there is
no bundled ffmpeg and there are no bundled codecs.

**Ogg Vorbis is macOS only.** iPadOS cannot decode it, so it is not offered in
the iPad file picker rather than being offered and then failing to open. Opus is
a different codec and works on both.

### What do I need to run it?

**macOS 26 on Apple Silicon.** Homebrew ships arm64-only libraries and Artscripture
has never been an Intel product, so the released bundle is `arm64` rather than
universal. The iPadOS target requires iPadOS 26 and is built from source rather
than distributed as a download.

### macOS says the app "cannot be opened"

That means the build you have was not notarised. Releases published from the
project's own release workflow *are* signed and notarised and should open
normally. If you hit it — with a build you compiled yourself, for instance —
right-click the app and choose **Open**, then confirm; or run:

```sh
xattr -d com.apple.quarantine Artscripture.app
```

### Where are my sessions saved?

Next to the audio file, with `.artscripture` appended to the whole filename:
`Blackbird.flac` saves to `Blackbird.flac.artscribe`. The extension is appended
rather than replaced on purpose, so a lossless master and an MP3 of the same
song in one folder do not silently overwrite each other's loop points.

If the folder cannot be written to, the session goes to
`~/Library/Application Support/Artscripture/Sessions/` instead, and the app says so
rather than failing quietly.

Press <kbd>⌘S</kbd> to save, <kbd>⇧⌘S</kbd> to save elsewhere.

### How do I see all the keyboard shortcuts?

Press <kbd>⌘/</kbd>, or **View ▸ Keyboard Shortcuts**. It opens a window showing
the whole keymap drawn on a keyboard, with a searchable list beside it. Hold a
modifier and the picture changes to that layer. The
[documentation]({{ '/docs/' | relative_url }}) has the same information as
tables.

### Can I change the keyboard shortcuts?

Not yet. The bindings all live in one catalog and the app is built so that a
rebindable table can replace it, but the user-facing editor has not been built.

### Does Artscripture send any of my data anywhere?

No. It has no network code at all. See the [privacy
policy]({{ '/privacy/' | relative_url }}) for the full detail.

### Is it free?

Yes, and it is open source. Artscripture's own code is Apache-2.0; the distributed
macOS binary links Rubber Band and is therefore conveyed under the GPLv3. See
[NOTICE]({{ site.repo_url }}/blob/main/NOTICE).

### Can I build it myself?

Yes — the [README]({{ site.repo_url }}#-quick-start) has the full instructions.
The short version is `make bootstrap` followed by `make app`.

## Contributing

The source is at [github.com/adamhadani/artscripture]({{ site.repo_url }}).
Pull requests are welcome; opening an issue first to agree the shape of a change
tends to save everyone time.
