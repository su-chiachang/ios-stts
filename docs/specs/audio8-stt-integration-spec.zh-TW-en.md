# Audio8 ARK-ASR STT Integration

> **狀態：已還原／移除（2026-08-05）。** Audio8 ARK-ASR STT 曾依此規格實作，
> 之後從 App 完全移除 —— Audio8 現在只作 TTS；Parakeet 是 App 唯一的 STT
> backend。原因：native ARK-ASR build 永久依賴一個本 repository 不 vendor、
> 不控管的外部 CrispASR source checkout（`third_party/CrispASR`，clone 自
> `github.com/CrispStrobe/CrispASR`）。與其無限期背負這個外部 build-time
> 依賴 —— 或等 upstream `audio8.cpp` 自行 vendor ARK-ASR kernel —— 決定直接
> 移除 Audio8 STT，把依賴範圍收斂到本 repo 能掌控的部分。見 GitHub issue
> #9（App 層移除）、#10（native build 移除）、#11（本文件／repo 清理）。
> 本文件保留作為原始整合的歷史紀錄；請勿依此文件進行新工作。
>
> **Status: reverted / removed (2026-08-05).** Audio8 ARK-ASR STT was
> implemented per this spec, then removed from the App entirely — Audio8 is
> now TTS-only; Parakeet is the app's sole STT backend. Reason: the native
> ARK-ASR build permanently depended on an external CrispASR source checkout
> (`third_party/CrispASR`, cloned from `github.com/CrispStrobe/CrispASR`)
> that this repository does not vendor or control. Rather than carry that
> external build-time dependency indefinitely — or wait on upstream
> `audio8.cpp` to vendor the ARK-ASR kernel itself — the decision was to drop
> Audio8 STT and keep the dependency surface to what this repo owns. See
> GitHub issues #9 (App layer removal), #10 (native build removal), and #11
> (this doc/repo cleanup). This document is kept as historical record of the
> original integration; do not use it to guide new work.

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
