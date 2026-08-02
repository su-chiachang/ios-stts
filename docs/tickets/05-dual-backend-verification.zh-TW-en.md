## Parent

Issue #3 — Add Audio8 while retaining Qwen / 保留 Qwen 並加入 Audio8

## What to build

### 繁體中文

完成雙 backend TTS 的整合驗收。使用者可以透過明確設定在 Qwen 與 Audio8 間切換，反覆 reload model 後仍能正常合成、播放、取消與重新載入；兩套模型下載/readiness、設定 UI、錯誤處理與 macOS/iOS build 都符合各自的 backend contract。Qwen 保留為正式支援 backend，不以移除 Qwen references 作為完成條件。

### English

Complete integration verification for the dual-backend TTS system. Users can explicitly switch between Qwen and Audio8, and repeated model reloads continue to synthesize, play, cancel, and reload correctly. Both model download/readiness flows, settings UI, error handling, and macOS/iOS builds satisfy their backend contracts. Qwen remains a supported production backend; removing Qwen references is not an acceptance condition.

## Acceptance criteria

- [ ] Selecting Qwen, loading models, synthesizing without reference audio, and synthesizing with reference audio all pass regression checks.
- [ ] Selecting Audio8, loading all three resources, synthesizing without reference audio, and synthesizing with reference audio all pass integration checks.
- [ ] Switching Qwen → Audio8 → Qwen through `loadModels()` leaves no stale runtime, audio queue, voice cache, or native buffer state.
- [ ] Reload and cancellation stop the active backend before a new backend is created.
- [ ] Model download and readiness UI distinguishes Qwen's resources from Audio8's three-resource group.
- [ ] Backend-specific errors remain readable and do not incorrectly identify the other backend.
- [ ] macOS and iOS arm64 application builds pass with both native libraries present.
- [ ] CPU fallback is verified for Audio8 when Metal is unavailable.
- [ ] Existing Qwen linker/build/vendor integration remains intentional and documented; Audio8 integration does not regress it.
- [ ] The final regression check confirms both backend names and contracts are represented, rather than requiring all Qwen references to disappear.

## Blocked by

- Issue #5 — Unified TTS Model Selection in loadModels / loadModels 統一 TTS 模型選擇
- Issue #6 — Audio8 No-Reference Synthesis / Audio8 無參考音訊合成
- Issue #7 — Audio8 Reference Conditioning / Audio8 參考音訊條件化
