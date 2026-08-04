# Audio8 Q8_0 Hybrid TDD

Status: slices 1–15 green on the pinned checkpoint; release-quality corpus and
Metal-device gates remain pending

本文件是 Audio8 TTS 量化實作的 red → green 記錄。測試只觀察已同意的邊界：native Generator 的 GGUF model contract、離線 quantized artifact contract，以及 App 可載入的完整 TTS model bundle。

## Acceptance seams

1. `GeneratorModel`：F32 與 Q8_0 artifact 的 metadata、tensor names、shape、type 必須被嚴格驗證。
2. Offline artifact：F32 reference 產生的 Q8_0 hybrid GGUF 必須保留 manifest，且只有 Generator attention/FFN matrix weights 使用 Q8_0。
3. TTS model bundle：Generator、Codec、tokenizer 必須以同一 variant、版本與 SHA-256 完整驗證後才可交給 `loadModels()`。
4. `ModelCatalog.audio8Resources`：使用者提供的 versioned F32/Q8_0 Generator/Codec 檔名必須被配成同一 variant，並保留 tokenizer。

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

### Slice 7 — Versioned user-provided Q8_0 resource discovery

- Red: the new macOS App XCTest created versioned filename fixtures for the
  Q8_0 pair
  `audio8-generator-Q8_0-hybrid-f9612f13.gguf` and
  `audio8-codec-F32-Q8_0-hybrid-f9612f13.gguf`; `audio8Resources(for: .q8_0Hybrid,
  in:)` returned `nil` for all three resources because the two variant prefixes
  were stripped with the generic prefixes.
- Red: a second fixture with two valid Q8_0 version suffixes showed that the
  previous implementation silently selected the lexicographically first pair
  instead of rejecting an ambiguous manual-import directory.
- Red: a directory named like the canonical Q8_0 Generator `.gguf` file was
  accepted because the exact-name path only checked `fileExists`.
- Red: a versioned Generator/Codec pair with a `tokenizer.json` directory was
  accepted because the fallback tokenizer path only checked `fileExists`.
- Green: `ModelCatalog.audio8ResourcePair` now strips the selected variant's
  Generator and Codec prefixes before comparing the source suffix, and returns
  no pair unless exactly one versioned pair matches. F32 and Q8_0 discovery,
  tokenizer retention, mismatched-pair rejection, and ambiguous-pair rejection
  pass `STTSTests` 7/7; exact and discovered paths now require regular files
  for Generator, Codec, and tokenizer.

### Slice 8 — App release-manifest download configuration

- Red: App tests referenced the native release-manifest handoff before the App
  had a parser or a safe mapping into `ModelAsset`, so the new manifest tests
  could not compile.
- Red: a fixture pointed one Q8_0 file outside `release_base_url`; the first
  parser accepted it instead of preserving the native release-manifest trust
  boundary.
- Green: `Audio8ReleaseManifest` now validates the pinned schema, model ID,
  source revision, exact F32/Q8_0 bundle/file roles, HTTPS URLs, byte sizes,
  release-base containment, and SHA-256 values, then maps both atomic
  three-file bundles into the existing `ModelDownloadManager` contract. A
  bundled local-audit manifest remains unavailable until every file has a
  publishable URL; no unverified download is enabled.

### Slice 9 — Atomic App download execution

- Red: the new App integration test required a `ModelDownloadManager` session
  seam, but the manager constructed its URLSession internally and could not be
  driven by a deterministic transport in XCTest.
- Green: `ModelDownloadManager` now accepts an optional
  `URLSessionConfiguration`; the test injects a URLProtocol transport and
  verifies that all three files download, pass the ModelBundle size/SHA checks,
  and become visible only after the activation marker is written. Production
  keeps the default URLSession configuration.

### Slice 10 — Integrity-aware completed state

- Red: after a completed bundle was tampered with, the download manager only
  checked the completion marker and continued to report the asset as downloaded.
- Green: completed-state lookup now calls `ModelBundleVerifier.isActivated`,
  which rechecks every file's size and SHA-256; a tampered bundle is exposed as
  `notStarted` and can be downloaded again instead of being passed to
  `loadModels()`.

### Slice 11 — Publishable release packaging entry point

- Red: the App repository had a native manifest generator and a safe local
  audit manifest, but no release command that made the hosting requirement
  impossible to overlook; a wrapper test first imported the missing command
  module.
- Green: `scripts/audio8_release_package.py` now requires an explicit HTTPS
  `--release-base-url`, checks that the sibling `audio8.cpp` release tool
  exists, and always delegates with `--require-release-url`. The wrapper only
  passes artifact paths and writes the native manifest output; it never copies
  model bytes into the App repository.

### Slice 12 — Multi-case quantized parity corpus

- Red: the existing quantized parity smoke only exercised one hard-coded token
  and had no corpus CTest registration; the new adapter tests first imported
  the missing `tools.audio8_quant_corpus` module.
- Green: the adjacent native repo now validates the pinned 18-case bilingual
  manifest, renders temporary TSV records, and runs
  `audio8-quant-corpus-smoke` over selected cases. The native runner uses the
  real tokenizer and no-reference prompt builder, checks F32/Q8_0 valid finite
  PCM, repeated Q8_0 determinism, and relative decoded length. It reports
  waveform RMSE but leaves the release threshold opt-in until calibration.

### Slice 13 — Full-corpus structural sweep token cap

- Red: the pinned corpus intentionally contains `max_new_tokens` values of
  `32`, `64`, and `128`; running every medium/long case uncapped on the CPU
  makes the fast gate dominated by native graph-build cost. The adapter test
  first rejected the new `--max-new-tokens` option as an unknown argument.
