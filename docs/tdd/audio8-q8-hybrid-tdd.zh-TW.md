# Audio8 Q8_0 Hybrid TDD

Status: slices 1–3 green at contract boundaries; runtime quality gate pending a real checkpoint

本文件是 Audio8 TTS 量化實作的 red → green 記錄。測試只觀察已同意的邊界：native Generator 的 GGUF model contract、離線 quantized artifact contract，以及 App 可載入的完整 TTS model bundle。

## Acceptance seams

1. `GeneratorModel`：F32 與 Q8_0 artifact 的 metadata、tensor names、shape、type 必須被嚴格驗證。
2. Offline artifact：F32 reference 產生的 Q8_0 hybrid GGUF 必須保留 manifest，且只有 Generator attention/FFN matrix weights 使用 Q8_0。
3. TTS model bundle：Generator、Codec、tokenizer 必須以同一 variant、版本與 SHA-256 完整驗證後才可交給 `loadModels()`。

## Red → green slices

### Slice 1 — Generator tensor policy

- Red: `audio8-quant-policy-smoke` 先以新 API 呼叫 policy，native header 尚未提供 name-aware overload，因此編譯失敗。
- Green: 將 per-tensor policy 放入 native loader contract，並讓 F32/Q8_0 validator 只接受符合 policy 的 GGUF；CPU 與 Metal build/CTest 均通過。

### Slice 2 — Offline Q8_0 artifact

- Red: Python exporter tests 先 import 尚未存在的 `is_quantizable_model_tensor`，因此失敗。
- Green: exporter contract 會宣告 `audio8.export_dtype`／policy；`audio8-quantize` 從已驗證的 F32 reference 產生 Q8_0 Generator + F32 sensitive tensors，且 App 不在啟動時量化。

### Slice 3 — Downloaded TTS bundle

- Red: `ModelBundle` package initially lacked verifier symbols, so size/hash/activation tests failed to compile.
- Green: bundle verifier now checks file existence, regular-file type, size, SHA-256, explicit version, and staged activation marker; the download manager verifies before activation and `loadModels()` re-verifies the active App-managed bundle before selecting the chosen F32/Q8_0 resource set. The native C ABI also checks the selected export dtype against GGUF metadata, covering user-provided version-suffixed filenames.

### Slice 4 — Runtime regression

- Red: F32 reference、Q8_0 Generator + F32 Codec 通過 fixed corpus 的 load/audio contract。
- Green: CPU/Metal runtime smoke、peak memory 與 Metal p95 RTF gate 產生可重現報告。

## Evidence

- `audio8-quant-policy-smoke`: native policy boundary, CPU and Metal green.
- `tests/test_audio8_export.py`: 14 tests green (one optional numeric test skipped).
- `Packages/ModelBundle`: 5 XCTest cases green, including versioned activation-marker ordering and post-activation tamper rejection.
- CPU CTest: 5/5 green; Metal CTest: 6/6 green; macOS vendor ctest: 6/6
  green; App macOS, iOS device, and iOS Simulator arm64 builds green.
- App rejects Audio8 loading below the accepted 8 GiB physical-memory floor with an explicit error; it does not auto-switch variants.
- `audio8_runtime_create_for_export_dtype()` is wired through the C consumer target and App wrapper; versioned Q8_0 user filenames are discoverable, and real F32/Q8_0 mismatch behavior remains a model-backed gate because no real checkpoint is present locally.

## Remaining red / release gate

No real Audio8 checkpoint or published, versioned release manifest is present in the current environment. Therefore the following remain intentionally unclaimed: end-to-end `GeneratorModel` validation of a converted Q8_0 GGUF, F32-vs-Q8_0 golden audio parity, peak memory, and Metal p95 RTF. The App keeps Audio8 download URLs and SHA-256 values unset rather than inventing release assets; a user-provided local model directory can still be selected and loaded through the existing `loadModels()` path.
