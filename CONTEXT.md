# STTS Apple-only Context

STTS uses Apple's platform speech services directly. The app has no bundled
speech model, native speech runtime, model downloader, or user-selectable
speech backend.

## Speech engines

**Apple SpeechTranscriber**:
The only STT engine. It resolves an optional locale identifier to an Apple
supported locale, installs the required system asset when needed, and exposes
streaming transcript updates plus timestamped file transcription.

**Apple AVSpeechSynthesizer**:
The only TTS engine. It selects an installed system voice from the detected
spoken language and returns PCM chunks to the shared audio player.

**Apple Foundation Models**:
The only TTT provider. It streams assistant text through the Apple adapter
when the OS and device support Foundation Models.

## Application shape

- The STT, TTS, and TTT screens expose Apple functionality directly.
- There is no in-app Settings screen or model-download screen.
- `StsEngine` owns the three Apple engines and lifecycle coordination.
- `SpeechPipeline` serializes Apple TTS synthesis and audio playback.
- `SttEngine`, `TtsEngine`, and `TttEngine` are narrow runtime seams for
  protocol conformance and tests; they do not represent selectable backends.
- The Xcode project links only system AVFoundation, AVFAudio, Speech, and
  FoundationModels frameworks.

Historical Audio8/Qwen/Parakeet specifications and tickets under `docs/` are
archival records, not supported project components.
