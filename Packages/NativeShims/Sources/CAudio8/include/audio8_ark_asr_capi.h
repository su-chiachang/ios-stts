#pragma once

#include <stddef.h>

#include "audio8_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct audio8_ark_asr audio8_ark_asr;

typedef struct audio8_ark_asr_options {
    int n_threads;
    int verbosity;
    int use_gpu;
    float temperature;
    int beam_size;
} audio8_ark_asr_options;

// Load an Audio8 ARK-ASR GGUF. The model accepts mono float32 PCM at 16 kHz.
// The returned context is owned by the caller and must be destroyed.
// `error` must be zero-initialized (or previously released with
// audio8_error_free) before the first call.
audio8_ark_asr * audio8_ark_asr_create(const char * model_path,
                                       const audio8_ark_asr_options * options,
                                       audio8_error * error);

void audio8_ark_asr_destroy(audio8_ark_asr * model);

// Returns non-zero on success and stores a malloc'd UTF-8 string in *text.
// Release *text with audio8_ark_asr_free_string.
int audio8_ark_asr_transcribe_pcm(audio8_ark_asr * model,
                                  const float * samples,
                                  size_t sample_count,
                                  char ** text,
                                  audio8_error * error);

void audio8_ark_asr_free_string(char * text);

#ifdef __cplusplus
} // extern "C"
#endif
