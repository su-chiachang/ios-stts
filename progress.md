# Progress

Last updated: 2026-08-03

## Completed

- Verified Audio8 native archives and Swift integration for macOS arm64 and iOS arm64.
- Defined Audio8 integration as model download plus `loadModels()`, covering independently selectable Audio8 TTS and ARK-ASR STT.
- Selected the baseline models: Audio8 TTS Preview 0.6B and ARK-ASR 0.6B.
- Recorded the quantization design in [ADR-0001](docs/adr/0001-q8-0-hybrid-tts-quantization.md).

## Accepted quantization direction

- Keep the public C ABI and Swift loading interface unchanged.
- First milestone: Q8_0 Generator with F32 Codec.
- Quantize Generator attention/FFN matrices (`wqkv`, `wo`, `w1`, `w2`, `w3`); keep embeddings, codebooks, norms, biases, and `fast_output` at F32.
- Produce quantized artifacts offline from the F32 reference.
- Download a versioned, manifest-backed TTS bundle with SHA-256 validation and atomic activation.
- Reject incompatible artifacts explicitly; do not silently dequantize or fallback.
- Target devices with at least 8 GiB unified memory.
- Gate release on golden quality, full runtime peak memory, and Metal p95 RTF <= 1.0.

## Pending implementation

- Add native GGUF metadata and tensor-policy validation for the hybrid Generator artifact.
- Add Q8_0 loading and GGML matrix-kernel support in `audio8.cpp`.
- Produce and publish versioned Generator-Q8_0, Codec-F32, and tokenizer assets.
- Implement resumable bundle download, integrity verification, and `loadModels()` wiring.
- Run golden, memory, CPU/Metal, and latency verification before making Q8_0 the default.
