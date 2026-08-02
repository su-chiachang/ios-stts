#include "audio8_ark_asr_capi.h"

#include "audio8_runtime.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <new>
#include <string>
#include <vector>

#include "audio8_ark_asr.h"

struct audio8_ark_asr {
    audio8::ArkAsrModel model;
};

namespace {

void clear_error(audio8_error * error) {
    if (error != nullptr) {
        audio8_error_free(error);
        error->message = nullptr;
    }
}

void set_error(audio8_error * error, const char * message) {
    if (error == nullptr)
        return;
    clear_error(error);
    const char * safe_message = message == nullptr ? "unknown Audio8 ARK-ASR error" : message;
    const size_t size = std::strlen(safe_message) + 1;
    error->message = static_cast<char *>(std::malloc(size));
    if (error->message != nullptr)
        std::memcpy(error->message, safe_message, size);
}

void set_error(audio8_error * error, const std::string & message) {
    set_error(error, message.c_str());
}

audio8::ArkAsrOptions options_or_default(const audio8_ark_asr_options * options) {
    audio8::ArkAsrOptions result;
    if (options == nullptr)
        return result;
    result.n_threads = options->n_threads;
    result.verbosity = options->verbosity;
    result.use_gpu = options->use_gpu != 0;
    result.temperature = options->temperature;
    result.beam_size = options->beam_size;
    return result;
}

} // namespace

extern "C" audio8_ark_asr * audio8_ark_asr_create(
    const char * model_path,
    const audio8_ark_asr_options * options,
    audio8_error * error) {
    clear_error(error);
    audio8_ark_asr * model = nullptr;
    try {
        if (model_path == nullptr || model_path[0] == '\0') {
            set_error(error, "Audio8 ARK-ASR model path is empty");
            return nullptr;
        }

        model = new (std::nothrow) audio8_ark_asr;
        if (model == nullptr) {
            set_error(error, "could not allocate Audio8 ARK-ASR model");
            return nullptr;
        }

        std::string load_error;
        if (!model->model.load(model_path, options_or_default(options), &load_error)) {
            delete model;
            set_error(error, load_error.empty() ? "Audio8 ARK-ASR model load failed" : load_error);
            return nullptr;
        }
        return model;
    } catch (const std::exception &) {
        delete model;
        set_error(error, "Audio8 ARK-ASR model load threw a C++ exception");
        return nullptr;
    } catch (...) {
        delete model;
        set_error(error, "Audio8 ARK-ASR model load threw an unknown exception");
        return nullptr;
    }
}

extern "C" void audio8_ark_asr_destroy(audio8_ark_asr * model) {
    delete model;
}

extern "C" int audio8_ark_asr_transcribe_pcm(
    audio8_ark_asr * model,
    const float * samples,
    size_t sample_count,
    char ** text,
    audio8_error * error) {
    clear_error(error);
    if (text != nullptr)
        *text = nullptr;
    try {
        if (model == nullptr) {
            set_error(error, "Audio8 ARK-ASR model is not loaded");
            return 0;
        }
        if (samples == nullptr || sample_count == 0) {
            set_error(error, "Audio8 ARK-ASR PCM input is empty");
            return 0;
        }
        if (text == nullptr) {
            set_error(error, "Audio8 ARK-ASR output pointer is null");
            return 0;
        }

        std::vector<float> pcm(samples, samples + sample_count);
        std::string transcript;
        std::string transcription_error;
        if (!model->model.transcribe_pcm(pcm, transcript, &transcription_error)) {
            set_error(error, transcription_error.empty()
                               ? "Audio8 ARK-ASR transcription failed"
                               : transcription_error);
            return 0;
        }

        const size_t size = transcript.size() + 1;
        auto * result = static_cast<char *>(std::malloc(size));
        if (result == nullptr) {
            set_error(error, "could not allocate Audio8 ARK-ASR transcript");
            return 0;
        }
        std::memcpy(result, transcript.c_str(), size);
        *text = result;
        return 1;
    } catch (const std::exception &) {
        set_error(error, "Audio8 ARK-ASR transcription threw a C++ exception");
        return 0;
    } catch (...) {
        set_error(error, "Audio8 ARK-ASR transcription threw an unknown exception");
        return 0;
    }
}

extern "C" void audio8_ark_asr_free_string(char * text) {
    std::free(text);
}
