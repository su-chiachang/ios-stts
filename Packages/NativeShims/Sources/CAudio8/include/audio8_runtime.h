#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct audio8_runtime audio8_runtime;

typedef struct audio8_error {
    char * message;
} audio8_error;

typedef struct audio8_synthesis_request {
    const char * text;
    const char * reference_text;

    // Optional mono reference audio. Reference audio and reference_codes are
    // mutually exclusive. Positive input rates are resampled to 44,100 Hz.
    const float * reference_audio;
    size_t reference_audio_samples;
    uint32_t reference_audio_sample_rate;

    // Optional pre-encoded codebook-major matrix [10, reference_code_length].
    const int32_t * reference_codes;
    size_t reference_code_length;

    uint32_t max_new_tokens;
    int prefer_metal;
} audio8_synthesis_request;

typedef struct audio8_audio_buffer {
    float * samples;
    size_t sample_count;
    uint32_t sample_rate;
    uint32_t channels;
} audio8_audio_buffer;

typedef struct audio8_runtime_diagnostics {
    const char * backend;
    const char * fallback_reason;
    uint64_t synthesis_count;
    double last_synthesis_ms;
} audio8_runtime_diagnostics;

// Additive performance measurements for the most recent generator/codec
// graph executions. The original diagnostics layout remains unchanged.
typedef struct audio8_runtime_metrics {
    double last_graph_build_ms;
    double last_backend_setup_ms;
    double last_graph_compute_ms;
    double last_graph_transfer_ms;
    // GGML graph-context footprint, not the complete Metal device heap.
    uint64_t last_graph_memory_bytes;
    uint64_t last_graph_transfer_bytes;
} audio8_runtime_metrics;

audio8_runtime * audio8_runtime_create(const char * generator_gguf,
                                        const char * codec_gguf,
                                        const char * tokenizer_json,
                                        audio8_error * error);

// Create a runtime only when the Generator GGUF declares the requested
// export dtype (for example, "F32" or "Q8_0"). This keeps a caller's
// selected model variant authoritative even when user-provided filenames are
// versioned or otherwise ambiguous. Pass NULL to preserve create() behavior.
audio8_runtime * audio8_runtime_create_for_export_dtype(
    const char * generator_gguf,
    const char * codec_gguf,
    const char * tokenizer_json,
    const char * expected_export_dtype,
    audio8_error * error);

void audio8_runtime_destroy(audio8_runtime * runtime);

// A runtime owns mutable execution state and telemetry. Serialize synthesis
// and diagnostics/metrics access for each runtime instance.
// Returns the current execution policy, e.g. "cpu" or
// "metal+cpu-fallback". The pointer remains valid until runtime destruction.
const char * audio8_runtime_backend_name(const audio8_runtime * runtime);
void audio8_runtime_get_diagnostics(const audio8_runtime * runtime,
                                    audio8_runtime_diagnostics * diagnostics);
void audio8_runtime_get_metrics(const audio8_runtime * runtime,
                                audio8_runtime_metrics * metrics);

int audio8_runtime_synthesize(audio8_runtime * runtime,
                              const audio8_synthesis_request * request,
                              audio8_audio_buffer * output,
                              audio8_error * error);

void audio8_audio_buffer_free(audio8_audio_buffer * buffer);
void audio8_error_free(audio8_error * error);

// Write the returned float PCM as a conventional little-endian PCM16 WAV.
int audio8_audio_buffer_write_wav(const audio8_audio_buffer * buffer,
                                  const char * path,
                                  audio8_error * error);

#ifdef __cplusplus
} // extern "C"
#endif
