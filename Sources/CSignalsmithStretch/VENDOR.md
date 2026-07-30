# Vendored: Signalsmith Stretch

Third-party source, copied in verbatim. **Do not edit these files.** A local fix
would be silently reverted by the next update and would not exist upstream; if
something needs changing, change `signalsmith_stretch_shim.cpp` or report it
upstream.

## What is here, and where it came from

| Path | Upstream | Version | Licence |
|---|---|---|---|
| `vendor/signalsmith-stretch/` | [Signalsmith-Audio/signalsmith-stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) | 1.3.2 (`main`, Jan 2026) | MIT |
| `vendor/signalsmith-linear/` | [Signalsmith-Audio/linear](https://github.com/Signalsmith-Audio/linear) | 0.3.1 | MIT |

Licence texts are in `LICENSES/` at the repository root and are reproduced in
`NOTICE`, which is what ships.

**These are two repositories, not one.** `signalsmith-stretch.h` opens with

```cpp
#include "signalsmith-linear/stft.h" // https://github.com/Signalsmith-Audio/linear
```

and the stretch tarball does not contain it — upstream's CMake pulls it with
`FetchContent` at build time, pinned to tag 0.3.1. That is the version above.
Updating one library means checking the other, and the pin in upstream's
`CMakeLists.txt` is where to look for which pairing is intended.

Only the headers actually reached are copied: `stft.h`, `fft.h`, and
`platform/fft-accelerate.h`. `linear.h` is **not** here, deliberately — nothing
includes it, and its Accelerate backend has an `#include <iostream>` that logs to
stderr when an expression is unoptimised, which is not something to have anywhere
near a render thread.

## Refreshing

```sh
curl -sL https://github.com/Signalsmith-Audio/signalsmith-stretch/archive/refs/heads/main.tar.gz | tar xz
curl -sL https://github.com/Signalsmith-Audio/linear/archive/refs/tags/<tag>.tar.gz | tar xz
```

then copy the four headers into place and re-run the suites. `git diff` on this
directory is the upstream changelog you actually care about, which is the reason
the files are byte-identical to upstream and the reason the pre-commit
whitespace hooks exclude this directory.

## Findings from reading the source, worth not rediscovering

**No allocation on the render path, but only just.** `process()` calls
`tmpProcessBuffer.resize(length)` on every block; that is safe *because*
`configure()` already sized it to `blockSamples + intervalSamples` and `length`
can never exceed that, so `std::vector` keeps its capacity. It is a property of
the sizes, not a guarantee in the code. A future upstream change to either could
turn a resize into a reallocation on the audio thread without looking like it
changed anything.

**One theoretical exception.** `findPeaks()` does `peaks.emplace_back` into a
vector reserved at `bands/2` in `configure()`. Each peak consumes at least two
bands, so `bands/2` is exactly the bound when `bands` is even — which it is for
the packed spectrum this uses. An odd `bands` would make the worst case
`ceil(bands/2)` and could reallocate. Not reachable today; worth re-checking if
`stft.h`'s `_fftBins` calculation ever changes.

**`splitComputation` matters more to us than to upstream.** The library defaults
it *off* for `presetDefault`, which is right for offline work. Off means one call
per interval does an entire FFT block while its neighbours do almost none — a
periodic spike against a hard deadline. `SignalsmithStretcher` turns it on
always; see the comment there.

**Accelerate is available but not enabled.** Defining `SIGNALSMITH_USE_ACCELERATE`
makes `fft.h` pull in `platform/fft-accelerate.h` (vDSP), and that header is
already vendored so the switch is one `.define` plus `.linkedFramework`. It is
off for now because the backend landed with the plain C++ FFT and every number
recorded — pitch, length, latency, loop seam — was measured against that. Turn it
on as its own change, with its own before/after CPU measurement, so a regression
has one candidate cause rather than two.
