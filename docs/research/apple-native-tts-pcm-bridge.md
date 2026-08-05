# Research: Apple PCM Synthesis Bridge for iOS 17 and macOS 15

## Context

- Wayfinder ticket: [Research Apple PCM Synthesis Bridge for iOS 17 and macOS 15](https://github.com/su-chiachang/ios-stts/issues/14)
- Wayfinder map: [Wayfinder: Apple Native TTS Backend Integration](https://github.com/su-chiachang/ios-stts/issues/13)
- Research date: 2026-08-05
- Sources were restricted to Apple Developer documentation and Apple-provided SDK/sample source. The supplied local sample was inspected at `/Users/chiachangsu/_clt/CreatingACustomSpeechSynthesizer`.

There was no existing `docs/research/` convention in this repository, so this note establishes the sensible location `docs/research/apple-native-tts-pcm-bridge.md`. No production code was changed.

## Decision-level finding

The supported app-internal bridge is `AVSpeechSynthesizer.write(_:toBufferCallback:)`. It asks Apple’s speech synthesizer to generate audio buffers for an `AVSpeechUtterance`, allowing STTS to copy the buffers into its existing `TtsAudioChunk` contract and continue through `SpeechPipeline` and `AudioPlayer`. Apple describes speech synthesis as on-device and the `write` API as intended for storing or further processing generated audio. [Speech synthesis](https://developer.apple.com/documentation/avfoundation/speech-synthesis), [`write(_:toBufferCallback:)`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write%28_%3Atobuffercallback%3A%29)

This is separate from the supplied custom speech synthesizer sample. The sample is a system-wide `AVSpeechSynthesisProviderAudioUnit` extension for voices used by `AVSpeechSynthesizer`, VoiceOver, and Speak Screen; it is explicitly outside the map’s destination. [Creating a custom speech synthesizer](https://developer.apple.com/documentation/avfaudio/creating-a-custom-speech-synthesizer), [`AVSpeechSynthesisProviderAudioUnit`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisprovideraudiounit)

## API and deployment support

The availability declarations below come from Apple’s AVFAudio SDK header at `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/AVSpeechSynthesis.h` (the same declarations are present in the macOS 15 SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk/System/Library/Frameworks/AVFAudio.framework/Versions/A/Headers/AVSpeechSynthesis.h`). The public API references are linked for the behavioral documentation.

| API | Apple availability | Relevance to STTS |
| --- | --- | --- |
| `AVSpeechSynthesizer` | iOS 7.0+, macOS 10.14+ | Synthesizer object; both target deployments support it. |
| `write(_:toBufferCallback:)` | iOS 13.0+, macOS 10.15+ | Primary PCM-producing bridge; both target deployments support it. |
| `write(_:toBufferCallback:toMarkerCallback:)` | iOS 16.0+, macOS 13.0+ | Current marker-capable equivalent; available on both targets, but markers are not required by the existing playback contract. [`MarkerCallback`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/markercallback) |
| `AVSpeechSynthesizerDelegate` finish/cancel events | iOS 7.0+, macOS 10.14+ | Available as lifecycle signals, subject to the `write` caveat below. [`AVSpeechSynthesizerDelegate`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate) |
| `AVSpeechSynthesisAvailableVoicesDidChangeNotification` | iOS 17.0+, macOS 14.0+ | Available on both targets for refreshing readiness/voice state. [`availableVoicesDidChangeNotification`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/availablevoicesdidchangenotification) |

The non-marker overload is therefore not a compatibility workaround: it is already supported by the project’s minimum iOS 17 and macOS 15 deployments. The marker overload should remain an optional extension point for future word/sentence timing, not a prerequisite for the first backend.

## PCM format and sample-rate behavior

Apple’s public callback type is `AVSpeechSynthesizer.BufferCallback = (AVAudioBuffer) -> Void`, not a statically promised `AVAudioPCMBuffer`. [`BufferCallback`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/buffercallback) and Apple’s SDK header define the parameter as `AVAudioBuffer`.

The format is voice-dependent, not a single Apple-wide speech rate. `AVSpeechSynthesisVoice.audioFileSettings` describes the format that the callback provides for that voice; Apple says the settings can be used to create an `AVAudioFile`, and that the dictionary matches the callback data. The settings expose the common format/interleaving information, while Apple’s standard audio settings define keys such as sample rate, format ID, and channel count. [`audioFileSettings`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/audiofilesettings), [Format settings](https://developer.apple.com/documentation/avfaudio/format-settings)

Implications:

1. Do not hard-code 22,050 Hz, 24 kHz, or 44.1 kHz as the Apple synthesizer output format.
2. Resolve the selected voice first, inspect its `audioFileSettings`, and inspect the received buffer’s actual `AVAudioFormat`.
3. Accept only a PCM buffer at the bridge boundary (or explicitly convert another `AVAudioBuffer` representation); copy its samples before returning from the callback because the public API does not transfer ownership of an app-owned long-lived sample array.
4. Convert to the app’s existing `TtsAudioChunk` representation: mono `Float32` samples plus the source sample rate. The existing [`AudioPlayer`](../../App/Audio/AudioPlayer.swift) already converts source sample rates to its stable 44.1 kHz mono playback format.

The supplied sample’s `22_050 Hz`, mono, non-interleaved `Float32` format is an implementation choice for that extension’s `AUAudioUnitBus`, not a promise about `AVSpeechSynthesizer.write`. The sample sets that format in `CustomSpeechSynthesizerExampleAudioUnit.swift` before rendering its own audio unit; it must not be used as the native backend’s format constant.

## Completion, cancellation, and retention

### What Apple documents

- `write` returns `Void` and accepts a buffer callback. The marker overload adds a marker callback, not a completion callback. Apple’s public method documentation says the callback receives generated audio but does not specify a terminal callback, callback count, zero-length sentinel, or end-of-stream object. [`write(_:toBufferCallback:)`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write%28_%3Atobuffercallback%3A%29), [`write(_:toBufferCallback:toMarkerCallback:)`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write%28_%3Atobuffercallback%3Atomarkercallback%3A%29)
- The delegate exposes `didStart`, `didFinish`, `didPause`, `didContinue`, and `didCancel`. Apple documents these as speech-synthesizer utterance events, but does not state that `didFinish` is the completion contract for an offline `write` buffer stream. [`AVSpeechSynthesizerDelegate`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate), [AVSpeechUtterance](https://developer.apple.com/documentation/avfaudio/avspeechutterance)
- `stopSpeaking(at:)` is the public stop primitive. Apple documents that stopping immediately cancels speech and removes unspoken utterances from the queue; `.immediate` and `.word` are the available boundaries. [`stopSpeaking(at:)`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/stopspeaking%28at%3A%29)
- Apple notes that the system does not automatically retain the synthesizer until speech concludes. The backend must retain one synthesizer for the whole request lifecycle rather than creating a local temporary object and letting it deallocate. [`AVSpeechSynthesizer`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer)

### Design consequence

There is no fully documented `write`-specific completion contract to directly map to `async throws -> TtsAudioChunk`. The implementation should therefore:

- serialize one synthesizer and one active request at a time;
- assign each request a generation/token and ignore buffers arriving after cancellation or replacement;
- copy PCM samples immediately in the callback, then hop to the backend’s isolated state;
- use `stopSpeaking(at: .immediate)` for cancellation and clear the token before flushing the app player;
- treat delegate completion/cancellation as a signal to test and integrate, not as a documented substitute for a missing `write` completion callback;
- add an on-device lifecycle prototype before production implementation, covering iOS 17 and macOS 15, because Apple’s public sources do not specify how `write` callbacks terminate or exactly how `stopSpeaking` interacts with an in-progress `write` request.

A zero-frame callback is not recorded here as an Apple-supported contract: neither the public method documentation nor the SDK header specifies it. If target testing observes that behavior, it should be guarded by regression tests and treated as an implementation detail rather than the only correctness mechanism.

## Callback threading and Swift isolation

Apple provides no callback queue or thread guarantee for `BufferCallback` in the public documentation or SDK declaration. The closure is escaping, but there is no queue parameter, main-thread annotation, or documented serialization guarantee. The current SDK also marks `AVSpeechSynthesizer` and `AVSpeechUtterance` as Swift non-sendable, while the delegate protocol is sendable; that does not establish a callback executor.

Recommended bridge discipline:

- Keep `AVSpeechSynthesizer` and `AVSpeechUtterance` inside one actor/serial isolation domain.
- Do not touch `@MainActor` UI or `AudioPlayer` state directly from the buffer callback.
- Copy the PCM data and format synchronously, then send only owned, value-type data to the backend actor/pipeline.
- Do not block the callback waiting for `AudioPlayer`; the callback should only validate/copy/enqueue work.

These are defensive requirements inferred from the API’s unspecified execution context and non-sendable SDK declarations, not claims that Apple promises a particular private queue.

## Interruptions and audio-session ownership

On iOS, `usesApplicationAudioSession` is available from iOS 13 and defaults to `true`. Apple says `true` uses the shared application audio session; `false` creates a separate session whose active state, interruptions, mixing, and ducking are managed automatically. The property is unavailable on macOS. [`usesApplicationAudioSession`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/usesapplicationaudiosession)

For STTS’s app-internal PCM path, the recommended first implementation is to leave the iOS property at its default (`true`) and let the app’s existing `AVAudioEngine`/`AudioPlayer` own actual playback. The synthesizer is being used as a generator, not as the final audio route. This avoids introducing a second automatically managed audio session; the recommendation should be verified in the lifecycle prototype because Apple documents the property in terms of speech output, not specifically offline buffer generation.

The app should observe iOS `AVAudioSession.interruptionNotification` at the playback/session layer. Apple documents that the notification is posted when an interruption occurs and that it is delivered on the main thread; the interruption article shows handling begin/end and the resume option. On interruption begin, cancel the active synthesis generation and flush queued PCM; on end, resume only according to the app’s explicit playback policy. [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions), [`AVAudioSession.interruptionNotification`](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification)

macOS 15 has the speech and `write` APIs, but not `AVAudioSession` or `usesApplicationAudioSession`. Its interruption/route behavior must be tested through the app’s macOS audio engine path rather than assuming iOS audio-session notifications apply.

## Voice and locale availability

Apple’s voice selection model matches the map’s language-first recommendation:

- `AVSpeechSynthesisVoice(language:)` accepts a BCP 47 language/region tag. Passing `nil` requests the default voice; an invalid language code returns `nil`; if an enhanced voice is available, Apple prefers it, otherwise it falls back to default quality. [`AVSpeechSynthesisVoice`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice), [`language`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/language)
- `speechVoices()` returns the voices currently available on the device, and each voice exposes its language/locale, identifier, quality, and audio settings. [`speechVoices()`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/speechvoices%28%29)
- Default quality is available on-device; enhanced and premium quality voices must be downloaded. [`AVSpeechSynthesisVoiceQuality`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoicequality)
- A valid voice identifier can still return `nil` when that voice is not available on the device because it has not been downloaded. This makes readiness a device state, not a compile-time guarantee. [`identifier`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/identifier)
- Apple posts `availableVoicesDidChangeNotification` when available voices change, including downloaded third-party voices or newly authorized personal voices. The target OS versions support this notification. [`availableVoicesDidChangeNotification`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/availablevoicesdidchangenotification)

Recommended resolver behavior:

1. Map the app’s detected `SpokenLanguage` to a BCP 47 candidate (for example, an English or Chinese regional tag).
2. Prefer an available voice whose `language` matches the requested language/region; if the exact region is absent, choose a same-language available voice.
3. If no candidate is available, call the documented default-voice path (`AVSpeechSynthesisVoice(language: nil)`) and report the selected voice/readiness state to the UI.
4. Refresh availability after `availableVoicesDidChangeNotification`.

The exact `en`/`zh` regional mapping remains a separate product decision; Apple defines the input as BCP 47 and exposes the installed list, but does not choose STTS’s preferred region for it.

## Distinction from the supplied custom synthesizer sample

| App-internal Apple backend | Supplied Apple sample |
| --- | --- |
| App owns an `AVSpeechSynthesizer`, creates an `AVSpeechUtterance`, calls `write`, receives buffers, and sends copied PCM through STTS’s existing pipeline. | The system discovers an Audio Unit extension and asks its `AVSpeechSynthesisProviderAudioUnit` to render speech for system use. |
| Uses installed system voices selected by BCP 47 language/locale. | Publishes custom `AVSpeechSynthesisProviderVoice` entries with primary/supported languages. |
| No App Group, extension target, Audio Unit factory, or system voice registration is needed. | The host app stores voice names in an App Group and calls `AVSpeechSynthesisProviderVoice.updateSpeechVoices()`; the extension is registered as `com.apple.AudioUnit`. |
| App’s `AudioPlayer` is the final playback owner. | The extension provides an output bus and `internalRenderBlock`; it signals completion with `offlineUnitRenderAction_Complete` and handles `cancelSpeechRequest()`. |
| Callback format is obtained from the selected native voice. | The sample explicitly chooses 22,050 Hz mono non-interleaved Float32 for its output bus. |

Local first-party sample evidence:

- `CustomSpeechSynthesizerExample/ContentView.swift:55-61` stores voice names in the shared App Group and calls `updateSpeechVoices()`.
- `CustomSpeechSynthesizerExampleExtension/Info.plist:9-36` registers the `com.apple.AudioUnit` extension.
- `CustomSpeechSynthesizerExampleExtension/CustomSpeechSynthesizerExampleAudioUnit.swift:10` subclasses `AVSpeechSynthesisProviderAudioUnit`; lines 30-48 choose the 22,050 Hz output format; lines 74-103 render through the Audio Unit block; lines 107-115 receive and cancel provider requests.

Apple’s sample documentation confirms that provider voices are surfaced for system speech technologies and that the provider receives an `AVSpeechSynthesisProviderRequest`, renders through its Audio Unit, and uses `cancelSpeechRequest()` for cancellation. [Creating a custom speech synthesizer](https://developer.apple.com/documentation/avfaudio/creating-a-custom-speech-synthesizer), [`AVSpeechSynthesisProviderAudioUnit`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisprovideraudiounit)

## Handoff and remaining decision ticket

The research decision is resolved as follows: implement the Apple backend around `AVSpeechSynthesizer.write`, copy/normalize the voice-specific PCM buffers into the existing `TtsAudioChunk` path, use language-matched installed voices with default fallback, isolate the non-sendable synthesizer, and coordinate cancellation/interruption with `SpeechPipeline` and `AudioPlayer`. Do not implement the provider extension sample.

One precise follow-up is required before production implementation: prototype the `write` stream’s terminal behavior, callback executor, actual formats, and cancellation race on iOS 17 and macOS 15. This is an implementation-risk ticket, not a reason to switch to the system-wide provider model.
