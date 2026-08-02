## Parent

Issue #3 — Add Audio8 while retaining Qwen / 保留 Qwen 並加入 Audio8

## What to build

### 繁體中文

保留現有 Qwen native TTS，同時把 Audio8 native runtime 加入 App 的 NativeShims 與平台建置流程。完成後，兩套 C ABI 都能獨立建置、連結與 smoke test，並可共存而不發生 symbol 或 backend 衝突。

### English

Keep the existing Qwen native TTS while adding the Audio8 native runtime to NativeShims and the platform build flow. When complete, both C ABIs can build, link, and pass smoke tests independently and can coexist without symbol or backend conflicts.

## Acceptance criteria

- [ ] Qwen native TTS build and existing C ABI smoke coverage remain green.
- [ ] Audio8 is exposed through a dedicated NativeShims module using its public C ABI.
- [ ] macOS and iOS arm64 Audio8 static-library builds succeed with Metal preference and CPU fallback support.
- [ ] Audio8 smoke coverage verifies runtime creation, synthesis, output cleanup, error cleanup, and fallback diagnostics.
- [ ] Qwen and Audio8 native libraries can be linked into the app build without duplicate or cross-runtime symbol conflicts.
- [ ] The Audio8 reference repository and its source files are not modified by this ticket.

## Blocked by

- None — can start immediately.
