# Audio8 Integration Context

This context defines the language used for Audio8 speech-service integration in the STTS app.

## Runtime Integration

## Speech Backends

**Apple native TTS backend**:
An app-internal text-to-speech backend that uses the operating system's managed speech voices for STTS playback. It is distinct from a custom speech synthesizer provider extension, which registers voices for system-wide use.
_Avoid_: custom speech provider, Audio Unit extension, Apple TTS model

**Speech provider extension**:
A separate system integration that exposes custom voices through Apple's speech synthesis provider Audio Unit APIs. It is outside the app-internal Apple native TTS backend unless explicitly brought into scope.
_Avoid_: native TTS backend, in-app voice

**Language-matched system voice**:
The Apple native TTS voice selected from the text's detected spoken language, with the operating system's default voice as the fallback when no matching voice is available.
_Avoid_: cloned voice, reference voice, provider extension voice

**Custom voice**:
An imported reference recording used only by TTS backends that support voice conditioning; Apple native TTS does not consume it, but switching back to a supporting backend preserves it.
_Avoid_: Apple system voice, provider extension voice

**Audio8 runtime integration**:
The app provides a complete path from downloading the required Audio8 model assets to loading the selected speech service for use. The integration is complete only when asset acquisition and model loading succeed; it does not imply that source code or model assets are bundled in the app.
_Avoid_: build-only integration, manual model setup, Audio8 fully bundled

**Audio8 speech services**:
The integration covers both Audio8 text-to-speech (TTS) and ARK-ASR speech-to-text (STT), with each service selectable independently.
_Avoid_: Audio8 TTS-only, Audio8 STT-only, coupled backend selection

## Model Variants

**F32 reference model**:
The high-precision Audio8 model variant used as the correctness and audio-quality reference for other variants.
_Avoid_: production default, debug-only model

**Quantized model**:
An Audio8 model variant that uses lower-bit weight representations to reduce download and memory costs while retaining acceptable speech quality.
_Avoid_: compressed model, smaller model

**Q8_0 hybrid model**:
The first production quantized variant: eligible weight groups use Q8_0, while sensitive weight groups retain higher precision until their quality is verified.
_Avoid_: all-tensor Q8_0, Q4_K_M default

**Reduced-precision model**:
An Audio8 model variant using BF16 or F16 weights; it is evaluated separately from block-integer quantized variants such as Q8_0 and Q4_K_M.
_Avoid_: BF16 quantized model

**TTS model bundle**:
A complete, version-compatible set of Generator, Codec, and tokenizer assets selected and downloaded as one Audio8 TTS variant.
_Avoid_: independent TTS files, mix-and-match model parts
