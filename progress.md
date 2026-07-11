# STTS Progress

macOS SwiftUI speech-to-speech conversation app. STT = parakeet.cpp, LLM = OpenAI-compatible API, TTS = qwen3-tts.cpp. Full plan: see `/Users/suchiachang/.claude/plans/swirling-wiggling-bonbon.md`.

## Reference repos
- speech-to-speech: https://github.com/huggingface/speech-to-speech
- parakeet.cpp: https://github.com/mudler/parakeet.cpp
- qwen3-tts.cpp: https://github.com/predict-woo/qwen3-tts.cpp
- whisper.cpp: https://github.com/ggml-org/whisper.cpp

## Status: M0–M6 implementation complete

- [x] M0 — native foundation (build scripts, models, dual-engine smoke test)
- [x] M1 — app skeleton (xcodegen project, views, model loading)
- [x] M2 — file-based STT transcription (audio/video input; live mic moved to M6, see below)
- [x] M3 — LLM round trip (endpoint detection + SSE client)
- [x] M4 — voice output (TTS + sentence chunking + playback)
- [x] M5 — full loop + polish
- [x] M6 — live mic transcription (AVAudioEngine)

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
- TTS GGUFs: HF `badlogicgames/qwen3-tts-0.6b-q8_0-gguf` — `qwen3-tts-0.6b-q8_0.gguf` (Q8, preferred by the native loader) and `qwen3-tts-tokenizer-f16.gguf` (341MB). The existing F16 talker remains a fallback until the Q8 download completes. `fetch-models.sh --convert` runs the canonical `setup_pipeline_models.py` pipeline instead if the CoreML code predictor export is needed later.

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
    Core/ConversationEngine.swift    # done through M4: file STT → LLM → sentence TTS/playback
    Audio/AudioFileInput.swift       # done — AVAssetReader-based file/video → 16kHz mono Float32 chunk stream
    STT/ParakeetStt.swift            # done — actor wrapping streaming C API, incl. lang-tag stripping
    TTS/QwenTts.swift                # done — actor wrapping synthesize C API
    UI/ConversationView.swift        # done — bubbles + status bar + "Transcribe File…" button (NSOpenPanel)
    UI/SettingsView.swift            # done (model pickers, LLM config, locale/threshold sliders; zh locale = "zh-CN")
    Resources/STTS.entitlements      # done (sandbox on: audio-input, network.client, user-selected read-only)
  App/Core/SentenceChunker.swift     # done — M4 CJK-aware streaming sentence splitter
  App/Core/LanguageDetect.swift      # done — M4 Han-ratio → Qwen language id routing
  App/Core/SpeechPipeline.swift      # done — M4 serialized synthesis + concurrent playback pipeline
  App/Audio/AudioPlayer.swift        # done — M4 AVAudioEngine/player-node buffer playback
  App/STT/EndpointDetector.swift     # done — M3
  App/LLM/OpenAIChatClient.swift     # done — M3
  App/Audio/AudioInputManager.swift  # done — M6 mic → 16 kHz mono Float32 chunk stream
  App/Audio/SourceMediaPlayer.swift  # done — selected file's original audio during subtitle transcription