- Green: the Python adapter, native runner, and CMake CTest wiring now accept
  an explicit positive token cap. With `max_new_tokens=1`, all 18 English and
  Chinese short/medium/long cases passed tokenization, no-reference prompt
  construction, F32/Q8_0 generation, finite PCM validation, deterministic Q8_0
  re-run, and length checks. This cap is a structural sweep, not an audio
  quality claim; uncapped manifest values remain the release-quality path.

### Slice 14 — Benchmark JSONL, cold load, and diagnostic records

- Red: the corpus gate emitted human-readable parity lines only; it had no
  stable trial schema for warmups, p50/p95 timing, RTF, graph diagnostics, or
  process RSS. The adapter first rejected `--warmups`, `--trials`, and
  `--report-jsonl` as unknown options.
- Green: the native corpus runner now emits validated JSONL records for F32 and
  Q8_0 measured trials, including runtime/artifact identity, output
  shape/duration/counts, load/e2e/synthesis timings, graph metrics, and
  `load_peak_rss_bytes` versus cumulative `process_peak_rss_bytes`. A separate
  `audio8-quant-load-smoke` child records isolated cold F32/Q8_0 load timing and
  RSS. Failed prompt/generation/decode cases remain as diagnostic records.
  The Python report module validates all three record types, excludes warmups
  from p50/p95/RTF summaries, interpolates p50 and p95 deterministically, and
  renders synthesis plus cold-load Markdown tables.

### Slice 15 — Explicit backend model-loading seam

- Red: `ConversationEngineModelLoadingTests` now asks `ConversationEngine` to
  inject fake STT/TTS loaders. The first run fails at compile time because the
  production engine still constructs native model types directly and has no
  test seam. The cases cover persisted Qwen → Audio8 selection, old-runtime
  release on reload, and atomic failure when TTS loading throws.
- Green: `ConversationEngine` retains the current Qwen/Audio8 constructors
  behind injectable `SttModelLoader`/`TtsModelLoader` closures. `loadModels()`
  now publishes both engines only after both selected loaders succeed, so a
  TTS failure cannot leave a partially ready STT/TTS pair. The focused
  two-case XCTest passed; the full target also completed without failures in
  the green run. A subsequent rerun after error-type-only cleanup was blocked
  by this host's SwiftPM cache permissions/approval quota, so it is not counted
  as new test evidence.

## Evidence

- `audio8-quant-policy-smoke`: native policy boundary, CPU and Metal green.
- Native Python suite: 59/59 tests green with no skips, including exporter and
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
- App macOS XCTest: `STTSTests` 13/13 passed on arm64 macOS, covering versioned
  F32 and Q8_0 Generator/Codec/tokenizer discovery, missing-tokenizer and
  mismatched-pair rejection, ambiguous-pair rejection, and non-regular-file
  rejection for Generator and tokenizer. The red phases reproduced the
  pre-fix `nil` resource pair, arbitrary version selection, and directory
  acceptance. The release-manifest tests also cover publishable mapping,
  non-publishable safety, dtype drift, release-base containment, and the
  bundled unavailable fallback.
- The App download integration test uses an injected URLSession transport to
  exercise the real `ModelDownloadManager` delegate path; it verifies the
  publishable three-file bundle reaches `completed` only after integrity
  verification and atomic activation.
- Local artifact evidence: F32 Generator 2,404,653,632 bytes; Q8_0 Generator
  1,178,352,288 bytes; F32 Codec 1,349,626,432 bytes. Runtime-smoke maximum
  RSS was ~3.72 GiB for F32 and ~2.55 GiB for Q8_0.
- Release-manifest tests: 11 focused tests green; full native Python suite:
  43/43 green. The builder reads the actual Generator/Codec GGUF metadata and
  rejects a non-pinned source revision. The real local audit manifest is valid
  and explicitly `publishable=false` until hosting is supplied.
- Release-package wrapper tests: 4/4 green; they cover required HTTPS hosting,
  forced `--require-release-url`, missing URL rejection, and native command
  delegation.
- Native corpus adapter tests: 3/3 green. The configured real CTest corpus
  tracer bullet passed 1/1, and the capped full-corpus structural sweep passed
  18/18. Every capped case had zero decoded-length delta and deterministic
  Q8_0 output; the largest observed capped waveform RMSE was `0.0279019`.
- Benchmark/report TDD: 8/8 report tests plus 5/5 corpus-adapter tests and
  3/3 qwentts-adapter tests are green. A real one-case CTest report with one
  warmup and two trials per variant produced six validator-clean synthesis
  records plus two isolated cold-load records. Cold load measured F32
  `1021.575 ms` / `3,815,145,472` bytes and Q8_0 `690.430 ms` /
  `2,660,696,064` bytes on the current host.

## Remaining red / release gate

The generated GGUF artifacts are local only; no trusted public GGUF host or
release manifest is available, so the App keeps download URLs and SHA-256
values unset rather than inventing release assets. A user-provided local model
directory can still be selected and loaded through `loadModels()`.

The fixed-prompt parity smoke remains a finite/shape/semantic diagnostic, while
the capped corpus sweep proves structural validity and Q8_0 repeatability only.
The uncapped 18-case run at manifest values `32`, `64`, and `128`, calibrated
waveform thresholds, sustained full-corpus memory, and Metal p95 RTF on a real
Apple GPU remain release gates. The new RSS report seam supplies the required
measurement shape but not yet the complete release dataset. BF16 source input and Q4_K_M remain outside the
native Audio8 deployment contract; the accepted deployment pair is F32
reference or Q8_0-hybrid Generator plus F32 Codec.
