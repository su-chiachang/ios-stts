## Parent

Issue #11 — Retire Audio8 STT docs and repo artifacts / 淘汰 Audio8 STT 相關文件與 repo 產物

Closes out the removal of `docs/specs/audio8-stt-integration-spec.zh-TW-en.md`'s scope. Depends on [07 — Remove Audio8 STT (ARK-ASR) from the App layer](07-remove-audio8-stt-app-layer.zh-TW-en.md) and [08 — Remove ARK-ASR/CrispASR from native Audio8 build](08-remove-ark-asr-native-build.zh-TW-en.md) both landing so docs reflect the actual end state.

## What to build

### 繁體中文

更新文件反映 Audio8 STT 已移除、只保留 Audio8 TTS 的最終狀態。在 `docs/specs/audio8-stt-integration-spec.zh-TW-en.md` 頂端加上明確的「已還原/移除」狀態說明（不要直接刪除，保留歷史紀錄），並記錄還原原因（STT 依賴外部 CrispASR checkout，決定不維護此依賴）。在 `progress.md` 補一筆紀錄這次還原。移除本機 `third_party/CrispASR` checkout 目錄（若還留著）並確認沒有 `.gitignore`／build 腳本再指向它。

### English

Update documentation to reflect the final state: Audio8 STT removed, only Audio8 TTS remains. Add an explicit "reverted/removed" status note at the top of `docs/specs/audio8-stt-integration-spec.zh-TW-en.md` (don't delete it outright — keep it as history) recording why (STT depended on an external CrispASR checkout; decided not to maintain that dependency). Add a `progress.md` entry for this reversion. Remove the local `third_party/CrispASR` checkout directory if still present, and confirm no `.gitignore`/build script still points at it.

Note: `docs/tickets/06-vendor-ark-asr-remove-crispasr-dependency.zh-TW-en.md` (an earlier, now mis-scoped ticket proposing to *vendor* ARK-ASR instead of removing it) was deleted directly during the wayfinder session that opened this ticket, since the destination changed from "vendor" to "remove" before that file was ever backed by a real GitHub issue. No action needed here.

## Acceptance criteria

- [ ] `docs/specs/audio8-stt-integration-spec.zh-TW-en.md` has a clear reverted/removed status note at the top.
- [ ] `progress.md` records the STT removal and its reason.
- [ ] `third_party/CrispASR` is removed from the local checkout and not referenced by any script.
- [ ] `rg -i "ark.asr|ark_asr"` (excluding historical/removed-status notes) returns no remaining production references in `App/`, `Packages/`, `scripts/`.

## Blocked by

- Issue #9 — Remove Audio8 STT (ARK-ASR) from the App layer / 移除 App 層 Audio8 STT (ARK-ASR)
- Issue #10 — Remove ARK-ASR/CrispASR from native Audio8 build / 移除 native Audio8 build 中的 ARK-ASR/CrispASR
