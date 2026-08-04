## Parent

Audio8 ARK-ASR STT Integration spec — `docs/specs/audio8-stt-integration-spec.zh-TW-en.md`

## What to build

### 繁體中文

`audio8.cpp` 目前已有 `AUDIO8_BUILD_ARK_ASR` target 與自己的 wrapper
(`src/audio8_ark_asr.cpp`)，但 ASR kernel 本體 (`ark_asr.cpp`,
`core/gguf_loader.cpp`, `core/mel.cpp`) 仍需在 build 時指向外部 CrispASR
checkout (`AUDIO8_ARK_ASR_SOURCE_DIR`)。這是刻意的依賴切割，避免重複維護
kernel；一旦 `audio8.cpp` 決定將這些 kernel vendor 進自己 repo（或改由
audio8.cpp 自己發布/鎖定版本），STTS 這邊的 build script 應移除外部
CrispASR git clone 步驟，改成直接指向 audio8.cpp 內建來源。

追蹤 upstream `audio8.cpp` 是否/何時 vendor ARK-ASR kernel；一旦發生，
更新 `scripts/build-audio8-ios.sh`、`scripts/build-audio8-macos.sh`，
移除 `third_party/CrispASR` clone 與 `AUDIO8_ARK_ASR_SOURCE_DIR` 覆寫，
並同步更新 `docs/specs/audio8-stt-integration-spec.zh-TW-en.md` 中對
CrispASR 的描述。

### English

`audio8.cpp` already has an `AUDIO8_BUILD_ARK_ASR` target and its own
wrapper (`src/audio8_ark_asr.cpp`), but the ASR kernel itself
(`ark_asr.cpp`, `core/gguf_loader.cpp`, `core/mel.cpp`) still requires an
external CrispASR checkout at build time via
`AUDIO8_ARK_ASR_SOURCE_DIR`. This is a deliberate dependency split to
avoid duplicating kernel maintenance. If/when `audio8.cpp` vendors these
kernels into its own repository (or otherwise pins/ships them directly),
STTS's build scripts should drop the external CrispASR clone step and
point straight at audio8.cpp's own source.

Track whether/when upstream `audio8.cpp` vendors the ARK-ASR kernel; once
it does, update `scripts/build-audio8-ios.sh` and
`scripts/build-audio8-macos.sh` to remove the `third_party/CrispASR`
clone and the `AUDIO8_ARK_ASR_SOURCE_DIR` override, and update
`docs/specs/audio8-stt-integration-spec.zh-TW-en.md`'s description of the
CrispASR dependency accordingly.

## Acceptance criteria

- [ ] Confirm current upstream `audio8.cpp` status: does it vendor the
      ARK-ASR kernel yet, or still require an external `CrispASR` source
      directory?
- [ ] If vendored: remove the `third_party/CrispASR` git clone block and
      `AUDIO8_ARK_ASR_SOURCE_DIR` default/override from
      `scripts/build-audio8-ios.sh` and `scripts/build-audio8-macos.sh`.
- [ ] Build points `AUDIO8_BUILD_ARK_ASR` at audio8.cpp's own vendored
      source; macOS and iOS arm64 builds still produce
      `libaudio8_ios.a` / equivalent with both TTS and ARK-ASR symbols.
- [ ] `docs/specs/audio8-stt-integration-spec.zh-TW-en.md` and this
      ticket's parent references no longer describe CrispASR as an
      external build-time dependency.
- [ ] If not yet vendored upstream: leave this ticket open/blocked and
      note the upstream tracking issue or commit to watch.

## Blocked by

- Upstream `audio8.cpp` vendoring its own ARK-ASR kernel sources (not yet
  done as of this ticket's filing).
