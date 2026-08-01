---
layout: home
permalink: /
title: Artscripture
description: >-
  A keyboard-first music transcription tool for macOS and iPadOS. Load a track,
  select a passage, loop it seamlessly, and slow it down without changing pitch.
---

<section class="hero">
  {% include mark.svg %}
  <h1>Artscripture</h1>
  <p class="tagline">A keyboard-first music transcription tool for macOS and iPadOS.</p>
  <p class="pitch">
    When you transcribe, your hands are on an instrument — not on a mouse. Load a
    track, select a passage, loop it seamlessly, and slow it down without
    changing pitch. Every operation has a key.
  </p>
  <p class="actions">
    <a class="button" href="{{ site.download_url }}">Download for macOS</a>
    <span class="aside">macOS 26 · Apple Silicon · iPadOS coming · free and open source</span>
  </p>
</section>

<section class="features">

<div class="feature feature--loop">
  <p class="eyebrow">Seamless looping</p>
  <h2>A repeat you cannot hear</h2>
  <p>
    The time stretcher is <strong>never reset at a loop boundary</strong> — audio
    is fed continuously across the seam. That is the difference between a clean
    loop and a click on every repetition, in a tool whose whole purpose is
    repetition. It is verified rather than asserted: a looped render is compared
    against a file with the same passage already laid out end to end, and the
    measured difference across every wrap is <strong>exactly zero</strong>.
    Forcing a reset at the boundary produces a 28× discontinuity against the
    signal's own natural step size.
  </p>
</div>

<div class="feature">
  <p class="eyebrow">Studio-grade slowdown</p>
  <h2>Slow, and still in tune</h2>
  <p>
    Time stretching sits behind a single interface with <strong>two
    interchangeable backends</strong>, chosen per platform. macOS uses Rubber
    Band 4.0's <strong>R3 “Finer”</strong> engine; iPadOS uses
    <strong>Signalsmith Stretch</strong>, compiled from vendored source into the
    app. Both are measured rather than assumed: as an FFT peak against a
    reference tone, pitch error at half speed is <strong>~0.00 cents</strong> for
    R3 and <strong>within 0.05 cents</strong> for Signalsmith — and Signalsmith's
    figure is identical at both ratios to five decimal places, which means it is
    reporting the estimator's own bias rather than anything the stretcher did.
  </p>
  <p>
    Speed and pitch are independent controls: you can transpose a passage by
    semitones or by single cents without touching the tempo.
  </p>
</div>

<div class="feature">
  <p class="eyebrow">One codebase, two platforms</p>
  <h2>The iPad is not a port</h2>
  <p>
    The audio stack below the interface — decoding, the peak pyramid, time
    stretching, the playback engine — builds for iPadOS as well as macOS, and CI
    compiles it for iOS on every push <em>and runs the portable suites on an iPad
    simulator</em>. Compiling is not behaviour, and the difference mattered: the
    test proving that a loop is indistinguishable from a continuous render now
    runs against the backend that is the only one on iPad.
  </p>
  <p>
    The two platform differences are narrow and both sit behind a seam rather
    than being sprayed through the code as conditionals — choosing an output
    device is a macOS idea, and being interrupted by a phone call is an iPadOS
    one.
  </p>
</div>

<div class="feature">
  <p class="eyebrow">Keyboard-first</p>
  <h2>Seventy-one actions, all under your hands</h2>
  <p>
    Transport, selection, looping, zoom, speed, pitch and volume are all keys —
    clustered so the whole transport sits under the left hand. Press
    <kbd>⌘/</kbd> for a separate window with the entire keymap drawn on a
    keyboard beside a searchable list. It <strong>follows the modifiers you
    hold</strong>: press <kbd>⇧</kbd> and <kbd>A</kbd> <kbd>S</kbd> <kbd>D</kbd>
    <kbd>F</kbd> change from setting the loop's edges to moving them. It is
    generated from the same catalog the menus are built from, so it cannot fall
    out of step with what the keys actually do.
  </p>
