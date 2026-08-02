# Audio8 ARK-ASR STT Integration

## Scope

整合 `audio8.cpp` 的 ARK-ASR native wrapper，讓 App 可以在既有 Parakeet
之外選擇 Audio8 作為 STT；Audio8 TTS 維持既有 `generator + codec +
tokenizer` runtime。STT 與 TTS backend 分開選擇，避免為了使用 Audio8 STT
而被迫更換 TTS。

Integrate `audio8.cpp`'s native ARK-ASR wrapper so the app can select Audio8
for STT in addition to Parakeet, while retaining the existing Audio8
`generator + codec + tokenizer` TTS runtime. STT and TTS backend selection are
independent, so choosing Audio8 STT does not force a TTS change.

## Requirements

- Expose an App-owned C ABI over `audio8::ArkAsrModel`; the Swift layer must
  not depend on C++ types.
- Build the ARK-ASR target from the external CrispASR source dependency and
  merge its symbols with the existing Audio8 TTS archive for macOS and iOS
  arm64, while keeping the public symbols namespaced.
- Audio8 STT accepts mono float32 PCM at 16 kHz. Its buffered native API may
  accumulate microphone chunks and transcribe at turn end; endpoint detection
  must still close a turn after speech followed by silence.
- Keep a shared `SttEngine` seam so `ConversationEngine` remains independent
  of Parakeet and Audio8 implementations. Audio8 must report that its native
  path does not provide per-word timestamps rather than inventing timings.
- Persist an independent STT backend setting, expose Audio8 ARK-ASR model
  readiness in Settings/Download Models, and retain Parakeet as the default.
- Missing ARK-ASR GGUF, malformed native requests, and native errors must be
  reported as readable app errors. Native output/error buffers must be freed.

## Verification

- Native Audio8 macOS and iOS archives contain both TTS and ARK-ASR C symbols.
- The C ABI smoke path covers invalid model/input errors and cleanup.
- When `AUDIO8_TEST_ARK_ASR_GGUF` is supplied, macOS C smoke also loads a
  valid ARK-ASR GGUF, transcribes a 16 kHz PCM buffer, and frees the result.
- Native Audio8 CTest, SwiftPM NativeShims build, macOS arm64 app build, and
  iOS Simulator arm64 app build pass.
