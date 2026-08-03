# Progress

Last updated: 2026-08-03

## Completed

- Verified Audio8 native archives and Swift integration for macOS arm64 and iOS arm64.
- Defined Audio8 integration as model download plus `loadModels()`, covering independently selectable Audio8 TTS and ARK-ASR STT.
- Selected the baseline models: Audio8 TTS Preview 0.6B and ARK-ASR 0.6B.
- Recorded the quantization design in [ADR-0001](docs/adr/0001-q8-0-hybrid-tts-quantization.md).

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
- Fixed the macOS Audio8 vendor script to build its registered
  `audio8-quant-policy-smoke` target before running ctest.
- Added `docs/tdd/audio8-q8-hybrid-tdd.zh-TW.md` with red → green seams and current evidence.

## Verification

- Native CPU CTest: 5/5 passed.
- Native Metal CTest: 6/6 passed, including `audio8_metal_smoke`.
- Native C ABI policy-selector smoke compiles through the C consumer target;
  model-backed selector verification remains pending a real checkpoint.
- Audio8 Python tests: 32 passed, 2 optional tests skipped.
- ModelBundle XCTest: 5/5 passed.
- macOS vendor ctest: 6/6 passed; device and simulator archives export the new
  selector symbol.
- STTS macOS arm64, generic iOS arm64, and generic iOS Simulator arm64 Xcode
  builds: passed without code-signing.
- Final rerun after the selector-harness and Q8 discovery fixes: CPU CTest
  5/5, Metal CTest 6/6, Python 32 passed/2 skipped, and all three App
  destinations remained green.

## Remaining release gates

- No real Audio8 checkpoint or published versioned release manifest is available in the current environment, so the App intentionally leaves Audio8 download URLs, byte sizes, and SHA-256 values unset. It will not claim a download is ready until those values are supplied.
- End-to-end Q8_0 GGUF load, F32-vs-Q8_0 golden audio parity, peak memory, and Metal p95 RTF still require the real checkpoint and release artifacts. F32 remains the default; Q8_0 is selectable but not silently substituted.
