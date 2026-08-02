## Parent

Issue #3 — Add Audio8 while retaining Qwen / 保留 Qwen 並加入 Audio8

## What to build

### 繁體中文

把 Audio8 參考音訊與參考轉錄納入雙 backend TTS flow。選擇 Audio8 時，App 將參考音訊轉為 mono float PCM，傳遞來源取樣率與可選 transcript，由 Audio8 完成必要的 resampling 與 reference conditioning；選擇 Qwen 時，既有 reference synthesis 與 custom voice 流程維持不變。

### English

Add Audio8 reference audio and reference transcript to the dual-backend TTS flow. When Audio8 is selected, the app converts reference audio to mono float PCM, passes the source sample rate and optional transcript, and lets Audio8 perform required resampling and reference conditioning; when Qwen is selected, the existing reference synthesis and custom-voice flow remains unchanged.

## Acceptance criteria

- [ ] Audio8 accepts reference audio with a non-native sample rate and forwards the source rate correctly.
- [ ] Optional reference transcript is forwarded only when supplied and produces a clear error when the selected backend requires missing conditioning data.
- [ ] Audio8 reference synthesis returns playable mono 44.1 kHz output.
- [ ] Qwen reference synthesis and custom-voice import remain functional when Qwen is selected.
- [ ] Reloading or switching backends does not reuse stale voice-reference cache, native buffers, or model state from the other backend.
- [ ] Reference-audio conversion and native buffer ownership are released on both success and failure.
- [ ] UI controls clearly reflect which reference-audio capabilities are available for the selected backend.

## Blocked by

- Issue #6 — Audio8 No-Reference Synthesis / Audio8 無參考音訊合成
