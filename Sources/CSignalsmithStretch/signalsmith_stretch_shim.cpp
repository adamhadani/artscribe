#include "signalsmith_stretch_shim.h"

#include <new>

#include "vendor/signalsmith-stretch/signalsmith-stretch.h"

// The one instantiation of the template, against plain pointer tables.
//
// `const float *const *` and `float *const *` already satisfy everything the
// library asks of `Inputs` and `Outputs` — it only ever writes `x[channel][i]`
// — so no adapter struct is needed. That is the whole reason this file is
// thirty lines rather than three hundred.
struct SignalsmithStretchShim {
  signalsmith::stretch::SignalsmithStretch<float> stretch;
};

extern "C" {

SignalsmithStretchShim *ss_stretch_create(void) { return new (std::nothrow) SignalsmithStretchShim(); }

void ss_stretch_destroy(SignalsmithStretchShim *shim) { delete shim; }

void ss_stretch_configure(SignalsmithStretchShim *shim, int channels, double sampleRate,
                          bool cheaper, bool splitComputation) {
  if (cheaper) {
    shim->stretch.presetCheaper(channels, static_cast<float>(sampleRate), splitComputation);
  } else {
    shim->stretch.presetDefault(channels, static_cast<float>(sampleRate), splitComputation);
  }
}

int ss_stretch_input_latency(const SignalsmithStretchShim *shim) {
  return shim->stretch.inputLatency();
}

int ss_stretch_output_latency(const SignalsmithStretchShim *shim) {
  return shim->stretch.outputLatency();
}

void ss_stretch_set_transpose_factor(SignalsmithStretchShim *shim, float multiplier) {
  shim->stretch.setTransposeFactor(multiplier);
}

void ss_stretch_reset(SignalsmithStretchShim *shim) { shim->stretch.reset(); }

void ss_stretch_process(SignalsmithStretchShim *shim, const float *const *inputs, int inputSamples,
                        float *const *outputs, int outputSamples) {
  shim->stretch.process(inputs, inputSamples, outputs, outputSamples);
}

void ss_stretch_flush(SignalsmithStretchShim *shim, float *const *outputs, int outputSamples,
                      float playbackRate) {
  shim->stretch.flush(outputs, outputSamples, playbackRate);
}

}  // extern "C"