</div>

<div class="feature">
  <p class="eyebrow">Preroll</p>
  <h2>Land <em>before</em> the note you stopped on</h2>
  <p>
    You stop on a note; to hear it in context you have to start slightly before
    it. <kbd>Space</kbd> therefore resumes from <em>position − preroll</em> — two
    seconds by default, configurable, and 0 turns it off. It clamps at the start
    of the file, and at the loop's in point when a loop is active, so a resume
    never steps outside the passage you set. Pausing and resuming twice rolls
    back twice, which is how you inch back through a phrase.
  </p>
</div>

<div class="feature">
  <p class="eyebrow">Practice ramp</p>
  <h2>From slow to tempo, automatically</h2>
  <p>
    Press <kbd>⌘P</kbd> for a separate window that plays your loop over and over
    while the speed climbs. Give it a start speed, an end speed and a number of
    repetitions; it works out the per-repetition step and shows it. It
    <strong>advances when the loop comes round, not on a timer</strong>, so it
    cannot drift when the loop length or the speed changes underneath it. An end
    speed below the start speed ramps down, which is a real way to practise.
  </p>
</div>

<div class="feature feature--selection">
  <p class="eyebrow">Track marks</p>
  <h2>One-file albums, navigable</h2>
  <p>
    A single FLAC of a whole record is a wall with no landmarks. Artscripture reads
    the <code>.cue</code> sheet sitting beside it and draws a lane showing where
    each track begins. <kbd>T</kbd> shows and hides it.
  </p>
</div>

<div class="feature">
  <p class="eyebrow">Sessions</p>
  <h2>A sidecar you can read</h2>
  <p>
    <kbd>⌘S</kbd> writes a plain <code>.artscribe</code> file next to your audio,
    holding the loop, the speed, the pitch, the playhead and the viewport. It is
    JSON, so you can read it, diff it and hand-edit it — and reopening the track
    picks up exactly where you left off. Every field is optional, so a
    hand-edited or truncated file is repaired field by field rather than thrown
    away.
  </p>
</div>

<div class="feature">
  <p class="eyebrow">Formats</p>
  <h2>Decoded natively, nothing bundled</h2>
  <p>
    MP3, AAC, M4A/MP4, ALAC, FLAC (including 24-bit), WAV, AIFF, CAF, Ogg Vorbis
    and Opus — all decoded by the operating system. No ffmpeg, no bundled codecs.
    <em>Ogg Vorbis is macOS only; iPadOS cannot decode it.</em>
  </p>
</div>

<div class="feature">
  <p class="eyebrow">Privacy</p>
  <h2>Nothing leaves your machine</h2>
  <p>
    Artscripture has no accounts, no analytics, no telemetry and no network code of
    any kind. Your audio is read from disk and never transmitted anywhere. See
    the <a href="{{ '/privacy/' | relative_url }}">privacy policy</a> — it is
    short, because there is very little to say.
  </p>
</div>

<div class="feature">
  <p class="eyebrow">Getting it</p>
  <h2>Download, or build it yourself</h2>
  <p>
    Signed, notarised builds are on the
    <a href="{{ site.releases_url }}">releases page</a>: unzip and drag
    <code>Artscripture.app</code> to <code>/Applications</code>. It needs
    <strong>macOS 26 on Apple Silicon</strong>.
  </p>
  <p>
    <strong>iPadOS is in preparation for the App Store</strong> and is not
    published yet. It builds and runs from the same tree today — the whole
    source is on <a href="{{ site.repo_url }}">GitHub</a> under Apache-2.0.
  </p>
  <p class="actions">
    <a class="button" href="{{ site.download_url }}">Download for macOS</a>
    <span class="aside"><a href="{{ '/docs/' | relative_url }}">Read the docs →</a></span>
  </p>
</div>

</section>
