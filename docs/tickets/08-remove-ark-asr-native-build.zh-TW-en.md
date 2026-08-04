## Parent

Issue #10 — Remove ARK-ASR/CrispASR from native Audio8 build / 移除 native Audio8 build 中的 ARK-ASR/CrispASR

Same parent as [07 — Remove Audio8 STT (ARK-ASR) from the App layer](07-remove-audio8-stt-app-layer.zh-TW-en.md) — retires `docs/specs/audio8-stt-integration-spec.zh-TW-en.md`. Depends on that ticket landing first so no Swift code still calls the native ARK-ASR C ABI before it's removed.

## What to build

### 繁體中文

把 ARK-ASR／CrispASR 從 native build 完全拆掉，只留 Audio8 TTS（`generator + codec + tokenizer`）native archive。從 `scripts/build-audio8-ios.sh`、`scripts/build-audio8-macos.sh` 移除：CrispASR git clone 區塊、`AUDIO8_BUILD_ARK_ASR=ON`／`AUDIO8_ARK_ASR_SOURCE_DIR` cmake 參數、`audio8-ark-asr` target build/link、`audio8_ark_asr_shim.cpp` 編譯、ARK-ASR smoke binary 建置與執行。刪除 `scripts/audio8_ark_asr_shim.cpp`、`scripts/audio8_ark_asr_c_smoke.c`。從 `Packages/NativeShims/Sources/CAudio8` 移除 `include/audio8_ark_asr_capi.h` 及 shim.c 中對應的 ARK-ASR C 函式宣告/包裝（保留 `audio8_runtime.h` 與 TTS 相關符號）。確認 symbol-localization 步驟（`ld -r -exported_symbols_list`）之後只保留 TTS 公開符號。

### English

Strip ARK-ASR/CrispASR out of the native build entirely, leaving only the Audio8 TTS (`generator + codec + tokenizer`) native archive. Remove from `scripts/build-audio8-ios.sh` and `scripts/build-audio8-macos.sh`: the CrispASR git-clone block, the `AUDIO8_BUILD_ARK_ASR=ON`/`AUDIO8_ARK_ASR_SOURCE_DIR` cmake arguments, the `audio8-ark-asr` target build/link step, the `audio8_ark_asr_shim.cpp` compile step, and the ARK-ASR smoke-binary build/run. Delete `scripts/audio8_ark_asr_shim.cpp` and `scripts/audio8_ark_asr_c_smoke.c`. Remove `include/audio8_ark_asr_capi.h` and the corresponding ARK-ASR C declarations/wrappers from `Packages/NativeShims/Sources/CAudio8` (keep `audio8_runtime.h` and TTS symbols). Confirm the symbol-localization step (`ld -r -exported_symbols_list`) only exports TTS symbols afterward.

## Acceptance criteria

- [ ] `scripts/build-audio8-ios.sh` and `scripts/build-audio8-macos.sh` no longer reference CrispASR, `AUDIO8_BUILD_ARK_ASR`, or `AUDIO8_ARK_ASR_SOURCE_DIR`.
- [ ] `scripts/audio8_ark_asr_shim.cpp` and `scripts/audio8_ark_asr_c_smoke.c` deleted.
- [ ] `Packages/NativeShims/Sources/CAudio8` exposes only TTS (`audio8_runtime.h`) symbols; ARK-ASR C API header/declarations removed.
- [ ] Rebuilt `libaudio8_ios.a`/macOS equivalent contains only Audio8 TTS symbols (verify via `nm`).
- [ ] macOS arm64 and iOS Simulator arm64 app builds pass with the updated native archive.
- [ ] `third_party/CrispASR` is no longer cloned/required by any build script.

## Blocked by

- Issue #9 — Remove Audio8 STT (ARK-ASR) from the App layer / 移除 App 層 Audio8 STT (ARK-ASR)
