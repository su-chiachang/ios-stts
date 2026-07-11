# STTS Progress

macOS SwiftUI speech-to-speech conversation app. STT = parakeet.cpp, LLM = OpenAI-compatible API, TTS = qwen3-tts.cpp. Full plan: see `/Users/suchiachang/.claude/plans/swirling-wiggling-bonbon.md`.

## Status: M0, M1, M2 done, starting M3

- [x] M0 — native foundation (build scripts, models, dual-engine smoke test)
- [x] M1 — app skeleton (xcodegen project, views, model loading)
- [x] M2 — file-based STT transcription (audio/video input; live mic moved to M6, see below)
- [ ] M3 — LLM round trip (endpoint detection + SSE client)
- [ ] M4 — voice output (TTS + sentence chunking + playback)
- [ ] M5 — full loop + polish
- [ ] M6 — live mic transcription (AVAudioEngine) — deferred from M2 by explicit user request

**Milestone reorder**: originally M2 was "live mic transcription." User asked to build file-based (audio/video) input first instead — deterministic, no mic/permissions needed, lets the rest of the pipeline (LLM, TTS, conversation loop) get built and tested before dealing with AVAudioEngine capture. Live mic capture is now **M6**, done last, reusing the same `ParakeetStt` actor the file path already exercises.

## M0 findings (locked in, don't re-derive)

**Linking strategy works**: parakeet built as static libs (ggml v0.13 baked into the app executable), qwen3-tts kept as its native shared build (`libqwen3tts.dylib` + ggml v0.15 dylibs, embedded in `Frameworks/`, resolved via `@rpath`). Verified both in `Tools/SmokeTest` and in the real Xcode app target — no symbol collisions, both Metal backends initialize in one process.

**STT model decision**: use `nemotron-3.5-asr-streaming-0.6b` (q8_0) for both languages.
- Chinese locale key is **`zh-CN`**, not bare `zh` (bare `zh` errors: "unknown target_lang"). English is `en`.
- Transcription quality is near WER-0 in both languages (verified against macOS `say`-generated fixtures).
- **nemotron never emits EOU events**, even with 1.5s of trailing silence fed in. Confirmed by contrast: the dedicated `realtime_eou_120m-v1` model correctly fires `[EOU @ 7.84s]` on the same kind of fixture. Root cause (`src/streaming.cpp:36`): EOU token id is resolved by scanning vocab for the literal string `"<EOU>"`; nemotron's vocab doesn't have one.
- **Conclusion**: silence-based endpointing (`EndpointDetector`, not yet implemented) is the *primary* turn-taking mechanism for this app, not a fallback. EOU events should still be wired in and treated as a bonus early-trigger, since some future model might have them.
- **Bug found + fixed**: nemotron embeds a literal `<zh-CN>` / `<en-US>` tag inline in the returned transcript text (confirmed as model output, not a CLI artifact — not stripped anywhere in the C++ library). `ParakeetStt.feed()` / `.endTurn()` now strip it via regex before returning text. Re-verified clean (no tag leakage) in the M2 end-to-end test below.

**Known issue + mitigation**: at process exit, two independently-linked ggml copies (parakeet's static v0.13, qwen3-tts's dylib v0.15) each register their own ggml-metal device wrapper around the same physical GPU. Their static destructors race during teardown and hit `GGML_ASSERT([rsets->data count] == 0)` in `ggml-metal-device.m` — a Metal residency-set teardown-order bug, **not a correctness issue** (both engines produce correct output before this point). Mitigation: call `_exit(0)` instead of a normal return/exit path, which skips C++ static destructors entirely (safe — the OS reclaims all GPU/process resources on exit regardless). Applied in `Tools/SmokeTest` and `Tools/FileTranscribeTest`. **Still needs to be applied to the shipped app** (hook `applicationWillTerminate` / Quit — tracked as task M5-9).

