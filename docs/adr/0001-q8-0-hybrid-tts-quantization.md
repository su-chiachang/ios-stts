# Q8_0 hybrid quantization for Audio8 TTS

Status: accepted

Audio8 TTS will keep its public C ABI and Swift loading interface unchanged while adding a Q8_0 hybrid model variant. The first end-to-end milestone quantizes the Generator while keeping the Codec F32; within the Generator, matrix-heavy, quantization-compatible weights may use Q8_0, while sensitive weights remain at higher precision until parity and audio quality are verified. The F32 model remains the reference. Q4_K_M and Codec quantization are deferred until the Q8_0 Generator path passes the same correctness, quality, and memory gates. This limits the first implementation to a safe deployment boundary without forcing every custom codec operation to accept quantized tensors at once.

The initial Generator tensor policy is Q8_0 for the attention `wqkv` and `wo` matrices and feed-forward `w1`, `w2`, and `w3` matrices in both slow and fast layers. Embeddings, codebooks, norms, biases, and `fast_output` remain F32 for the first quality gate.

## Consequences

- Quantization policy belongs inside the native runtime, not in `loadModels()`.
- The Q8_0 Generator artifact is produced offline from the F32 reference; the App downloads and loads it but does not quantize model weights on-device.
- Model artifacts must declare their quantization policy and remain distinguishable from the F32 reference artifact.
- The App exposes the Q8_0 Generator plus F32 Codec and tokenizer as one manifest-backed TTS model bundle; users do not select those assets independently.
- A bundle is staged while downloading and becomes active only after every asset passes size, SHA-256, manifest, and version checks; incomplete or corrupt bundles are never passed to `loadModels()`, while resumable temporary data may be retained.
- The first downloadable artifacts are versioned Release assets from the Audio8 source project, with exact URLs, sizes, and SHA-256 values pinned by the App's model catalog; unversioned branch or raw-file URLs are not accepted.
- The runtime strictly validates the declared policy and tensor manifest; unsupported or mismatched artifacts fail with an actionable error instead of silently dequantizing or falling back to another model.
- F32 remains the default until the Q8_0 Generator passes its golden and quality gates; after acceptance, Q8_0 Hybrid becomes the user-facing default and F32 remains an explicit reference/diagnostic choice, with no automatic fallback.
- The first supported device target is at least 8 GiB of unified memory for the Q8_0 Generator plus F32 Codec bundle; lower-memory devices are not declared supported until measured and report an explicit memory incompatibility instead of switching variants automatically.
- The first quality gate uses a fixed utterance corpus, seed, and generation parameters; it validates artifact loading, compares intermediate Generator values with tolerances, checks the 44.1 kHz finite non-clipping audio contract, and records code-sequence agreement without requiring byte-identical waveforms.
- Release gates hard-fail on load errors, non-finite values, invalid audio format, clipping, or out-of-memory conditions. Numeric quality thresholds are calibrated from the first reproducible F32/Q8_0 benchmark corpus rather than guessed in advance.
- Memory support is judged by peak runtime memory across a fixed synthesis corpus on both CPU and Metal, including resident model weights, graph/workspace allocations, backend staging, and audio buffers; downloaded file size and an isolated graph-context metric are insufficient.
- On supported 8 GiB-or-more devices, warm Metal synthesis targets a real-time factor of at most 1.0 at p95 over the fixed corpus; download and cold model-load latency are measured separately, and CPU is initially a correctness target rather than a real-time promise.
