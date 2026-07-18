# Custom voice (read-aloud in your own voice)

Type text and have it spoken back in **your own voice**, verbatim, without going
through the assistant LLM. This is a "speak as me" path layered on top of the
existing STT → LLM → TTS conversation, which is left untouched.

## What you can do

| Input | How | Output |
| --- | --- | --- |
| **Type** | Type in the composer, press **Return** | Your exact text, spoken in your voice |
| **Dictate a file** | `doc.badge.plus` button → pick an audio/video file | Transcribed text dropped into the composer to review, then Return to speak |
| **Reference voice** | Settings → *Custom voice* → **Import…** | One-time: chooses whose voice everything is spoken in |

Microphone input is unchanged — when you speak there's already a voice, so no TTS
is involved.

## How it works

Voice cloning is fully supported down in `qwen3-tts.cpp`; this change only wires
the existing C API up to Swift and UI.

- **Import** (`ReferenceAudioImporter`): any Core Audio-decodable file is
  downmixed/resampled to **24 kHz mono 16-bit PCM WAV** — the only shape the
  native `load_audio_file` accepts (it rejects compressed and float32 WAV). The
  WAV is written into the app container under a per-import unique name.
- **Embedding cache** (`QwenTts`): on first use the reference WAV is run through
  the speaker encoder once (`qwen3_tts_extract_embedding_file`, ~1024 floats) and
  the embedding is memoized. Per-sentence synthesis then uses
  `qwen3_tts_synthesize_with_embedding`, skipping the encoder. Keyed by path, and
  each import writes a new filename, so a replaced voice never hits a stale cache.
- **Read-aloud path** (`ConversationEngine.speakText` → `SpeechPipeline` with a
  `referenceWavPath`): typed text is sentence-chunked and synthesized in the
  reference voice, bypassing the LLM. Falls back to the model's default voice when
  no voice is imported.
- **Dictation** (`ConversationEngine.dictateFile`): STT-only — transcribes the
  whole clip (no endpoint cutoff, no playback, no LLM) and hands the text to the
  composer via `dictatedText`.

The reference clip is **never transcribed** — cloning captures voice timbre only,
and the clone API takes no reference transcript, so the words in it don't matter.

## UI

- **Composer**: a `doc.badge.plus` dictate button, a `waveform` read-aloud toggle,
  and a mode-aware send button (speaker icon in read-aloud mode). **Return** sends
  / reads aloud; **Shift+Return** inserts a newline.
- **Settings → Custom voice (read aloud)**: import/remove the reference voice and
  toggle read-aloud mode. A 5–15 s clip works best.

## Notes / follow-ups

- Reference-voice conversion runs on the main thread; fine for short clips.
- No in-app recording yet — import only (a recorder could be added later).
- Not yet exercised end-to-end against real models; build verified.
