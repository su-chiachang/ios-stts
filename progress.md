# Progress

Last updated: 2026-08-05

## 2026-08-05 — Audio8 STT (ARK-ASR) reverted; Audio8 is TTS-only

- Removed Audio8 ARK-ASR STT from the app entirely (issues #9, #10, #11).
  Parakeet is now the app's only STT backend; Audio8 remains TTS-only,
  unchanged. `docs/specs/audio8-stt-integration-spec.zh-TW-en.md` is marked
  reverted/removed at the top and kept as historical record.
- Reason: the native ARK-ASR build permanently required an external
  CrispASR source checkout (`third_party/CrispASR`) that this repo doesn't
  vendor or control. Rather than carry that external dependency indefinitely
  — or wait on upstream `audio8.cpp` to vendor the ARK-ASR kernel itself —
  the STT feature was dropped instead.
- App layer: deleted `App/STT/Audio8Stt.swift`; `SttBackend` now only has
  `.parakeet`; removed the Audio8-STT-specific members from `AppSettings`
  and `ModelCatalog`; removed the corresponding Settings/Download Models UI,
  including the now-single-option STT backend picker.
- Native build: `scripts/build-audio8-macos.sh` and
  `scripts/build-audio8-ios.sh` no longer clone CrispASR or build the
  `audio8-ark-asr` target; deleted `audio8_ark_asr_shim.cpp`,
  `audio8_ark_asr_c_smoke.c`, and `audio8_ark_asr_capi.h`. Rebuilt native
  archives verified via `nm` to contain only the Audio8 TTS C ABI
  (`_audio8_runtime_*`, `_audio8_audio_buffer_*`, `_audio8_error_free`) —
  no `_audio8_ark_asr_*` symbols remain. macOS arm64 and iOS Simulator
  arm64 app builds pass against the rebuilt archives.
- Removed the local `third_party/CrispASR` checkout; it was already
  gitignored and unreferenced by any script.

## 2026-08-04 — App model-loading TDD red phase

- Added `AppTests/ConversationEngineModelLoadingTests.swift` for the next
  integration seam: persisted Qwen/Audio8 selection must drive `loadModels()`;
  reloading must release the previous TTS runtime; and a TTS load failure must
  not publish a partially loaded STT/TTS pair.
- Generated the Xcode project from `project.yml` and ran the new App XCTest
  target. The test suite is intentionally red at the seam because
  `ConversationEngine` does not yet expose injectable STT/TTS loaders; the
  compiler reports both missing-initializer arguments. This is the recorded
  TDD red phase before implementation.

## 2026-08-04 — App model-loading TDD green phase

- Added injectable `SttModelLoader`/`TtsModelLoader` seams while preserving the
  production Qwen, Audio8, Parakeet, and Audio8 ARK-ASR constructors.
- Changed `loadModels()` to construct the selected STT/TTS pair before
  publishing either engine. A failed TTS load therefore cannot expose a
  partially loaded pair; reload still waits for active cancellation and audio
  flush before the previous actor can be released.
- The focused two-case App XCTest passed (exit 0), and the complete App test
  target completed without failures during the green run. A later repeat after
  only error-type wording cleanup was blocked by the sandbox's package
  manifest/cache permissions and approval quota; `swiftc -parse` passed for
  the edited production file.
- Red-phase commit `7de8a8a` is pushed to `origin/feature/audio8`; the green
  implementation and this progress update are pending the next commit.

## Completed

- Verified Audio8 native archives and Swift integration for macOS arm64 and iOS arm64.
- Defined Audio8 integration as model download plus `loadModels()`, covering independently selectable Audio8 TTS and ARK-ASR STT.
- Selected the baseline models: Audio8 TTS Preview 0.6B and ARK-ASR 0.6B.
- Revalidated the official Audio8 TTS source release and found the pinned
  checkpoint locally: `Audio8/Audio8-TTS-Preview-0.6b`, revision
  `f9612f13a0ab40facf3d050fc908b9e6db05c2be`. The source files are
  `model.safetensors` (1,202,342,528 bytes, BF16), `codec.pth`
  (1,349,857,559 bytes, FP32), and `tokenizer.json` (12,217,872 bytes).
- Recorded the quantization design in [ADR-0001](docs/adr/0001-q8-0-hybrid-tts-quantization.md).
- Recorded the requested F32/BF16/Q8_0/Q4_K_M bundle-size and runtime-memory
  comparison in [Audio8 TTS model sizing](docs/model-sizing/audio8-tts-model-sizing.zh-TW.md).

## Accepted quantization direction

- Keep the existing public C ABI and Swift loading interface compatible; add an
  optional expected-export-dtype gate for variant-aware App loading.
- First milestone: Q8_0 Generator with F32 Codec.
- Quantize Generator attention/FFN matrices (`wqkv`, `wo`, `w1`, `w2`, `w3`); keep embeddings, codebooks, norms, biases, and `fast_output` at F32.
- Produce quantized artifacts offline from the F32 reference.
- Download a versioned, manifest-backed TTS bundle with SHA-256 validation and atomic activation.
- Reject incompatible artifacts explicitly; do not silently dequantize or fallback.
- Target devices with at least 8 GiB unified memory.
- Gate release on golden quality, full runtime peak memory, and Metal p95 RTF <= 1.0.

## Implemented in this pass

- Added the shared native `audio8_quant_policy.h` contract. F32 remains strict F32; Q8_0 is accepted only for the Generator attention/FFN matrices, while embeddings, codebooks, norms, biases, `fast_output`, and all Codec tensors remain F32.
- Added strict Generator metadata/tensor validation and a defense-in-depth loader path for F32/Q8_0 tensors; unsupported policy values (including Q4_K_M) fail explicitly.
- Added the offline `audio8-quantize <f32.gguf> <q8.gguf>` tool. It validates the F32 reference first, streams the GGUF, and never runs on-device.
- Added the App `ModelBundle` package with streaming SHA-256/size/version verification, staging, completion-marker activation, and re-verification of the active App-managed bundle before `loadModels()`. `ModelDownloadManager` verifies before activation and resumes only files that already pass their own integrity check; `ConversationEngine.loadModels()` loads the selected F32 reference or Q8_0 hybrid resource names.
- Added the accepted 8 GiB physical-memory compatibility gate for Audio8 TTS; low-memory devices report an explicit incompatibility instead of silently switching variants.
- Added `audio8_runtime_create_for_export_dtype()` and passed the selected
  F32/Q8_0 export dtype from `loadModels()` so user-provided, version-suffixed
  filenames cannot override the selected variant; native GGUF metadata is the
  authority.
- Extended user-provided Q8_0 discovery to the versioned
  `audio8-generator-Q8_0-hybrid*` / `audio8-codec-F32-Q8_0-hybrid*` pair while
  retaining native metadata enforcement.
- Added the App XCTest target and fixed variant-specific suffix matching so a
  user-provided versioned Q8_0 Generator/Codec pair is discovered atomically
  with `tokenizer.json` before `loadModels()`.
- Tightened Audio8 resource discovery to accept only regular files for exact
  and versioned Generator/Codec/tokenizer bundles, rejecting directories with
  `.gguf`- or `tokenizer.json`-looking names.
- Added the App-side `Audio8ReleaseManifest` parser and bundled local-audit
  manifest. Publishable release JSON now maps into the existing atomic
  `ModelAsset`/`ModelDownloadManager` flow only after pinned schema, bundle
  roles, HTTPS URL, size, and SHA-256 validation; the current no-URL manifest
  remains unavailable by design.
- Added a deterministic `URLSessionConfiguration` seam to
  `ModelDownloadManager` and an App integration test that downloads a
  publishable three-file Audio8 bundle through the delegate path, verifies
  size/SHA-256, and asserts atomic activation only after all files pass.
- Tightened downloaded-state reporting so a completed Audio8 bundle is only
  considered installed while `ModelBundleVerifier.isActivated` still passes;
  tampering now returns the asset to a re-downloadable state.
- Fixed the macOS Audio8 vendor script to build its registered
  `audio8-quant-policy-smoke` target before running ctest.
- Added `docs/tdd/audio8-q8-hybrid-tdd.zh-TW.md` with red → green seams and current evidence.
- Added the native release-manifest handoff: local F32/Q8_0/Codec/tokenizer
  artifacts can now produce deterministic bytes/SHA-256 records, canonical App
  destination filenames, source revision, and optional HTTPS release URLs.
- Added `scripts/audio8_release_package.py` as the App-repository release
  entry point. It requires an explicit HTTPS `--release-base-url`, delegates
  to the native generator with `--require-release-url`, and refuses to run if
  the native release tool is missing; this prevents a local-audit manifest
  from being mistaken for a downloadable App release.
- Added the native opt-in multi-case quantization gate beside the App repo:
  the existing 18-case bilingual corpus is validated by a Python adapter and
  passed as temporary TSV records to `audio8-quant-corpus-smoke`. Each case
  exercises native tokenization, no-reference prompt construction, F32/Q8_0
  generation, finite 44.1 kHz PCM validation, repeated Q8_0 determinism, and
  relative output-length checking. Native commit `4fa6056` is pushed to
  `audio8.cpp` `origin/main`.
- Added an explicit `--max-new-tokens`/CMake override for a bounded structural
  sweep of the entire corpus. Native commit `b0e22f9` is pushed to
  `audio8.cpp` `origin/main`; the release-quality manifest caps remain
  unchanged when the override is omitted.

## Verification

- Real source conversion completed from the pinned checkpoint. Generated local
  artifacts are:
  - F32 Generator: 2,404,653,632 bytes,
    SHA-256 `d435f97a3f755a2b494ecefffda50631173db8275b5723f647d750c049039909`.
  - Q8_0-hybrid Generator: 1,178,352,288 bytes,
    SHA-256 `96fe2ed44114ecb6d8c8a0439a28052f0ec4895c06858dc0bb6b5dd1ca878512`.
  - F32 Codec: 1,349,626,432 bytes,
    SHA-256 `8bc2374d16a66b0d8cde4c8c0085173faeb3f9bca05347b93a601fb4998393d2`.
  - Source tokenizer: 12,217,872 bytes,
    SHA-256 `f24e08099d45a8adf3f52f5f0b03276e433bb9d689bb15fcbcc48ce58744588b`.
- Native real-checkpoint CPU CTest: 14/14 passed, including F32/Q8_0 model
  inspection, Generator/Codec/pipeline parity, runtime smoke, quantization
  parity, and matching/mismatched C ABI dtype-selector cases.
- Native real-checkpoint Metal CTest: 15 passed and 1 skipped. The only skip is
  `audio8_metal_parity`, return code 77, because this host has no Metal device or
  command queue; the CPU fallback and `audio8_metal_smoke` passed.
- Quantization parity sanity smoke passed with
  `slow_logits_max_abs=0.152815`, `slow_hidden_rmse=0.032499`,
  `fast_logits_max_abs=0.619019`, one acoustic-code mismatch, and
  `waveform_rmse=0.0458928`; drift and code mismatch remain diagnostic until
  the fixed corpus calibrates release thresholds.
- Real model-backed C ABI selector checks passed for F32→F32 and Q8_0→Q8_0;
  F32→Q8_0 was rejected with the expected incompatible-dtype error.
- Peak resident memory from the runtime smoke was 3,992,305,664 bytes
  (~3.72 GiB) for F32 and 2,737,537,024 bytes (~2.55 GiB) for Q8_0. The App's
  accepted 8 GiB physical-memory gate remains conservative pending longer
  corpus measurements.
- Native Python suite: 46/46 passed with no skips; ModelBundle XCTest remains
  5/5; macOS vendor ctest remains 6/6; STTS macOS,
  generic iOS device, and generic iOS Simulator arm64 builds remain green.
- App `STTSTests` XCTest: 13/13 passed on arm64 macOS, covering versioned F32 and
  Q8_0 discovery, missing-tokenizer and mismatched-pair rejection, ambiguous
  versioned-pair rejection, and non-regular-file rejection for Generator and
  tokenizer. Its red phases reproduced the pre-fix Q8_0 discovery failure,
  arbitrary version choice, and directory acceptance. Release-manifest tests
  cover publishable mapping, non-publishable safety, dtype drift,
  release-base containment, and the bundled unavailable fallback.
- The dedicated `STTSTests` scheme remains green at 13/13 on arm64 macOS, and
  the generic iOS `STTS` target builds successfully with signing disabled.
- The App download integration test passes with an injected URLSession
  transport: the Audio8 three-file bundle reaches `completed` only after
  ModelBundle verification and activation-marker publication.
- Release-manifest TDD is green: 11 focused tests and the full native Python
  suite are 46/46 passed. The builder also verifies the actual Generator/Codec
  GGUF metadata and pinned source revision. The real local audit manifest
  reproduces all four artifact hashes and is marked `publishable=false` because
  no hosting URL was supplied.
- Release-package wrapper TDD is green: 4/4 tests cover the forced native
  publishability flag, required release URL, HTTPS validation, and delegation
  command. No model bytes are copied into the App repository.
- Native corpus adapter TDD is green: 3/3 tests cover stable manifest-to-TSV
  rendering, native command wiring, and tab/newline rejection. The configured
  real CTest tracer bullet passed 1/1, and the capped full-corpus adapter run
  passed 18/18 across English/Chinese short/medium/long cases. Every capped
  case produced deterministic Q8_0 output with zero decoded-length delta; the
  largest observed capped waveform RMSE was `0.0279019`.
- 2026-08-04: Native benchmark convergence progressed from a timing-only JSONL
  seam to an auditable contract: F32/Q8_0 trial identity and output counts,
  load/e2e/synthesis timing, graph/process RSS, failed-case diagnostics,
  deterministic p50/p95/RTF summaries, and Markdown output. An isolated native
  cold-load child now measures F32 `1021.575 ms` / `3,815,145,472` bytes and
  Q8_0 `690.430 ms` / `2,660,696,064` bytes; real CTest remained `1/1`.
  The native qwentts adapter also parses F32/BF16/Q8_0/Q4_K_M logs, but keeps
  the existing no-timestamp limitation visible instead of claiming warm p50/p95.

## Remaining release gates

- The release-manifest schema/generator is ready, but the generated GGUF
  artifacts are currently local only. No trusted public GGUF host/release
  upload credential is available, so the bundled App manifest intentionally
  has no download URLs and the App remains unavailable for in-app Audio8
  downloads. The official source checkpoint is not itself a GGUF runtime
  bundle; replace this manifest at release packaging time with the native
  tool's publishable JSON once hosting is authorized.
- The Q8_0 path now has both the fixed-prompt diagnostic and an opt-in
  multi-case structural/determinism gate; its fast cap=1 sweep is green for
  18/18 cases. The uncapped manifest run (`32`, `64`, and `128` tokens) and
  calibrated waveform RMSE thresholds are still pending. Sustained peak memory
  and Metal p95 RTF on a real Apple GPU are also required before publishing.
- F32 remains the reference/default; Q8_0 hybrid is loadable and selectable;
  BF16 and Q4_K_M are not claimed as native Audio8 deployment artifacts.
