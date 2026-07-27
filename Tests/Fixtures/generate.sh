#!/usr/bin/env bash
# Regenerates the small test fixtures. Requires ffmpeg and afconvert.
#
# Every *committed* fixture must stay well under 100 KB (raw 2-second stereo
# PCM at 44.1kHz/16-bit alone is ~350 KB, so the masters used to derive the
# compressed fixtures are >1s (as several tests require) but are temporary
# and never committed; only the small derived files and one short raw WAV
# are written to disk under fixed names.
set -euo pipefail
cd "$(dirname "$0")"

masters=(_master16.wav _master24.wav)
cleanup() { rm -f "${masters[@]}"; }
trap cleanup EXIT

# ffmpeg's `sine` source is not full-scale: mono output sits at -18 dBFS, and
# mono->stereo upmix (-ac 2) applies a further ~3 dB pan-law attenuation,
# landing around -21 dBFS (amplitude ~0.09). A `+18dB` boost brings that to
# about -3 dBFS (amplitude ~0.7): comfortably above any "is there a real
# signal" threshold and comfortably below clipping.
boost="volume=18dB"

# --- 16-bit master: only used to derive the compressed fixtures below. ---
# 2s so every compressed format decodes to more than 1 second of audio,
# as `decodesEveryNativeFormat` requires.
ffmpeg -y -loglevel error -f lavfi \
  -i "sine=frequency=440:duration=2:sample_rate=44100" -ac 2 -af "$boost" -c:a pcm_s16le _master16.wav

ffmpeg -y -loglevel error -i _master16.wav -c:a libmp3lame -b:a 192k sine.mp3
ffmpeg -y -loglevel error -i _master16.wav -c:a flac sine.flac
ffmpeg -y -loglevel error -i _master16.wav -c:a libopus sine.opus
ffmpeg -y -loglevel error -i _master16.wav -ac 2 -c:a vorbis -strict -2 sine.ogg
afconvert -f m4af -d aac _master16.wav sine.m4a

# --- Short raw PCM fixture, committed directly for the WAV-decode test. ---
# 0.4s keeps a 16-bit stereo WAV at ~69 KB.
ffmpeg -y -loglevel error -f lavfi \
  -i "sine=frequency=440:duration=0.4:sample_rate=44100" -ac 2 -af "$boost" -c:a pcm_s16le sine.wav

# --- 24-bit master: only used to derive the bit-depth regression fixture. ---
# 0.75s keeps the FLAC well under 100 KB while leaving plenty of samples.
ffmpeg -y -loglevel error -f lavfi \
  -i "sine=frequency=440:duration=0.75:sample_rate=44100" -ac 2 -af "$boost" -c:a pcm_s24le _master24.wav
ffmpeg -y -loglevel error -i _master24.wav -c:a flac -sample_fmt s32 sine24.flac

# --- Two-tone stereo fixture: L and R carry genuinely different content. ---
# Every fixture above is a mono sine identically upmixed to both channels, so
# L and R are byte-for-byte identical -- no test using them can tell a channel
# swap or a misaligned deinterleave index from correct output. Two independent
# mono generators merged via `amerge` give distinguishable per-channel content
# (440 Hz left, 660 Hz right) that a swap or misalignment would fail.
# `amerge`'s two independent sources aren't pan-law-attenuated the way a
# mono->stereo upmix is, so they start around -18 dBFS already; +15dB (not
# +18dB) lands at the same ~-3 dBFS/~0.7 amplitude used everywhere else,
# rather than clipping.
ffmpeg -y -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=1:sample_rate=44100" \
  -f lavfi -i "sine=frequency=660:duration=1:sample_rate=44100" \
  -filter_complex "[0:a]volume=15dB[l];[1:a]volume=15dB[r];[l][r]amerge=inputs=2[aout]" \
  -map "[aout]" -sample_fmt s16 -c:a flac sine_stereo_distinct.flac

ls -la