**Model sources** (in case download needs to be repeated / `fetch-models.sh` needs updating):
- STT GGUFs: HF `mudler/parakeet-cpp-gguf` — `nemotron-3.5-asr-streaming-0.6b-q8_0.gguf` (984MB), `realtime_eou_120m-v1-q8_0.gguf` (176MB).
- TTS GGUFs: HF `Volko76/Qwen3-TTS-12Hz-0.6B-Base-Qwen3tts.cpp_quants-GGUF` — `qwen3-tts-0.6b-f16.gguf` (1.8GB), `qwen3-tts-tokenizer-f16.gguf` (341MB). (Community conversion, filenames match what `qwen3_tts.cpp`'s loader expects. `fetch-models.sh --convert` runs the canonical `setup_pipeline_models.py` pipeline instead if the CoreML code predictor export is needed later.)

## M2 findings (locked in, don't re-derive)

**File input works for both plain audio AND video containers via one code path.** `AudioFileInput` uses `AVAssetReader` (not `AVAudioFile`, which doesn't reliably open video containers) to pull the audio track out of *any* AVFoundation-readable file — wav, mp3, m4a, mp4, mov, etc. — and decode+resample it to 16kHz mono Float32 in one step via `AVAssetReaderTrackOutput`'s `outputSettings`. Verified: transcribing a `.wav` and an `ffmpeg`-muxed `.mp4` (same audio, h264 video track + AAC audio) of the same speech produced byte-for-byte identical transcripts.

**Sandbox correctly blocks arbitrary file paths — this is not a bug to work around.** Tried a debug hook in `STTSApp.swift` that set model/file paths directly from environment variables (bypassing `NSOpenPanel`); the sandboxed app correctly refused, since `com.apple.security.files.user-selected.read-only` only authorizes files the user actually picked through a panel/drag-drop, not arbitrary paths. Disabling the sandbox even temporarily to test around this was (correctly) blocked by the harness as a security-weakening action, and that block was right — the fix was to verify the same production code from an *unsandboxed* context instead, not to weaken the shipped app's sandbox.

**Verification approach that worked**: `Tools/FileTranscribeTest` is a small SPM executable that symlinks the *actual* production sources (`ParakeetStt.swift`, `AudioFileInput.swift`, `QwenTts.swift`, `AppSettings.swift`, `ConversationEngine.swift` — symlinked from `App/` into its `Sources/`, not reimplemented) and drives `ConversationEngine.transcribeFile(_:)` directly, unsandboxed. This is the pattern to reuse for future milestone verification whenever the sandbox would otherwise get in the way of testing real app code — symlink the real files into a throwaway SPM tool rather than reimplementing logic in a test harness or weakening the app's sandbox.

Result: real transcripts, tag-stripping confirmed clean, `.wav`/`.mp4` parity confirmed. Exact commands are in shell history; rerun via:
```
cd stts/Tools/FileTranscribeTest && swift build
./.build/debug/FileTranscribeTest <parakeet.gguf> <qwen3tts-model-dir> <file1> [file2 ...]
```

## What exists on disk

```
stts/
  scripts/build-parakeet-macos.sh    # done, tested
  scripts/build-qwen3tts-macos.sh    # done, tested (flattens versioned dylib names, fixes install names to @rpath)
  scripts/fetch-models.sh            # done, tested
  vendor/, models/, build/           # gitignored, populated
  Packages/NativeShims/              # CParakeet + CQwen3TTS SPM C shims, done
  Tools/SmokeTest/                   # M0 dual-engine verification tool, done — keep for regression checks
  Tools/FileTranscribeTest/          # M2 verification tool — symlinks real App/ sources, keep for regression checks
  project.yml                        # xcodegen spec, done
  App/
    STTSApp.swift                    # done (M1 scope: loads models on launch; no debug scaffolding left in it)
    Core/AppSettings.swift           # done (UserDefaults + security-scoped bookmarks)
    Core/ConversationEngine.swift    # done through M2: state enum, loadModels(), transcribeFile(_:)
    Audio/AudioFileInput.swift       # done — AVAssetReader-based file/video → 16kHz mono Float32 chunk stream
    STT/ParakeetStt.swift            # done — actor wrapping streaming C API, incl. lang-tag stripping
    TTS/QwenTts.swift                # done — actor wrapping synthesize C API
    UI/ConversationView.swift        # done — bubbles + status bar + "Transcribe File…" button (NSOpenPanel)
    UI/SettingsView.swift            # done (model pickers, LLM config, locale/threshold sliders; zh locale = "zh-CN")
    Resources/STTS.entitlements      # done (sandbox on: audio-input, network.client, user-selected read-only)
  App/Core/SentenceChunker.swift     # not yet written — M4
  App/Core/LanguageDetect.swift      # not yet written — M4
  App/STT/EndpointDetector.swift     # not yet written — M3
  App/LLM/OpenAIChatClient.swift     # not yet written — M3
  App/Audio/AudioInputManager.swift  # not yet written — M6 (live mic, deferred)
```

Xcode project builds successfully (`xcodegen generate && xcodebuild -project STTS.xcodeproj -scheme STTS build`). Real conversation loop (LLM + TTS) not yet wired — that's M3/M4.

Own git repo at `stts/.git` (separate from the parent `qwen3-tts.cpp` repo, which now ignores `stts/`). Nothing committed yet.

Test fixtures (gitignored, in `build/fixtures/`): `en.wav`/`zh.wav` (macOS `say` synthesized), `en_pad.wav`/`zh_pad.wav` (+1.5s trailing silence, for EOU testing), `en.mp4` (ffmpeg-muxed video+audio, for video-container testing). Regenerate with `say -v <voice> "<text>" -o x.aiff && afconvert x.aiff x.wav -d LEI16@16000 -c 1 -f WAVE`.

## Next up: M3 — LLM round trip

Per the plan: `EndpointDetector` (silence-based primary, EOU-event bonus — see M0 findings) + `OpenAIChatClient` (URLSession.bytes SSE client against an OpenAI-compatible `/chat/completions` endpoint, e.g. local llama-server + gemma). Wire so that when a turn ends, the finalized transcript goes to the LLM and the streamed reply appears as a live assistant bubble. File input still drives STT for now (M6 swaps in the mic); `EndpointDetector` can be exercised by feeding it the file-input chunk-by-chunk RMS/text signal the same way mic chunks will.
