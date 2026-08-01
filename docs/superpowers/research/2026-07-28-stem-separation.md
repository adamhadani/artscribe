# Stem separation for Artscripture — research and design

**Date:** 2026-07-28
**Status:** research only. No product code was written. Nothing here has been run on this machine.
**Scope:** answers the six questions in the brief: what is SOTA now, can we get piano as a stem,
licensing, on-device feasibility on Apple Silicon, whether selection-scoped separation is sound,
and a recommendation.

Constraints this must satisfy: spec §11.3 (single replaceable source accessor; identical ratios
and identical frame counts to every stretcher every quantum; CPU scales with stem count;
separation is offline, cached, background) and `CLAUDE.md` (module boundaries point one way;
no allocation/locks/`String` on the render thread; Artscripture is GPL-3.0-or-later).

---

## 0. How to read the confidence markers

This project has been burned by plausible-but-unmeasured claims, so every factual statement below
is tagged.

| Tag | Meaning |
|---|---|
| **[V]** | Verified locally in this session — I downloaded the source or the licence file and read it. |
| **[P]** | Published by a primary source (upstream repo, arXiv paper, model card). Not independently checked. |
| **[S]** | Secondary source: a blog, an SEO comparison site, a forum post. Directionally useful, individually unreliable. |
| **[I]** | My inference from **[V]**/**[P]** facts. Explicitly not measured. Each one carries a note on how to measure it. |

The single most important thing in this document is §5, and the second most important is that
**§7's first task is a measurement, not a feature**. The wall-clock number decides what the product is.

---

## 1. What is actually state of the art, July 2026

### 1.1 The short version

The field split into two lineages after 2022 and they have not re-merged:

- **Demucs lineage** (waveform + spectrogram hybrid, U-Net with a transformer bottleneck).
  Plateaued at HTDemucs (Demucs v4) around **9.0–9.2 dB** average SDR on MUSDB18-HQ **[P]**.
  Meta has shipped no successor; the repo's last model additions are the v4 family **[V]**.
- **Band-split / RoFormer lineage** (BS-RoFormer, Mel-Band RoFormer, and derivatives), out of
  ByteDance originally. This is where the SOTA number lives: **9.80 dB** average SDR on
  MUSDB18-HQ trained on MUSDB alone, **11.99 dB** with 500 extra songs, which won the SDX23
  Music Separation track **[P]**. Mel-Band RoFormer beats BS-RoFormer on vocals, drums and other **[P]**.

Everything below HTDemucs — Open-Unmix, Spleeter — is now a historical footnote on quality, and
Spleeter in particular is two full generations behind. It is fast and small; that is its only
remaining argument.

Nothing in 2026 has displaced the RoFormer family for *deterministic* separation. The 2026 papers
that beat it do so by bolting a **diffusion refinement stage** on top (arXiv:2412.06965, v2 dated
2026-04-26, reports SOTA by refining BS-RoFormer output with a diffusion model **[P]**). **That
approach is disqualified for Artscripture on the same grounds §11.3 already gives for generative
stretchers**: a diffusion refiner invents plausible detail, and the user would be transcribing the
model's invention. Do not use it, however good the SDR looks.

### 1.2 Comparison table

SDR figures come from different test sets and are **not** directly comparable across rows. I have
labelled the set for each. "MUSDB avg" = mean over vocals/drums/bass/other on MUSDB18-HQ test.
"Multisong" = MVSEP's own larger private-ish benchmark, which the practitioner community now
treats as the working leaderboard because MUSDB18 is saturated and partially in everyone's
training set.

| Model | Year | Stems | Quality | Params / size | Code licence | Weights licence | Verdict |
|---|---|---|---|---|---|---|---|
| **HTDemucs (`htdemucs`)** | 2022 | 4 | 9.00 dB MUSDB avg **[P]** | ~41M; ONNX 316 MB fp32 / 166 MB fp16 **[S]** | MIT **[V]** | MIT **[V]** | **Usable** |
| **HTDemucs fine-tuned (`htdemucs_ft`)** | 2022 | 4 | 9.20 dB MUSDB avg **[P]**; multisong bass 12.05 / drums 11.24 / vocals 8.33 / other 5.74 **[P]** | 4× a bag of 4 models; 641 MB **[P]** | MIT **[V]** | MIT **[V]** | **Usable**, 4× slower |
| **HTDemucs 6-source (`htdemucs_6s`)** | 2023 | **6 incl. piano + guitar** | 4-stem quality ≈ `htdemucs`; **piano is bleedy and artefacty by upstream's own admission** **[P]** | ONNX 258 MB fp32 / 136 MB fp16 **[P]** | MIT **[V]** | MIT **[V]** | **Usable — the only distributable piano model** |
| **BS-RoFormer** | 2023 | 4 | 9.80 dB MUSDB avg (no extra data); 11.99 dB with extra **[P]**; 9.65 in ZFTurbo's eval **[P]** | 72M (L=6) / 93.4M (L=12) **[S]** | MIT (lucidrains reimpl.) **[P]** | **No official weights released by ByteDance** | Architecture usable, weights are the problem |
| **Mel-Band RoFormer** | 2023 | 2 (vocals/other) mostly | vocals 10.98 SDR, multisong **[P]** | ~? | MIT **[P]** | MIT (KimberleyJSN HF card) **[V]** | **Usable**, but vocals-only |
| **BS-RoFormer "SW" 6-stem** | 2024–25 | **6 incl. piano + guitar** | multisong: vocals 11.30, bass 14.62, drums 14.11, guitar 9.05, **piano 7.83** **[P]** | 0.2B params; ONNX 669 MB fp32 / 336 MB fp16 **[P]** | — | **Unknown / broken chain — see §3.3** | **Not distributable** |
| **SCNet / SCNet-L** | 2024 | 4 | 9.0 dB MUSDB avg without extra data; CPU inference 48% of HTDemucs **[P]** | small | Apache/MIT (varies by fork) | varies | Interesting, weights need per-checkpoint checking |
| **Banquet (query-bandit)** | 2024 | arbitrary, incl. **piano** | beats 6-stem HTDemucs on guitar and piano on MoisesDB **[P]** | 24.9M trainable **[P]** | MIT **[V]** | **CC BY-NC-SA 4.0** **[V]** | **Not distributable** |
| **SCNet + ACMID (7-stem)** | 2025-10 | 7 incl. **piano** | piano 4.36 dB, avg 4.63 dB on their own set **[P]** | — | unstated **[P]** | unstated **[P]** | Not usable as-is |
| **Moises-Light** | 2025-10 | 4 | ~9.96 dB avg SDR, beats SCNet-L with half the params **[P]** | small | research paper | not released as far as I can find | Watch, not use |
| **Open-Unmix (`umxl`)** | 2019/21 | 4 | vocals 7.21, bass 6.02, drums 7.15, other 4.89 **[P]** | small | MIT **[V]** | **CC BY-NC-SA 4.0** **[V]** | **Not distributable**, and outclassed anyway |
| **Spleeter** | 2019 | 2/4/5 (5th is piano) | far behind; no credible modern SDR | MIT **[V]** | not explicitly stated in repo **[V]** | Obsolete — see §2.3 |

A note on the "2026 benchmark" pages that dominate search results for these queries
(aistemsplitter.org, stemsplit.io, stemsplitter.github.io, StemSplitio's HF collections): they are
SEO content farms with a commercial interest, and several of their numbers are recycled from the
Demucs README. I have used them only where a claim is checkable elsewhere, and marked those rows **[S]**.
The StemSplitio ONNX model cards are the exception — they carry concrete artefact metadata (file
sizes, opsets, tensor shapes) that is self-consistent and matches upstream, so I have used those.

---

## 2. Five stems including piano

### 2.1 The honest answer

**Yes, it exists; no, it is not good.**

There are exactly three families that produce a distinct piano stem, and only one of them has a
licence chain we can distribute:

1. **`htdemucs_6s`** — vocals / drums / bass / other / **guitar** / **piano**. MIT code, MIT
   weights **[V]**. Upstream's own README describes the piano source as "not working great",
   and independent reports agree: "okay quality for guitar, but a lot of bleeding and artifacts
   for the piano source" **[P]/[S]**.
2. **BS-RoFormer-SW 6-stem** — genuinely better piano (7.83 dB multisong vs. htdemucs_6s's
   unpublished-but-worse **[P]**), and the community's preferred 6-stem model. **Provenance is
   broken; see §3.3. Cannot be shipped.**
3. **Banquet** and the **ACMID/SCNet 7-stem** work — research-grade, better piano than
   `htdemucs_6s` on paper, but CC BY-NC-SA and unstated-licence weights respectively. **Cannot be
   shipped.**

### 2.2 Is a piano-capable model worth a quality trade elsewhere?

**[I]** For Artscripture specifically, mostly yes, with a caveat. `htdemucs_6s` and `htdemucs` share
an architecture and training set; the 6-stem variant just carves piano and guitar out of `other`.
When you sum the 6-stem model's piano + guitar + other back together it is directly comparable to
its 4-stem sibling and lands very close **[S]**. So the "trade" is not a quality cliff on
drums/bass/vocals — it is a modest one, and you also get the option of *not using* the piano output.

The caveat is that a bleedy piano stem is a **worse** transcription aid than no piano stem, because
it invites the user to trust an isolated line that has a guitar's overtones in it. That is the same
category of failure as a generative stretcher. So: ship `htdemucs_6s`, expose piano and guitar, and
**label them as experimental in the UI** rather than presenting six equal stems.

### 2.3 The two facts about Spleeter's "5 stems"

Spleeter's 5-stem model does include piano, which is how it keeps appearing in "which model gives
you piano" listicles. Two things kill it: the quality is two generations behind everything above,
and the repo's own README states only that **"The code of Spleeter is MIT-licensed"** **[V]** —
it is conspicuously silent on the pretrained models. Historically Deezer stated the models were
under a separate, more restrictive grant. Do not build on it without a lawyer, and there is no
quality reason to want to.

---

## 3. Licensing — the hard constraint

Artscripture is **GPL-3.0-or-later** and already links GPL-2.0-or-later Rubber Band. Two consequences
that cut in opposite directions:

**In our favour:** a GPL-licensed model is *fine here*. Most commercial audio products cannot touch
GPL weights; Artscripture can. Copyleft weights widen our field rather than narrowing it.

**Against us:** anything **non-commercial** (CC BY-NC-SA, "research only") is not free software and
is GPL-incompatible. It cannot be bundled, and it cannot be auto-downloaded by the app on first run
either — the download is still distribution in substance, and the NC term binds the user regardless.

### 3.1 Verdicts

| Candidate | Code | Weights | Distributable in a GPL-3.0 app? |
|---|---|---|---|
| `htdemucs`, `htdemucs_ft`, `htdemucs_6s` | MIT **[V]** | MIT **[V]** | **Yes.** MIT → GPL-3.0 is the textbook compatible direction. |
| Demucs → ONNX export (Mixxx GSoC 2025, merged upstream) | MIT **[P]** | MIT | **Yes.** |
| Mel-Band RoFormer (KimberleyJSN) | MIT **[P]** | MIT, per the HF model card **[V]** | **Yes**, but vocals-only. A search result claims it was GPL-3.0 until 2026-04-22 and then relicensed to MIT **[S]** — either state is fine for us. |
| ZFTurbo `Music-Source-Separation-Training` | MIT **[V]** | **Per-checkpoint. The repo licence does not cover them** — the checkpoints are third-party community weights hosted on HF and GitHub releases, and the docs page states no licence at all **[V]**. | **Only per checkpoint, each checked individually.** |
| BS-RoFormer-SW 6-stem | — | **See §3.3** | **No.** |
| Banquet | MIT **[V]** | **CC BY-NC-SA 4.0** (Zenodo record 13694558, 2024-09-05) **[V]** | **No.** |
| Open-Unmix `umxl` | MIT **[V]** | **CC BY-NC-SA 4.0**, stated in the repo **[V]** | **No.** |
| Spleeter | MIT **[V]** | Not stated **[V]** | **No** — absence of a grant is not a grant. |
| ACMID / SCNet 7-stem | unstated **[P]** | unstated **[P]** | **No**, unless the authors clarify. |

### 3.2 The general trap the brief warned about, confirmed

The code/weights split is real and it bites exactly where you would not want it to. **Open-Unmix
and Banquet both have MIT code and non-commercial weights.** If you had only checked the repo
badge you would have shipped an NC model in a GPL app. Check the weights every time, at the file
they are actually downloaded from.

### 3.3 BS-RoFormer-SW: the interesting failure

This is the model the community regards as the best open 6-stem separator, and it is the one you
would most want. Its licence chain does not survive contact:

- The ONNX rehost's own model card states the weights **"were rehosted by jarredou without a stated
  license"** and that **"the original rehost owner has confirmed they were not involved in training
  and have no provenance information."** **[V]**
- The rehost is nonetheless *tagged* MIT on Hugging Face, and a GGUF re-conversion downstream
  inherits that MIT tag and adds "review the upstream repository and license before use" **[V]**.
- ByteDance published the BS-RoFormer **paper** but never released official weights **[P]**.

So: an MIT tag applied by someone who states they do not know who trained the model and had no part
in it. **You cannot license what you do not own.** This is an unlicensed artefact wearing an MIT
label, and shipping it in a GPL-3.0 binary would put a defect in Artscripture's own licence chain —
a distributed GPL work must come with a valid grant for every part of it.

**Verdict: do not ship it.** Not bundled, not auto-downloaded. If a user points Artscripture at a
local checkpoint file themselves, that is their act and their risk, and a "load a custom model
file" affordance is a legitimate escape hatch — but it must not be a curated in-app list.

---

## 4. On-device feasibility on Apple Silicon

### 4.1 The four runtime options, assessed honestly for a Swift app

**A bundled PyTorch — rejected outright.** It means shipping a Python interpreter and ~2 GB of
wheels inside a Mac app bundle, and Artscripture's whole distribution story (§README) is a
self-contained arm64 bundle with two Homebrew dylibs re-pointed at `@rpath`. Adding Python would
be the single largest thing in the product. No.

**ONNX Runtime — the strongest option.** Microsoft ships an official
[SwiftPM package](https://github.com/microsoft/onnxruntime-swift-package-manager) with the native
runtime as a binary dependency **[P]**, and a CoreML execution provider that requires macOS 10.15+
**[P]** — trivially satisfied by our macOS 26 floor. Critically, **the STFT problem is solved
upstream**: Mixxx's GSoC 2025 project (published 2025-10-27) exported Demucs v4 as a fully
self-contained ONNX graph by re-expressing STFT/ISTFT as 1-D convolutions with precomputed
sine/cosine kernels, achieving **MSE < 1e-4 against PyTorch with no retraining**, and the work was
merged into the upstream Demucs repository **[P]**. Their measured numbers: on 50 MUSDB tracks
(3.46 h of audio) the C++ ONNX path was **17.9% faster than PyTorch on CPU** (4,415 s vs 5,380 s)
and 8.4% slower on an NVIDIA GPU (386 s vs 354 s), with SI-SDR identical to two decimal places
(7.43 vs 7.44 dB) **[P]**. Pre-built `htdemucs_6s` ONNX artefacts also exist publicly: 258 MB fp32,
136 MB fp16, opset 17, input `(1,2,343980)` = 7.8 s stereo at 44.1 kHz, output `(1,6,2,343980)`
in the order drums, bass, other, vocals, guitar, piano **[P]**.

**MLX — fast, but Python-shaped.** `demucs-mlx` (MIT) converts all eight Demucs checkpoints
including `htdemucs_6s`, and reports **2.7 s for a 3:15 track on an M4 Max**, 2.6× faster than
PyTorch/MPS and ~73× realtime **[P]**. `mlx-audio-separator` (MIT) extends this to Roformer, MDXC,
MDX and VR families and reports a median 1.85× speedup over `audio-separator` on an M4 mini **[P]**.
The problem: **both are Python-only** — `mlx-audio-separator`'s docs say so explicitly **[V]**, and
the Swift port referenced in one search summary (`ssmall256/demucs-mlx-swift`) **returns HTTP 404
— it does not exist** **[V]**. MLX-Swift itself is real and could host a hand-written port, but that
is a substantial from-scratch reimplementation of HTDemucs in Swift, which is not the project to
start with.

**CoreML directly — possible, awkward, and probably unnecessary.** CoreML's MIL has no complex
dtype, so HTDemucs's opening STFT (which returns complex64) cannot be converted naively; the known
workarounds split real/imag into channels, decompose multi-head attention manually and precompute
overlap-add **[P]**. Since ONNX Runtime's CoreML EP gets you CoreML acceleration without doing that
conversion by hand, direct CoreML is only worth revisiting if the EP measurably fails to offload.

### 4.2 Size and memory

| Artefact | Size | Peak RAM |
|---|---|---|
| `htdemucs_6s` ONNX fp32 | 258 MB **[P]** | ~1.1 GB reported on an M4 Pro CPU **[P]** |
| `htdemucs_6s` ONNX fp16 weights | 136 MB **[P]** | lower; unmeasured |
| `htdemucs` ONNX fp32 / fp16 | 316 / 166 MB **[S]** | — |

**[I]** 136 MB fp16 is small enough to bundle inside `Artscripture.app`, which sidesteps a
first-run download and the licence-hygiene questions that come with one. 258 MB is also bundleable
but starts to feel rude. Decide after measuring whether fp16 costs any audible quality.

**[I]** ~1.1 GB peak for separation plus the existing ~200 MB resident per loaded track (spec §12)
is fine on any Apple Silicon Mac, but separation must not run concurrently with a second separation
job. One at a time, queued.

### 4.3 Wall-clock for a 10-minute track on an M2 Max

**No number here was measured on this machine. This is the single most important thing to measure
first.** What the published data points bracket:

| Source | Hardware | Implied cost for 10 min of audio |
|---|---|---|
| htdemucs_6s ONNX, RTF 0.20, 1.6 s per 7.8 s segment **[P]** | M4 Pro, **CPU only** | ~120 s at zero overlap; **~160 s at the default 0.25 overlap** |
| "four-minute track in 90 seconds" **[S]** | M2/M3, MPS | ~225 s |
| `demucs-mlx`, 3:15 track in 2.7 s **[P]** | M4 Max GPU, 128 GB | ~8 s |
| Mixxx GSoC, 3.46 h in 354–386 s **[P]** | NVIDIA GPU | ~17 s |

**[I] My estimate for `htdemucs_6s` on an M2 Max, ONNX Runtime with the CoreML EP, overlap 0.25,
shifts 0: 60–180 seconds for a 10-minute track.** I would plan the UX around ~2 minutes and be
pleased if it is 30 s. The `demucs-mlx` figure implies it could be far faster; I distrust it as a
single vendor benchmark on the fastest available chip, and it is Python-only anyway.

**[I] BS-RoFormer-family models are materially slower** — 93M–200M params against HTDemucs's ~41M,
and the SW ONNX card explicitly warns of **O(T²) attention** **[P]**. Expect 3–5×, i.e. 5–15 minutes
for a 10-minute track. That difference alone is a product decision: two minutes is "go make coffee",
ten minutes is "I'll do it tomorrow". It reinforces the Demucs recommendation independently of
licensing.

**What this means for UX.** At ~2 minutes, separation is a background job with a progress
breadcrumb and a disk cache — exactly the treatment §11.3 already prescribes for it, and the same
treatment decode already gets. It is *not* fast enough to be interactive, which is what makes §5's
question load-bearing.

---

## 5. The selection-scoped question

The user asked: if a selection is made and we run separation, can it apply to just that part?

**Answer: the model-side objection is real for some models and absent for Demucs, and I can show
exactly why from the source. But the right product answer is still "no, don't scope the *result*
to the selection" — scope the *work order* instead.** Both halves matter, so here is each.

### 5.1 What I verified in the Demucs source

I downloaded `demucs/apply.py` and `demucs/htdemucs.py` from `facebookresearch/demucs@main` and
read them **[V]**:

1. **There is no track-global normalisation.** `apply_model` does not compute any statistic over
   the whole mix. I grepped for it specifically because older Demucs generations did have one.
2. **Normalisation is per-chunk, inside the forward pass.** `htdemucs.py` lines 544–547:
   ```python
   # unlike previous Demucs, we always normalize because it is easier.
   mean = x.mean(dim=(1, 2, 3), keepdim=True)
   std  = x.std(dim=(1, 2, 3), keepdim=True)
   x = (x - mean) / (1e-5 + std)
   ```
   with the matching time-branch statistics at 552–554 and the inverse at 626/656. The statistics
   come from the chunk being processed, not the track.
3. **Inference is already a sliding window with no state carried between windows.** In `apply.py`:
   `segment_length = int(model.samplerate * segment)`, `stride = int((1 - overlap) * segment_length)`,
   `offsets = range(0, length, stride)`, each chunk submitted independently to a thread pool, and
   the outputs overlap-added under a triangular weight raised to `transition_power`, then divided
   by the accumulated `sum_weight`. There is no recurrence, no cache, no cross-chunk attention.
4. **Chunks that run off the ends of the track are zero-padded**, not reflected: `TensorChunk.padded`
   ends in `F.pad(self.tensor[..., correct_start:correct_end], (pad_left, pad_right))`, and
   `F.pad`'s default mode is constant zero.
5. **The `shifts` trick is random**: `offset = random.randint(0, max_shift)` with
   `max_shift = int(0.5 * model.samplerate)`. With `shifts > 0` the same input does not give the
   same output twice.

**Consequences, and these are strong ones:**

- The "these models need temporal context" worry is **bounded and small for Demucs — one segment,
  7.8 s.** It is not a whole-track dependency. The model literally cannot see beyond its 7.8 s window.
- A window separated in isolation, **with at least one segment of real audio as context on each
  side, and with the chunk grid aligned to the same absolute sample offsets the full-track run
  would use**, should produce output in the interior that is *identical* to the full-track run.
  **[I]** — this follows directly from 1–3 but I have not run it. See §7 task 2.
- Padding a selection with *real neighbouring audio* is **strictly better conditioned** than what
  the model already does at the start and end of every track, which is pad with silence. So a
  context-padded selection run is not a degraded mode; it is the normal mode.
- **`shifts` must be 0.** Non-determinism in a transcription tool means the stem you looped
  yesterday is not the stem you loop today, and it would also break the caching scheme in §5.4.
  The 0.2 dB it buys is not worth it **[P]**.

### 5.2 What I verified about the RoFormer inference path — the counterexample

I downloaded ZFTurbo's `utils/audio_utils.py`, `utils/model_utils.py` and `inference.py` **[V]**.
Its RoFormer path *does* have a genuine whole-track dependency:

```python
def normalize_audio(audio):
    mono = audio.mean(0)
    mean, std = mono.mean(), mono.std()
    return (audio - mean) / std, {"mean": mean, "std": std}
```

called on the **entire mix** before demixing when `config.inference.normalize` is true, and undone
after. Chunking itself is stateless in the same way Demucs's is (`chunk_size` ~8 s, `num_overlap`
2–4, linear fade-in/out window with the fades flattened on the first and last chunk) **[V]**.

So for that family, a window separated alone would be normalised by *its own* loudness rather than
the track's, and a quiet intro would go into the model at a different level than it would have in a
full-track run — which for a nonlinear model changes the output. **The fix is trivial and worth
recording**: compute the mean/std from the whole decoded track (one cheap pass, we already have the
samples in memory) and apply those to the window. That removes the dependency completely.

**Generalisable rule for adding any future model: the question is not "does it need context" but
"does it compute any statistic over material outside the window". Context is bounded and can be
padded. Global statistics must be lifted out and computed track-wide.**

### 5.3 Why selection-scoped *results* are still the wrong product

Even granting §5.1, splicing a separated region against unseparated audio has two problems, one
technical and one about what the user hears.

**Technical: the stems do not sum to the mix.** HTDemucs is a direct-estimation model, not a
masking model — each source head predicts a waveform outright, and nothing constrains their sum to
equal the input. **[I]** So even with every stem unmuted at unity gain, the "remix" of a separated
region is *not* sample-identical to the original audio, and butting it against unseparated audio
gives a discontinuity at the seam. The magnitude is unmeasured and might be inaudible; the project's
own history with loop seams (`CLAUDE.md`) says the honest move is to measure the residual rather than
assume, and that a step threshold is a worse test than a differential one.

**About what the user hears: soloing across a boundary is incoherent.** Solo the piano over a
selection and the audio outside it is the full band. That is not a subtle artefact; it is a
level and timbre jump twice per loop, in a tool whose entire purpose is looping. And the boundary
lands wherever the user happened to drag, which is a moving target.

### 5.4 What to do instead — selection as a *priority*, not an *extent*

Keep the result track-wide; let the selection decide **what gets computed first**.

- Separation produces a **track-level artefact**: a full set of stem buffers, cached on disk, keyed
  by (source file content hash, model ID, model version, inference parameters). Runs once per track,
  not once per open — as §11.3 already requires.
- Define a **canonical chunk grid** for the track: offsets `k * stride` from sample 0, exactly the
  grid `apply.py` would use. Every chunk's output depends only on its own 7.8 s of input **[V]**,
  so **the order in which chunks are computed cannot change the result.** That is the property
  that makes everything below work.
- When the user hits Separate with a selection active, **enqueue the chunks covering the selection
  (plus one segment of context each side) first**, then the rest of the track in the background.
  The user hears stems over their passage in a few seconds instead of two minutes, which is the
  responsiveness they were actually asking for.
- A region is **ready** only once every chunk whose window overlaps it has landed, because the
  overlap-add `sum_weight` divisor is not correct until then **[V]**. Track a ready-interval set;
  show it as a subtle fill on the timeline. Unready regions play the undivided source.
- **Never crossfade separated against unseparated audio mid-playback.** Playing a stem mix over a
  region that is not yet separated is a state the UI reports ("still separating"), not a seam the
  audio path papers over.

This is strictly better than the literal request: same latency benefit, no boundary artefacts, no
incoherent solo, and the work is not thrown away when the user moves the selection.

**If a genuine selection-only export is ever wanted** (bounce this passage's stems to disk), that is
sound and should use exactly the §5.1 recipe: aligned grid, ≥ 1 segment of real context each side,
`shifts = 0`, discard the context region from the output.

---

## 6. Recommendation

### 6.1 Primary: `htdemucs_6s` via ONNX Runtime, CoreML execution provider

- **Licence: MIT code and MIT weights, verified at the source** — the only 5-plus-stem-with-piano
  option with a licence chain that survives inspection, and cleanly compatible with GPL-3.0-or-later.
- **The only distributable model that gives a piano stem at all**, which is the user's most
  interesting ask and plausibly the most valuable stem for transcription.
- **Fast enough to be a background job** (§4.3): estimated 1–3 minutes for a 10-minute track,
  against 5–15 for a RoFormer.
- **The hard engineering is already done upstream and merged**: the self-contained ONNX export with
  ONNX-native STFT/ISTFT, numerically equivalent to PyTorch at MSE < 1e-4 **[P]**. We are not the
  first people through this door.
- **No Python in the app bundle.** SwiftPM binary dependency, one C/Obj-C API, consistent with how
  Rubber Band is already consumed.
- Its per-chunk normalisation and stateless windowing (§5.1, verified) make the progressive,
  selection-first scheme in §5.4 provably order-independent — which no other candidate gives us
  without also lifting a global statistic out of its inference path.

Ship 6 stems, but **mark piano and guitar experimental in the UI.** Upstream says the piano source
is weak and the field agrees; presenting it as an equal peer of `drums` would mislead a transcriber,
which is the failure mode this product cares most about avoiding.

### 6.2 Fallback: `htdemucs` (4-stem) on the same runtime

Identical plumbing, one model file swapped, no piano. If the 6-stem piano output turns out to be
unusable in listening (a real possibility), we still ship vocals/drums/bass/other — which is the
majority of the value in §11.3's original framing, since the transient-smearing argument only needs
percussion separated from everything sustained. Because both are Demucs v4 with the same segment
length and grid, **this fallback costs a config change, not a rewrite.** Keep the stem list
data-driven from the start so that stays true.

Second-line option if quality on vocals specifically becomes the complaint: add **Mel-Band RoFormer
(KimberleyJSN, MIT weights [V])** as an *optional* vocals-refinement pass. It is vocals-only, so it
supplements rather than replaces, and its global-normalisation dependency (§5.2) must be lifted
track-wide if it is ever wired to the progressive scheme.

### 6.3 Explicitly rejected

| | Why |
|---|---|
| BS-RoFormer-SW 6-stem | Best piano available, **no valid licence grant** (§3.3). Not shippable at any quality. |
| Banquet, Open-Unmix `umxl` | MIT code, **CC BY-NC-SA weights** — non-free and GPL-incompatible. |
| Spleeter | Quality two generations behind; model licence unstated. |
| Diffusion-refined separators (arXiv:2412.06965) | **Generative.** Same disqualification §11.3 gives generative stretchers: the user would transcribe the model's invention. |
| Bundled PyTorch | ~2 GB and a Python interpreter inside a Mac app that currently ships two dylibs. |
| Hand-porting HTDemucs to MLX-Swift | The fastest published numbers, but it is a from-scratch reimplementation and the Swift port that search results reference does not exist (404, verified). Revisit only if ONNX Runtime measures badly. |

---

## 7. Implementation sketch, and what to build first

### 7.1 Module placement

New module **`StemSeparation`**, a sibling of `AudioDecode` / `Waveform` / `TimeStretch` — it may
import `ArtscribeKit` and its runtime dependency, and **must not import `Playback` or any UI**.

```
ArtscribeKit ← AudioDecode / Waveform / TimeStretch / StemSeparation ← Playback ← ArtscribeUI ← ArtscribeApp
```

Into **`ArtscribeKit`** (which imports nothing, not even Foundation) go the pure types:
`StemID` (an enum: `.vocals .drums .bass .guitar .piano .other`), `StemSet`, `StemMix` (per-stem
gain / mute / solo), and `SeparationGrid` (segment length, stride, offset-of-chunk-k arithmetic,
ready-interval bookkeeping). `SeparationGrid` is pure integer arithmetic and is where the §5.4
correctness argument lives, so it should be the most heavily unit-tested thing in the feature.

Into **`Playback`** goes the §11.3 requirement that is already on the books: **one** replaceable
source accessor. Two conformers — the current single-buffer one, and a stem-backed one holding N
buffers and a `StemMix`. The render block reads through that one accessor and nothing else. This
refactor is worth doing on its own merits *before* any separation exists, because it is the part
that must not be retrofitted through a scattered render path.

### 7.2 The N-stretcher discipline

Spec §11.3 is unambiguous and it is the easiest thing here to get subtly wrong. Concretely:

- One `StretchClock` computes `timeRatio` and `framesToFeed` **once** per render quantum and hands
  the *same* values to every stretcher. No stretcher may compute its own.
- Pre-size every instance with `setMaxProcessSize` at configure time, as the mono path already does,
  so nothing allocates while rendering.
- Guard it with a test that renders a long stretch and asserts every stretcher received an identical
  frame-count sequence — and, following `CLAUDE.md`'s lesson about step thresholds, make the
  *quality* guard a **differential** test rather than a threshold: render N stems separately and
  remix, render the same material through one stretcher, compare. Phasing is cumulative, so compare
  late in the render, not just at the start.
- CPU: six R3 instances is a very different budget from one. Expect to need R2 on unfocused stems
  or to pre-render. Measure before designing around either.

### 7.3 De-risking order — the first three tasks are all measurements

**Nothing above should be built until tasks 1 and 3 have numbers.**

1. **Measure the wall clock.** A throwaway CLI spike: ONNX Runtime via SwiftPM, `htdemucs_6s` fp16,
   a real 10-minute track, on this M2 Max, in **release**. Report wall clock, peak RSS, and — the
   part people forget — **whether the CoreML EP actually offloads the graph or silently falls back
   to CPU**. Every UX decision downstream (progress UI vs. spinner, bundle vs. download, 4-stem vs.
   6-stem default) depends on whether the answer is 30 s or 5 minutes. §4.3's 1–3 minute estimate
   is inference, not measurement, and this project's own notes record two false conclusions drawn
   from unmeasured performance claims.

2. **Falsify the selection-scoping claim.** Separate a full track. Then separate a 30 s window with
   8 s of real context each side on the aligned grid, `shifts = 0`. Compare interiors sample by
   sample. §5.1 predicts *identical*. If it is not identical, find out whether the difference is
   float non-determinism or a real dependency I missed, and the progressive scheme in §5.4 has to
   be re-derived. Also measure the stems-sum-minus-original residual (§5.3) while the data is there —
   it decides whether a seam is even audible.

3. **Prove the N-stretcher architecture before committing to it.** No ML needed: split a known
   signal into 6 parts, drive 6 Rubber Band instances with the identical-ratio/identical-frames
   discipline, remix, and compare against one stretcher on the sum. Should be near-zero. If it is
   not, the entire premise of §11.3's stem-stretching design is in question, and that is enormously
   cheaper to learn now than after the separation pipeline exists.

4. Only then: the source-accessor refactor in `Playback`, the `SeparationGrid` type and its tests,
   the background task with progress and disk cache, and the UI (stem lanes, solo/mute keys, the
   ready-region fill).

### 7.4 Open questions this research did not settle

- Whether fp16 weights cost audible quality versus fp32. Cheap to A/B once task 1 exists.
- The actual magnitude of the stems-sum residual (§5.3) — folded into task 2.
- Whether the CoreML EP handles the ONNX-ified STFT convolutions or partitions them back to CPU,
  which would change the wall clock a lot. Task 1 must report the partitioning, not just the total.
- Whether `htdemucs_6s`'s piano is usable enough to expose at all. This is a **listening** question
  on real material, not an SDR question, and it should be decided by ear before the UI is designed
  around six stems.

---

## Sources

Primary, verified locally in this session:
- [facebookresearch/demucs](https://github.com/facebookresearch/demucs) — `LICENSE` (MIT), `demucs/apply.py`, `demucs/htdemucs.py`
- [ZFTurbo/Music-Source-Separation-Training](https://github.com/ZFTurbo/Music-Source-Separation-Training) — `utils/audio_utils.py`, `utils/model_utils.py`, `inference.py`, `docs/pretrained_models.md`
- [Zenodo record 13694558](https://zenodo.org/records/13694558) — Banquet weights, CC BY-NC-SA 4.0, 2024-09-05
- [sigsep/open-unmix-pytorch](https://github.com/sigsep/open-unmix-pytorch) — MIT code, CC BY-NC-SA 4.0 weights
- [deezer/spleeter](https://github.com/deezer/spleeter) — MIT code, model licence unstated
- [kwatcharasupat/query-bandit](https://github.com/kwatcharasupat/query-bandit) — Banquet, MIT code
- [KimberleyJSN/melbandroformer](https://huggingface.co/KimberleyJSN/melbandroformer) — MIT
- [elicwhite/bs-roformer-sw-6stem-onnx](https://huggingface.co/elicwhite/bs-roformer-sw-6stem-onnx) — the provenance statement in §3.3
- `ssmall256/demucs-mlx-swift` — **404, does not exist**

Papers and primary write-ups:
- [Music Source Separation with Band-Split RoPE Transformer](https://arxiv.org/pdf/2309.02612) (BS-RoFormer)
- [Mel-Band RoFormer for Music Source Separation](https://arxiv.org/abs/2310.01809)
- [SCNet: Sparse Compression Network](https://arxiv.org/html/2401.13276v1)
- [Moises-Light](https://arxiv.org/html/2510.06785v1) (2025-10)
- [ACMID: 7-stem dataset curation](https://arxiv.org/html/2510.07840) (2025-10)
- [A Stem-Agnostic Single-Decoder System (Banquet)](https://arxiv.org/abs/2406.18747)
- [MoisesDB](https://archives.ismir.net/ismir2023/paper/000073.pdf)
- [Improving Music Source Separation with Diffusion and Consistency Refinement](https://arxiv.org/html/2412.06965) (v2, 2026-04-26) — the generative approach we reject
- [Mixxx GSoC 2025: Demucs v4 → ONNX](https://mixxx.org/news/2025-10-27-gsoc2025-demucs-to-onnx-dhunstack/) (2025-10-27)

Runtime and tooling:
- [microsoft/onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager)
- [ONNX Runtime CoreML Execution Provider](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)
- [ssmall256/demucs-mlx](https://github.com/ssmall256/demucs-mlx), [ssmall256/mlx-audio-separator](https://github.com/ssmall256/mlx-audio-separator), [mlx-community/demucs-mlx](https://huggingface.co/mlx-community/demucs-mlx)
- [StemSplitio/htdemucs-6s-onnx](https://huggingface.co/StemSplitio/htdemucs-6s-onnx) — artefact metadata
- [MVSEP algorithms leaderboard](https://mvsep.com/en/algorithms) — multisong SDR figures
