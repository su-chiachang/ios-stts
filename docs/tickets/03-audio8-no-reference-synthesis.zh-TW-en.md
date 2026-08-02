## Parent

Issue #3 — Add Audio8 while retaining Qwen / 保留 Qwen 並加入 Audio8

## What to build

### 繁體中文

完成 Audio8 的無參考音訊 TTS vertical slice：當設定選擇 Audio8 且三項模型資源可用時，`loadModels()` 建立 Audio8 Swift runtime，文字合成結果可交給既有 AudioPlayer 播放；選擇 Qwen 時原有合成流程保持不變。

### English

Complete the Audio8 no-reference TTS vertical slice: when Audio8 is selected and all three model resources are ready, `loadModels()` creates the Audio8 Swift runtime and synthesized text is played by the existing AudioPlayer; when Qwen is selected, the existing synthesis flow remains unchanged.

## Acceptance criteria

- [ ] The Swift TTS abstraction can represent either the Qwen or Audio8 backend without exposing native C++ implementation details to callers.
- [ ] Audio8 runtime lifecycle is owned by one serialized Swift actor or equivalent owner.
- [ ] Text and language are mapped to an Audio8 synthesis request with the configured token limit and backend preference.
- [ ] Native PCM is copied before the Audio8 buffer is freed, and synthesis errors become readable App errors.
- [ ] Audio8 output plays through the existing AudioPlayer as mono 44.1 kHz audio.
- [ ] Qwen text synthesis remains functional when Qwen is selected.
- [ ] Conversation read-aloud and direct TTS use the selected backend after `loadModels()`.

## Blocked by

- Issue #4 — Dual TTS Native Foundation / 雙 TTS Native Foundation
- Issue #5 — Unified TTS Model Selection in loadModels / loadModels 統一 TTS 模型選擇
