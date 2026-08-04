## Parent

Issue #9 — Remove Audio8 STT (ARK-ASR) from the App layer / 移除 App 層 Audio8 STT (ARK-ASR)

Reverts scope from `docs/specs/audio8-stt-integration-spec.zh-TW-en.md` (Audio8 ARK-ASR STT Integration) — that spec is being retired by this and its sibling tickets. Decision: keep Audio8 for TTS only; drop Audio8/ARK-ASR STT entirely rather than wait on upstream `audio8.cpp` to vendor the ARK-ASR kernel out of CrispASR.

## What to build

### 繁體中文

從 App Swift 層完全移除 Audio8 ARK-ASR STT engine，只保留 Parakeet 作為 STT backend。刪除 `App/STT/Audio8Stt.swift`；從 `SttBackend` 移除 `.audio8` case（連同其 display name）；從 `ConversationEngine` 移除 Audio8 STT 分支（`audio8SttModelURL`／`Audio8Stt(modelURL:)` 呼叫路徑）；從 `AppSettings` 移除 `audio8SttModelURL`、`audio8SttModelReadinessMessage` 及相關 UserDefaults key；從 `ModelCatalog` 移除 `audio8SttAssets`、`audio8SttModelURL`、`audio8SttReadinessMessage`；從 `SettingsView`／`DownloadModelsView` 移除 Audio8 STT 專屬 UI（backend picker 選項、readiness 訊息、下載清單項目）。Audio8 TTS 相關程式碼（`Audio8Tts.swift`、`audio8TtsVariant`、`audio8Assets` 等）保持不動。

### English

Fully remove the Audio8 ARK-ASR STT engine from the Swift app layer, leaving Parakeet as the only STT backend. Delete `App/STT/Audio8Stt.swift`; remove the `.audio8` case (and its display name) from `SttBackend`; remove the Audio8 STT branch from `ConversationEngine` (the `audio8SttModelURL`/`Audio8Stt(modelURL:)` call path); remove `audio8SttModelURL`, `audio8SttModelReadinessMessage`, and their UserDefaults keys from `AppSettings`; remove `audio8SttAssets`, `audio8SttModelURL`, `audio8SttReadinessMessage` from `ModelCatalog`; remove Audio8-STT-specific UI from `SettingsView`/`DownloadModelsView` (backend picker option, readiness text, download list entry). Audio8 TTS code (`Audio8Tts.swift`, `audio8TtsVariant`, `audio8Assets`, etc.) is untouched.

## Acceptance criteria

- [ ] `App/STT/Audio8Stt.swift` deleted; no remaining Swift references to it.
- [ ] `SttBackend` only exposes Parakeet (or whatever backends remain); `.audio8` case removed everywhere it's matched.
- [ ] `ConversationEngine` no longer branches on an Audio8 STT backend.
- [ ] `AppSettings` and `ModelCatalog` have no Audio8-STT-specific members; Audio8 TTS members untouched.
- [ ] `SettingsView` and `DownloadModelsView` no longer show Audio8 ARK-ASR STT controls or download entries.
- [ ] Existing/updated tests (including `AppTests/ModelCatalogTests.swift`) pass with Audio8 STT removed; add/update tests that assert Audio8 STT no longer exists where relevant.
- [ ] App still builds and Audio8 TTS continues to work unchanged (regression check).

## Blocked by

- none
