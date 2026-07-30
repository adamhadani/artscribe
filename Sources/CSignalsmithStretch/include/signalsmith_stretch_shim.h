// A flat C surface over Signalsmith Stretch, which is a C++ class template.
//
// ## Why this file exists at all
//
// `SignalsmithStretch<Sample>::process` is a template on its argument types:
//
//     template<class Inputs, class Outputs>
//     void process(Inputs &&inputs, int inputSamples, Outputs &&outputs, int outputSamples);
//
// `Inputs` and `Outputs` are duck-typed on `operator[]` — anything for which
// `inputs[channel][frame]` compiles will do. Swift's C++ interop cannot
// instantiate an arbitrary template from Swift, so *something* has to name the
// concrete types on the C++ side. That is all this shim does: it instantiates
// the template against plain `float` pointer tables and hands the result out
// through `extern "C"`.
//
// It deliberately holds no buffering, no ratio arithmetic and no policy. Those
// live in `SignalsmithStretcher.swift`, where they are readable and testable in
// the same language as the rest of the project. If you find yourself adding
// state here, it probably belongs there instead.
//
// ## The pointer conventions match `TimeStretcher`
//
// Planar, one pointer per channel, `channels` entries in the table. Every
// pointer is `_Nonnull`: unlike `PlaybackEngine`'s render table, whose channel
// entries may legitimately be null when a device does not want a channel, the
// Swift wrapper owns both tables here and always fills them.

#ifndef SIGNALSMITH_STRETCH_SHIM_H
#define SIGNALSMITH_STRETCH_SHIM_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SignalsmithStretchShim SignalsmithStretchShim;

/// Allocates. Returns null only if the C++ allocation throws.
SignalsmithStretchShim *_Nullable ss_stretch_create(void);
void ss_stretch_destroy(SignalsmithStretchShim *_Nullable shim);

/// Allocates, and must be called before anything below. `cheaper` selects the
/// library's own `presetCheaper` over `presetDefault` — a shorter analysis
/// block, so less CPU and lower quality.
///
/// `splitComputation` spreads each spectral block's work across the `process`
/// calls that follow it instead of doing it all in the call that triggers it.
/// It costs one interval of extra output latency and removes the periodic CPU
/// spike, which is the trade a real-time render thread wants.
void ss_stretch_configure(SignalsmithStretchShim *_Nonnull shim, int channels,
                          double sampleRate, bool cheaper, bool splitComputation);

/// Analysis latency, in *input* frames.
int ss_stretch_input_latency(const SignalsmithStretchShim *_Nonnull shim);
/// Synthesis latency, in *output* frames. The two are separate and are not
/// interchangeable — see `SignalsmithStretcher.startDelay`.
int ss_stretch_output_latency(const SignalsmithStretchShim *_Nonnull shim);

/// Frequency multiplier: 2.0 is an octave up. Independent of the time ratio,
/// which for this library is expressed by the sample counts handed to
/// `ss_stretch_process` rather than by any setter.
void ss_stretch_set_transpose_factor(SignalsmithStretchShim *_Nonnull shim, float multiplier);

/// Drops all internal state. **Never call this at a loop boundary** — see the
/// note in `SignalsmithStretcher.reset()`.
void ss_stretch_reset(SignalsmithStretchShim *_Nonnull shim);

/// Consumes exactly `inputSamples` and produces exactly `outputSamples`. The
/// ratio between them *is* the time ratio for this call; there is no setter.
void ss_stretch_process(SignalsmithStretchShim *_Nonnull shim,
                        const float *_Nonnull const *_Nonnull inputs, int inputSamples,
                        float *_Nonnull const *_Nonnull outputs, int outputSamples);

/// Drains the tail with no further input. `playbackRate` is input frames per
/// output frame — the reciprocal of `TimeStretcher.timeRatio`.
void ss_stretch_flush(SignalsmithStretchShim *_Nonnull shim,
                      float *_Nonnull const *_Nonnull outputs, int outputSamples,
                      float playbackRate);

#ifdef __cplusplus
}
#endif

#endif  // SIGNALSMITH_STRETCH_SHIM_H
