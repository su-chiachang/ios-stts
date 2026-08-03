# Audio8 Q8_0 Hybrid TDD

Status: slices 1–6 green on the pinned checkpoint; release-quality corpus and
Metal-device gates remain pending

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

### Slice 4 — Real checkpoint load and dtype selection

- Red: the earlier selector harness could only compile against the additive C
  ABI; no real F32/Q8_0 checkpoint pair existed, so model-backed acceptance and
  mismatch rejection were unproven.
- Green: the pinned Audio8 checkpoint was exported to F32 Generator, Q8_0
  hybrid Generator, F32 Codec, and tokenizer artifacts. Both native Generator
  models load and run; the C ABI accepts F32→F32 and Q8_0→Q8_0, while rejecting
  F32→Q8_0 before inference.

### Slice 5 — F32/Q8_0 quantization parity

- Red: `audio8-quant-parity-smoke` was first added as a deliberate seam stub
  calling the not-yet-existing `QuantizationParityContract`; the native build
  failed with the missing contract symbol.
- Green: the comparator now checks metadata, slow logits/hidden states, fast
  logits across nine codebook stages, one-token semantic/acoustic output, and
  optional Codec waveform drift. The real checkpoint passed the fixed-prompt
  smoke with one acoustic-code mismatch and waveform RMSE `0.0458928`.

### Slice 6 — Versioned release-manifest handoff

- Red: the manifest test initially imported the not-yet-existing
  `audio8_release_manifest` module and failed before any artifact could be
  treated as downloadable.
- Green: the native tool now hashes the local F32/Q8_0 Generator, shared F32
  Codec, and tokenizer, records canonical App filenames and pinned source
  revision, validates both bundle variants, and only marks a manifest
  publishable when every file has an HTTPS release URL.

## Evidence

- `audio8-quant-policy-smoke`: native policy boundary, CPU and Metal green.
- Native Python suite: 43/43 tests green with no skips, including exporter and
  release-manifest contracts.
- `Packages/ModelBundle`: 5 XCTest cases green, including versioned activation-marker ordering and post-activation tamper rejection.
- Real-checkpoint CPU CTest: 14/14 green, including Generator/Codec/pipeline
  parity, runtime smoke, quantization parity, and model-backed C ABI dtype
  selector/mismatch cases.
- Real-checkpoint Metal CTest: 15 passed and 1 skipped; the skip is the
  device-dependent `audio8_metal_parity` test because this host has no Metal
  command queue. `audio8_metal_smoke` and all CPU-fallback tests passed.
- macOS vendor ctest: 6/6 green; App macOS, iOS device, and iOS Simulator
  arm64 builds green.
- App rejects Audio8 loading below the accepted 8 GiB physical-memory floor with an explicit error; it does not auto-switch variants.
- `audio8_runtime_create_for_export_dtype()` is wired through the C consumer
  target and App wrapper; versioned Q8_0 user filenames are discoverable, and
  real F32/Q8_0 mismatch behavior is now model-backed.
- Local artifact evidence: F32 Generator 2,404,653,632 bytes; Q8_0 Generator
  1,178,352,288 bytes; F32 Codec 1,349,626,432 bytes. Runtime-smoke maximum
  RSS was ~3.72 GiB for F32 and ~2.55 GiB for Q8_0.
- Release-manifest tests: 11 focused tests green; full native Python suite:
  43/43 green. The builder reads the actual Generator/Codec GGUF metadata and
  rejects a non-pinned source revision. The real local audit manifest is valid
  and explicitly `publishable=false` until hosting is supplied.

## Remaining red / release gate

The generated GGUF artifacts are local only; no trusted public GGUF host or
release manifest is available, so the App keeps download URLs and SHA-256
values unset rather than inventing release assets. A user-provided local model
directory can still be selected and loaded through `loadModels()`.

The fixed-prompt parity smoke is only a finite/shape/semantic sanity check;
drift values and code mismatches are diagnostics, not calibrated release
thresholds. Longer-corpus audio quality, sustained peak memory, and Metal p95
RTF on a real Apple GPU remain release gates. BF16 source input and Q4_K_M
remain outside the native Audio8 deployment contract; the accepted deployment
pair is F32 reference or Q8_0-hybrid Generator plus F32 Codec.