```

Xcode project builds successfully (`xcodegen generate && xcodebuild -project STTS.xcodeproj -scheme STTS build`). The M3/M4 file-input loop now streams STT → LLM → sentence TTS/playback; M5 adds controls and conversation-loop polish.

Own git repo at `stts/.git` (separate from the parent `qwen3-tts.cpp` repo, which now ignores `stts/`). Nothing committed yet.

Test fixtures (gitignored, in `build/fixtures/`): `en.wav`/`zh.wav` (macOS `say` synthesized), `en_pad.wav`/`zh_pad.wav` (+1.5s trailing silence, for EOU testing), `en.mp4` (ffmpeg-muxed video+audio, for video-container testing). Regenerate with `say -v <voice> "<text>" -o x.aiff && afconvert x.aiff x.wav -d LEI16@16000 -c 1 -f WAVE`.

## M3 findings (locked in)

**The file-input path now exercises the same primary endpoint logic as the future mic path.** `EndpointDetector` is a pure value type: a model EOU event ends the turn immediately; otherwise it measures RMS from each 16 kHz PCM chunk and ends after detected speech plus the configured silent interval and a non-empty partial transcript. `ConversationEngine.transcribeFile(_:)` feeds each chunk through it, while EOF remains the deterministic fallback for short fixture files without trailing silence.

**LLM streaming is OpenAI-compatible and does not depend on a particular server.** `OpenAIChatClient` normalizes the configured base URL to `/chat/completions`, posts the configured system prompt plus chat history with `stream: true`, and reads `data:` SSE events until `[DONE]`. Text deltas update a newly-created assistant bubble on the main actor; malformed URLs, HTTP failures, and SSE/transport errors flow into the existing UI error state. `Authorization` is sent only when an API key is configured, allowing local llama-server endpoints without dummy credentials.

**Verified locally:** the arm64 macOS app target builds; an isolated `EndpointDetector` test covers the 0.8-second silence and EOU triggers; and an `URLProtocol`-backed mock endpoint verifies SSE text-delta assembly, `/v1/chat/completions` URL construction, and Authorization handling. Performing the milestone's live round-trip checks still requires a running OpenAI-compatible endpoint (local llama-server + gemma and a cloud endpoint/API key) selected by the user in Settings. No endpoint credentials or server were present in the workspace, so none were invented.

## M4 findings (locked in)

**Sentence-level pipelining hides Qwen's non-streaming synthesis.** `SentenceChunker` extracts CJK/Latin sentence boundaries at 10+ characters (or a 120-character hard split), and `SpeechPipeline` starts synthesis of the following sentence once the previous sentence's buffer has been scheduled. `AVAudioPlayerNode` renders that prior buffer independently, so synthesis and playback overlap without concurrent access to Qwen's native handle.

**Language routing stays local and deterministic.** `LanguageDetect` selects Qwen Chinese (2055) when Han scalars are over 30% of non-whitespace content; otherwise it selects English (2050). This avoids an additional language-ID model or network round trip.

**Verified locally:** `SentenceChunker` handling of English, CJK, flush, and hard-split paths plus `LanguageDetect` routing pass in an isolated test. `AudioPlayer` successfully schedules and completes a 24 kHz mono buffer against the real audio engine. The initial test exposed a stereo-output/mono-buffer assertion, fixed by explicitly connecting the player node at Qwen's 24 kHz mono format and allowing the mixer to perform hardware-output conversion. The full production-source SPM tool and arm64 macOS app target build successfully.

## M5 findings (locked in)

**Every conversation turn is cancel-safe.** `ConversationEngine` assigns each file-driven turn an ID; late completions from cancelled STT, LLM, or TTS work can no longer overwrite a newer turn's state. Stop cancels the active task and `SpeechPipeline`, flushes queued playback, and returns to Ready. Reset additionally clears the transcript history. The file chooser remains disabled while a turn is active, preserving the half-duplex interaction model until M6 adds a microphone source.

**The shipped app skips the known ggml Metal destructor race.** `AppDelegate.applicationWillTerminate` flushes standard I/O and calls `_exit(0)`, matching the already verified smoke-test and file-test mitigation. The OS reclaims process resources without allowing the two incompatible ggml static-destructor chains to race.

## M6 findings (locked in)

**Live and file transcription share the same turn semantics.** `AudioInputManager` taps AVAudioEngine's input node, uses `AVAudioConverter` to produce 16 kHz mono Float32 PCM, accumulates deterministic 100 ms chunks, and reports RMS with every chunk. The chunks feed the existing `ParakeetStt` actor and silence/EOU detector without a parallel STT path.

**Microphone conversation is half-duplex and self-rearming.** Listen requests permission before capture. An endpoint stops capture before LLM/TTS work begins; after the assistant finishes playback, the engine automatically starts a fresh microphone turn. Stop cancels this rearm path as well as active capture and audio playback. The UI exposes Listen and live RMS alongside the existing threshold setting.

**Verified locally:** the production-source SPM target and arm64 macOS app target build with the AVAudioEngine integration. Final hardware verification requires granting microphone access and using a configured OpenAI-compatible endpoint from the app, which was not automated in the workspace.

**Post-MVP composer:** the conversation view includes a bottom multi-line text composer, Send control, and voice-input toggle. Typed text and finalized speech share the same LLM/TTS history; assistant bubbles are left-aligned with an assistant icon, while user bubbles are right-aligned with a user icon. Selected media now plays its original audio while realtime file transcription publishes subtitles. `qwen3-tts.cpp` prefers Q8 automatically when `qwen3-tts-0.6b-q8_0.gguf` is present, otherwise it falls back to F16.

## MVP implementation complete

For hands-on verification: choose both model paths in Settings, configure an LLM endpoint, press Listen, speak a short English or Chinese utterance, and confirm partial text, streamed response, sentence playback, and automatic return to Listening. Use Stop to cancel immediately.
