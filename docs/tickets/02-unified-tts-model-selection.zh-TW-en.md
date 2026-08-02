## Parent

Issue #3 — Add Audio8 while retaining Qwen / 保留 Qwen 並加入 Audio8

## What to build

### 繁體中文

建立統一的 TTS backend/model selection，讓使用者透過明確設定選擇 `qwen` 或 `audio8`，再由 `loadModels()` 載入對應的 runtime。重新載入時必須先停止目前工作、釋放舊 TTS instance，再建立新 backend；兩套模型資源各自維持清楚的 readiness、下載與錯誤狀態。

### English

Create a unified TTS backend/model selection so the user explicitly chooses `qwen` or `audio8`, and `loadModels()` loads the corresponding runtime. Reloading must stop current work, release the old TTS instance, and then create the selected backend; each model's resources must retain clear readiness, download, and error states.

## Acceptance criteria

- [ ] The persisted TTS selection has exactly the supported backend choices: Qwen and Audio8.
- [ ] `loadModels()` selects the backend from that explicit setting rather than auto-detecting a directory.
- [ ] Qwen selection loads the existing Qwen model contract without changing its supported behavior.
- [ ] Audio8 selection requires the generator GGUF, codec GGUF, and `tokenizer.json` as one atomic resource group.
- [ ] Switching the selection stops active work, releases the previous TTS instance, and loads only the newly selected backend.
- [ ] Missing or invalid resources produce backend-specific, user-readable errors.
- [ ] Settings and model-download state clearly identify whether a resource belongs to Qwen or Audio8.

## Blocked by

- Issue #4 — Dual TTS Native Foundation / 雙 TTS Native Foundation
