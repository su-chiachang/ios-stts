#include "audio8_ark_asr_capi.h"

int main(int argc, char ** argv) {
    audio8_ark_asr_options options = {4, 0, 0, 0.0f, 1};
    audio8_error error = {0};

    if (audio8_ark_asr_create("", &options, &error) != 0)
        return 1;
    if (error.message == 0)
        return 2;
    audio8_error_free(&error);

    char * text = (char *)1;
    if (audio8_ark_asr_transcribe_pcm(0, 0, 0, &text, &error) != 0)
        return 3;
    if (text != 0)
        return 4;
    if (error.message == 0)
        return 5;
    audio8_error_free(&error);
    audio8_ark_asr_free_string(0);

    if (argc < 2)
        return 0;

    audio8_ark_asr * model = audio8_ark_asr_create(argv[1], &options, &error);
    if (model == 0) {
        audio8_error_free(&error);
        return 6;
    }

    static float samples[16000] = {0};
    char * transcript = 0;
    if (audio8_ark_asr_transcribe_pcm(model, samples, 16000, &transcript, &error) == 0) {
        audio8_error_free(&error);
        audio8_ark_asr_destroy(model);
        return 7;
    }
    if (transcript == 0) {
        audio8_ark_asr_destroy(model);
        audio8_error_free(&error);
        return 8;
    }
    audio8_ark_asr_free_string(transcript);
    audio8_ark_asr_destroy(model);
    audio8_error_free(&error);
    return 0;
}
