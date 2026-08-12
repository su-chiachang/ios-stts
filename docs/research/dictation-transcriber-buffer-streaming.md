# Research: DictationTranscriber AVAudioBuffer ingestion and lifecycle

- Issue: [DictationTranscriber AVAudioBuffer ingestion and lifecycle](https://github.com/su-chiachang/ios-stts/issues/65)
- Research date: 2026-08-11
- Branch: `research/dictation-transcriber-buffer`
- Scope: construction and availability, locale/model readiness, file and buffer ingestion, format and ownership, result sequencing, timestamps, finalization, cancellation, and errors for `DictationTranscriber` on iOS/macOS 26; comparison with `SFSpeechAudioBufferRecognitionRequest`.
- Source policy: Apple Developer Documentation, Apple SDK interfaces, and Apple’s WWDC25 first-party sample material only. No production code was changed.

## Executive findings

1. `DictationTranscriber` and `SpeechAnalyzer` are available on iOS 26.0 and macOS 26.0, and unavailable on tvOS/watchOS. The module is constructed with a locale plus either a preset or explicit option sets. It does not expose the `SpeechTranscriber.isAvailable` Boolean; readiness is expressed through locale support, installed assets, compatible audio formats, and analyzer errors. [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber), [SpeechTranscriber `isAvailable`](https://developer.apple.com/documentation/speech/speechtranscriber/isavailable)

2. The exact buffer bridge depends on the SDK used to build the app. The locally installed Xcode 26.4.1 iOS/macOS 26.4 Swift interfaces expose `AnalyzerInput` only for `AVAudioPCMBuffer`. Apple’s current online documentation additionally lists the beta `AnalyzerInputConverter`, whose input is `AVAudioBuffer` and whose conversion result is `[AnalyzerInput]`. That converter and the beta file/capture providers are absent from both local 26.4 Swift interfaces inspected here. This is the principal implementation blocker.

3. For the local SDK, import a file with `AVAudioFile`; Apple documents that file reads produce `AVAudioPCMBuffer` in the file’s processing format. Select the module-compatible format with `SpeechAnalyzer.bestAvailableAudioFormat`, convert explicitly, and yield `AnalyzerInput(buffer:bufferStartTime:)` values. Do not assume the analyzer transparently resamples: Apple says it does not, in order to preserve sample-accurate `CMTime` values. [AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile), [SpeechAnalyzer audio formats](https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat%28compatiblewith%3A%29), [AnalyzerInput initializer](https://developer.apple.com/documentation/speech/analyzerinput/init%28buffer%3Abufferstarttime%3A%29)

4. For the current online beta API, pass each `AVAudioBuffer` through `AnalyzerInputConverter.convert(_:at:)`, yield every returned `AnalyzerInput`, call `flush()` before ending the input sequence, then finish the analyzer. Apple explicitly says the converter may retain an input buffer across calls; the caller must not reuse or modify it. [AnalyzerInputConverter](https://developer.apple.com/documentation/speech/analyzerinputconverter), [`convert(_:at:)`](https://developer.apple.com/documentation/speech/analyzerinputconverter/convert%28_%3Aat%3A%29), [`flush()`](https://developer.apple.com/documentation/speech/analyzerinputconverter/flush%28%29)

5. New results are an `AsyncSequence`. With `.volatileResults`, the same audio range can be emitted repeatedly while the interpretation improves; a `false` `isFinal` result is not guaranteed to be reissued as `true`. Track volatile and finalized ranges separately instead of concatenating every result. `resultsFinalizationTime` and `range` provide the finalization boundary. [DictationTranscriber.Result](https://developer.apple.com/documentation/speech/dictationtranscriber/result), [`SpeechModuleResult.isFinal`](https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal), [`resultsFinalizationTime`](https://developer.apple.com/documentation/speech/speechmoduleresult/resultsfinalizationtime)

6. For timestamps, construct the transcriber with `.audioTimeRange`; Apple then adds `SpeechAttributes.TimeRangeAttribute` values to the returned `AttributedString`. The result also always carries a `CMTimeRange`, but the per-text time attributes require the option. [DictationTranscriber.ResultAttributeOption.audioTimeRange](https://developer.apple.com/documentation/speech/dictationtranscriber/resultattributeoption/audiotimerange)

7. A streaming New session must explicitly finish. Ending an `AsyncStream` alone generally does not finish the analyzer; after the input is terminated, use `finalizeAndFinishThroughEndOfInput()`. Cancellation uses `cancelAndFinishNow()`. For Old, `SFSpeechAudioBufferRecognitionRequest` is a live/existing-buffer request, requires native uncompressed PCM, and must receive `endAudio()`; the recognition task can separately be finished or cancelled. [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [`finalizeAndFinishThroughEndOfInput()`](https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput%28%29), [`cancelAndFinishNow()`](https://developer.apple.com/documentation/speech/speechanalyzer/cancelandfinishnow%28%29), [SFSpeechAudioBufferRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest)

## SDK snapshot and version discrepancy

The local toolchain is Xcode 26.4.1 (Build 17E202). The SDK paths selected by `xcrun` are:

```text
/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.4.sdk
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.4.sdk
```

The local iOS Swift interface declares:

- `DictationTranscriber` at `Speech.swiftinterface:46-168`, with `@available(macOS 26.0, iOS 26.0, ...)` and the locale, preset, result, and compatible-format APIs.
- `SpeechAnalyzer` at `Speech.swiftinterface:205-240`.
- `AnalyzerInput` at `Speech.swiftinterface:241-248`, with initializers that accept `AVAudioPCMBuffer`, not `AVAudioBuffer`.

The same declarations were present in the local macOS 26.4 Swift interface. A text search of both interfaces found no `AnalyzerInputConverter`, `AssetInputSequenceProvider`, or `CaptureInputSequenceProvider` declaration. Apple’s current online [Speech framework overview](https://developer.apple.com/documentation/speech/) and [Speech updates](https://developer.apple.com/documentation/updates/speech) list those APIs as beta/current documentation, so the online API surface is newer or ahead of this installed SDK. This is a local toolchain observation, not a claim that the APIs will never ship.

## New API: construction, availability, and model readiness

### Construction and availability

The local SDK declaration is equivalent to:

```swift
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
final class DictationTranscriber: SpeechModule, LocaleDependentSpeechModule {
    convenience init(locale: Locale, preset: Preset)
    convenience init(
        locale: Locale,
        contentHints: Set<ContentHint>,
        transcriptionOptions: Set<TranscriptionOption>,
        reportingOptions: Set<ReportingOption>,
        attributeOptions: Set<ResultAttributeOption>
    )
}
```

The standard presets include `phrase`, `shortDictation`, `progressiveShortDictation`, `longDictation`, `progressiveLongDictation`, and `timeIndexedLongDictation`. Apple describes `progressive*` presets as providing volatile/progressive delivery and `timeIndexedLongDictation` as providing audio time ranges. There is no documented standard preset combining every desired option; the designated option initializer can express that combination. The last sentence is an API-shape inference from Apple’s preset table and initializer, not a product recommendation. [DictationTranscriber.Preset](https://developer.apple.com/documentation/speech/dictationtranscriber/preset)

Apple describes this module as using the same speech-to-text models as system dictation or an on-device `SFSpeechRecognizer`, and explicitly says it does not support locales that legacy recognition supports only through the network. [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)

### Locale and asset readiness

`DictationTranscriber` conforms to `LocaleDependentSpeechModule`, which supplies:

- `supportedLocales`: locales supported by the module, including locales whose assets may be downloadable;
- `installedLocales`: locales whose assets are currently installed;
- `supportedLocale(equivalentTo:)`: the supported locale matching a requested locale;
- `selectedLocales`: the locale selected by the instance.

The documented readiness sequence is:

```swift
guard let locale = await DictationTranscriber.supportedLocale(
    equivalentTo: requestedLocale
) else {
    // Unsupported locale.
    throw SpeechError.unsupportedLocale
}

let transcriber = DictationTranscriber(
    locale: locale,
    contentHints: [],
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: [.audioTimeRange]
)

let status = await AssetInventory.status(forModules: [transcriber])
if status != .installed {
    if let request = try await AssetInventory.assetInstallationRequest(
        supporting: [transcriber]
    ) {
        try await request.downloadAndInstall()
    }
}
```

The `Speech` APIs use `AssetInventory.Status.unsupported`, `.supported`, `.downloading`, and `.installed`. `assetInstallationRequest(supporting:)` returns `nil` when the required assets are already installed; otherwise it returns a request whose `downloadAndInstall()` completes the installation. Asset locale reservations can be made explicitly with `AssetInventory.reserve(locale:)`; Apple says the call throws if no supporting asset exists or the app would exceed the device-dependent reservation limit. [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory), [AssetInventory.Status](https://developer.apple.com/documentation/speech/assetinventory/status), [`status(forModules:)`](https://developer.apple.com/documentation/speech/assetinventory/status%28formodules%3A%29), [`assetInstallationRequest(supporting:)`](https://developer.apple.com/documentation/speech/assetinventory/assetinstallationrequest%28supporting%3A%29), [`reserve(locale:)`](https://developer.apple.com/documentation/speech/assetinventory/reserve%28locale%3A%29)

After installation, `DictationTranscriber.availableCompatibleAudioFormats` reports the formats the configured module can analyze. Apple documents that this list is empty when required assets are not installed. `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` returns `nil` when additional assets are needed and otherwise returns the best-quality format from installed assets. [SpeechModule.availableCompatibleAudioFormats](https://developer.apple.com/documentation/speech/speechmodule/availablecompatibleaudioformats), [`bestAvailableAudioFormat(compatibleWith:)`](https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat%28compatiblewith%3A%29)

There is no `DictationTranscriber.isAvailable` in the local SDK declaration or in Apple’s current DictationTranscriber symbol list. Therefore, a Boolean availability check copied from `SpeechTranscriber` is not a documented substitute for the Dictation asset/locale checks. `SpeechAnalyzer.prepareToAnalyze(in:)` can additionally preheat the analyzer and throws if preparation cannot be completed. [SpeechAnalyzer `prepareToAnalyze(in:)`](https://developer.apple.com/documentation/speech/speechanalyzer/preparetoanalyze%28in%3A%29)

## New API: file-to-buffer and `AVAudioBuffer` bridges

### File import produces PCM buffers

Apple’s `AVAudioFile` contract is that, regardless of the on-disk format, reads and writes use `AVAudioPCMBuffer` objects in the file’s processing format. Reads are sequential, and the API supports reading an entire buffer or a requested frame count. [AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile)

That gives the local-SDK file-to-buffer shape:

```swift
let file = try AVAudioFile(forReading: url)
let processingFormat = file.processingFormat

while file.framePosition < file.length {
    let remaining = file.length - file.framePosition
    let count = AVAudioFrameCount(min(remaining, 4096))
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: processingFormat,
        frameCapacity: count
    ) else { throw SpeechError.cannotAllocateBuffer }

    try file.read(into: buffer, frameCount: count)
    // Convert to analyzerFormat, then yield AnalyzerInput.
}
```

The sample is illustrative only. The final read may contain fewer frames than its capacity, so consumers must use `frameLength`, not `frameCapacity`. The sample does not make a product choice about chunk size.

### Local Xcode 26.4 bridge: explicit PCM conversion

In the local SDK, `AnalyzerInput` accepts only `AVAudioPCMBuffer`:

```swift
let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
    compatibleWith: [transcriber]
)
guard let analyzerFormat else { throw SpeechError.noModelOrFormat }

let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.start(inputSequence: inputSequence)

for buffer in fileBuffers {
    let converted: AVAudioPCMBuffer = try convert(
        buffer,
        to: analyzerFormat
    ) // AVAudioConverter or an equivalent app-owned PCM converter.

    inputBuilder.yield(AnalyzerInput(buffer: converted))
}

inputBuilder.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

Apple’s WWDC25 first-party material shows the same conceptual sequence: obtain `bestAvailableAudioFormat`, convert each `AVAudioPCMBuffer` to that format, create `AnalyzerInput(buffer:)`, yield it into an `AsyncStream`, and call `finalizeAndFinishThroughEndOfInput()` when recording stops. The sample uses an app-level buffer converter; it does not establish a public `AnalyzerInputConverter` symbol in Xcode 26.4. [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/), [Apple sample code page](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app)

`SpeechAnalyzer` does not transparently upsample, downsample, or otherwise convert input because its time-code model is sample-accurate. The conversion must therefore happen before `AnalyzerInput` is yielded. [bestAvailableAudioFormat](https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat%28compatiblewith%3A%29)

### Online beta bridge: `AnalyzerInputConverter`

Apple’s current online documentation adds this bridge:

```swift
let converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)

for buffer: AVAudioBuffer in incomingBuffers {
    let inputs = try converter.convert(buffer, at: audioTime)
    for input in inputs {
        inputBuilder.yield(input)
    }
}

for input in try converter.flush() {
    inputBuilder.yield(input)
}
inputBuilder.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

Apple documents these important semantics:

- `convert` accepts `AVAudioBuffer` and may return zero, one, or multiple `AnalyzerInput` values.
- Conversion may hold audio for correctness or efficiency, so `convert` need not consume the entire input buffer.
- `flush()` must be called to emit pending converted audio before the sequence is finished.
- The input buffer must not be reused or modified because the converter may retain it across calls.
- `audioTime` is optional; `nil` means immediately after the previous buffer (or time zero for the first buffer).

The converter page and the file/capture provider pages are marked beta. They are not present in this checkout’s Xcode 26.4 iOS/macOS Swift interfaces, so this path cannot be treated as locally compilable without changing the SDK/toolchain. [AnalyzerInputConverter](https://developer.apple.com/documentation/speech/analyzerinputconverter), [`convert(_:at:)`](https://developer.apple.com/documentation/speech/analyzerinputconverter/convert%28_%3Aat%3A%29), [`flush()`](https://developer.apple.com/documentation/speech/analyzerinputconverter/flush%28%29)

### Time-code and conversion ownership

`AnalyzerInput(buffer:)` assumes the buffer follows the previous input (or starts at time zero). `AnalyzerInput(buffer:bufferStartTime:)` is for a possibly discontiguous stream. Apple requires input not to overlap or precede previous input and warns that conversion priming can shift audio into a later converted buffer; in that case, the original buffer’s start time is not valid for the converted buffer. The `AVAudioTime` to `CMTime` conversion shown by Apple is:

```swift
CMTime(
    value: audioTime.sampleTime,
    timescale: CMTimeScale(audioTime.sampleRate)
)
```

[AnalyzerInput initializer](https://developer.apple.com/documentation/speech/analyzerinput/init%28buffer%3Abufferstarttime%3A%29)

The online `AnalyzerInput.buffer` documentation describes the exposed PCM buffer as a new copy of the audio data, while the local Swift interface marks `AnalyzerInput` as `@unchecked Sendable`. The public sources do not provide a stronger general mutation/ownership guarantee for the local initializer. **Inference:** once an input is constructed and yielded, treat its PCM memory as immutable and do not recycle the source buffer until the conversion/input step has completed; use copies if a capture/file reader reuses storage. [AnalyzerInput.buffer](https://developer.apple.com/documentation/speech/analyzerinput/buffer), [Swift `Sendable`](https://developer.apple.com/documentation/swift/sendable)

## New API: direct file-fed behavior

`SpeechAnalyzer` has direct `AVAudioFile` APIs in the local SDK:

- `analyzeSequence(from:)` reads the file and returns the last consumed `CMTime?`.
- `start(inputAudioFile:finishAfterFile:)` starts autonomous analysis.
- The async initializer taking `inputAudioFile` starts analysis immediately.

Apple documents that these file methods automatically convert the file to a supported format and process it in its entirety. `finishAfterFile: true` terminates the analysis after that file. If it is false, the analyzer waits for additional input and the result streams do not terminate automatically. The WWDC25 file example reads results concurrently, calls `analyzeSequence(from:)`, then calls `finalizeAndFinish(through:)` using the returned last sample. [SpeechAnalyzer file APIs](https://developer.apple.com/documentation/speech/speechanalyzer)

This direct file path is distinct from the requested “file becomes buffer” path. **Documented fact:** Apple supports both. **Inference:** if the app’s `file` and `buffer` modes must share one streaming ingestion state machine, read the file into PCM chunks and use the buffer bridge; otherwise the direct `AVAudioFile` API avoids app-owned chunking and conversion.

The current online beta `AssetInputSequenceProvider` is another file/asset path: it reads the first track and exposes an `analyzerInputs` sequence. It is not in the local 26.4 Swift interface. [AssetInputSequenceProvider](https://developer.apple.com/documentation/speech/assetinputsequenceprovider)

## New API: result sequencing and timestamps

`DictationTranscriber.results` is a single asynchronous result sequence; Apple says accessing the property does not create a new sequence. Results are delivered in phrase order. Each `DictationTranscriber.Result` contains:

- `text: AttributedString`, the most likely interpretation;
- `alternatives`, if requested;
- `range: CMTimeRange`, the source-audio range covered;
- `resultsFinalizationTime: CMTime`, the time through which this module’s results have been finalized.

With `.volatileResults`, a phrase can be delivered repeatedly while its interpretation improves until finalization. `SpeechModuleResult.isFinal` is equivalent to `resultsFinalizationTime >= range.end`. If `isFinal` is false, the result may be replaced later, but Apple explicitly says there is no guarantee it will be reissued with `isFinal == true`; finalization may leave an unchanged volatile result un-reissued. [DictationTranscriber.Result](https://developer.apple.com/documentation/speech/dictationtranscriber/result), [`isFinal`](https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal), [`resultsFinalizationTime`](https://developer.apple.com/documentation/speech/speechmoduleresult/resultsfinalizationtime)

The safe transcript state model is therefore:

- retain finalized text/ranges as committed;
- replace volatile text for its audio range rather than append it;
- when a result is final, remove the volatile representation for that range and commit the final representation;
- use `range`/`resultsFinalizationTime` for ordering and deduplication rather than arrival time.

The first three bullets are an implementation inference from Apple’s documented volatile semantics; they are not a product decision.

For timing, include `.audioTimeRange` in `attributeOptions`. Apple then includes `SpeechAttributes.TimeRangeAttribute` values in the returned attributed string. `rangeOfAudioTimeRangeAttributes(intersecting:)` can map a playback `CMTimeRange` back to text. [audioTimeRange](https://developer.apple.com/documentation/speech/dictationtranscriber/resultattributeoption/audiotimerange), [AttributedString time-range lookup](https://developer.apple.com/documentation/speech/dictationtranscriber/result/rangeofaudiotimerangeattributes%28intersecting%3A%29)

## New API: end-of-input, finalization, cancellation, and errors

For an autonomous stream started with `start(inputSequence:)`:

1. Stop producing input and call `inputBuilder.finish()`.
2. Call `try await analyzer.finalizeAndFinishThroughEndOfInput()`.
3. Drain/await the transcriber result task and handle its thrown error.

Apple says this method waits for the input sequence to terminate and be fully consumed, finalizes module results, and finishes analysis. It throws `CancellationError` when analysis finished early. Merely finishing the input sequence generally does not finish the analysis session; the analyzer can otherwise continue with a different sequence. [finalizeAndFinishThroughEndOfInput](https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput%28%29)

Other controls:

- `finalize(through:)` waits for input through a time-code and publishes finalized results; it does not necessarily re-publish an unchanged result.
- `finalizeAndFinish(through:)` finalizes through a time-code and finishes.
- `finish(after:)` finishes after input through a time-code is consumed, but does not guarantee that the module has finalized that input; use the finalize variant when final output is required.
- `cancelAndFinishNow()` cancels pending work and finishes immediately. It can finish before any input and is the cancellation primitive for an active streaming session.

[finalize(through:)](https://developer.apple.com/documentation/speech/speechanalyzer/finalize%28through%3A%29), [finish(after:)](https://developer.apple.com/documentation/speech/speechanalyzer/finish%28after%3A%29), [cancelAndFinishNow](https://developer.apple.com/documentation/speech/speechanalyzer/cancelandfinishnow%28%29)

When the analyzer or a module result sequence throws, Apple says the analysis session becomes finished and the same error (or `CancellationError`) is thrown from waiting methods and result sequences. Relevant documented `SFSpeechError.Code` values include unsupported/unallocated locale, no model, incompatible or unexpected audio format, disordered audio time, audio-read failure, insufficient resources, module output failure, and internal service failure. [SpeechAnalyzer error handling](https://developer.apple.com/documentation/speech/speechanalyzer), [SFSpeechError.Code](https://developer.apple.com/documentation/speech/sfspeecherror/code)

## Old API: `SFSpeechAudioBufferRecognitionRequest`

### Availability and readiness

The legacy request and recognizer are available on iOS 10.0 and macOS 10.15. `SFSpeechRecognizer(locale:)` can return `nil` for an unsupported locale; successful construction does not guarantee current service availability, so check `isAvailable`. The app must request speech-recognition authorization. Some locales require a network connection; `supportsOnDeviceRecognition` reports whether on-device recognition is possible, and `requiresOnDeviceRecognition` requests that audio remain on-device only when support is true. [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer), [SFSpeechRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest), [`requiresOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)

### File-to-buffer ingestion and accepted format

`SFSpeechAudioBufferRecognitionRequest` is documented for live audio or a set of existing audio buffers. It exposes `nativeAudioFormat` as the preferred format, but Apple says not to depend on the value remaining unchanged. `append(_:)` accepts `AVAudioPCMBuffer`; Apple requires native, uncompressed PCM for this method. The alternate `appendAudioSampleBuffer(_:)` accepts `CMSampleBuffer` in a native format. It does not accept an arbitrary `AVAudioBuffer` parameter.

For a file-backed Old request, read the file sequentially into `AVAudioPCMBuffer` chunks, convert to the request’s current native format if necessary, append the chunks, and call `endAudio()` after the last chunk. The conversion recommendation is an inference from the documented native-format requirement and `nativeAudioFormat` hint; the public API does not provide an Old-request conversion helper. [SFSpeechAudioBufferRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest), [`append(AVAudioPCMBuffer)`](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest/append%28_%3A%29), [`endAudio()`](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest/endaudio%28%29), [AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter)

Apple’s public `append` documentation does not state whether the request copies the PCM data synchronously or retains the buffer. **Defensive inference:** do not mutate or recycle an appended buffer until the request’s ownership/retention behavior has been verified on target runtimes; use independent chunks or copies when the file reader reuses storage.

### Partial/final result sequencing

The request’s `shouldReportPartialResults` defaults to `true`. The recognizer’s result handler can be called repeatedly for partial and final results. `SFSpeechRecognitionResult.isFinal` means recognition is complete and the transcription will not change. The task handler/delegate queue defaults to the app’s main queue, but `SFSpeechRecognizer.queue` can be assigned to another `OperationQueue`.

For a streaming adapter, replace the displayed partial transcript with the newest result and commit only the `isFinal` result; do not append every callback. The replacement/commit rule is an implementation inference from the documented repeated-partial/final callback model. [SFSpeechRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest), [SFSpeechRecognitionResult.isFinal](https://developer.apple.com/documentation/speech/sfspeechrecognitionresult/isfinal), [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)

### End-of-input, finish, and cancellation

The request itself must receive `endAudio()` so the recognizer knows no more audio is coming. The resulting `SFSpeechRecognitionTask` also exposes:

- `finish()`: stop accepting new audio and finish processing audio already accepted; Apple specifically notes that buffer-based recognition does not finish until this method is called;
- `cancel()`: cancel prerecorded or live recognition;
- `state`, `finishing`, `cancelled`, and `error` for lifecycle inspection.

The exact adapter should follow the target runtime’s observed interaction between `request.endAudio()` and `task.finish()`; both are documented controls at different layers, and the headers do not say that one makes the other redundant. [SFSpeechRecognitionTask](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask), [`finish()`](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/finish%28%29), [`cancel()`](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/cancel%28%29)

### Errors

The result handler receives an error when recognition fails. The task’s documented error table includes missing assets, disabled Siri/Dictation, recognizer initialization failure, cancellation, recognition failure, an already-active recognition instance, speech-process invalidation/interruption, no recognized speech, and lack of authorization. [SFSpeechRecognitionTask.error](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error)

The legacy API also documents a one-minute planning limit for network-based recognition and warns that service availability can change. This limit and network behavior are properties of the legacy service documentation, not a claim about the New `DictationTranscriber` model. [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)

## Minimal side-by-side lifecycle

| Concern | New: `DictationTranscriber` + `SpeechAnalyzer` | Old: `SFSpeechAudioBufferRecognitionRequest` |
| --- | --- | --- |
| Deployment | iOS/macOS 26.0+ | iOS 10.0+/macOS 10.15+ |
| File import | Direct `AVAudioFile` analyzer API exists; buffer mode reads PCM chunks | Read file into PCM chunks and append; URL request is a separate legacy path |
| Input type | Local 26.4: `AnalyzerInput(AVAudioPCMBuffer)`; online beta: `AnalyzerInputConverter(AVAudioBuffer)` | `append(AVAudioPCMBuffer)` or `appendAudioSampleBuffer(CMSampleBuffer)` |
| Format | Explicitly convert to `bestAvailableAudioFormat`; preserve `CMTime` | Native, uncompressed PCM; `nativeAudioFormat` is a hint |
| Results | `AsyncSequence`; volatile/final ranges and optional per-text audio times | Repeated callback; partial/final `SFSpeechRecognitionResult` |
| End input | Finish input sequence, then finalize-and-finish analyzer | `request.endAudio()`; task-level `finish()` is separately documented |
| Cancel | `await analyzer.cancelAndFinishNow()` | `task.cancel()` |
| Readiness | Supported/installed locale and `AssetInventory` status/installation | Authorization, recognizer construction, `isAvailable`, optional on-device support |

## Blockers and non-findings

- **Toolchain blocker:** Apple’s current online documentation exposes the beta `AnalyzerInputConverter`/file-provider path, but the local Xcode 26.4.1 iOS/macOS 26.4 Swift interfaces do not. A production implementation must either use the local manual `AVAudioConverter` + `AnalyzerInput(AVAudioPCMBuffer)` path or be built/tested with an SDK that actually exports the beta converter. This report does not choose between them.
- **Ownership non-finding:** Apple documents retention for `AnalyzerInputConverter` input, but does not document a comparable copy/retention contract for `SFSpeechAudioBufferRecognitionRequest.append(AVAudioPCMBuffer)` or the local `AnalyzerInput` initializer. The report therefore records defensive immutability/copying as inference, not as an Apple guarantee.
- **Runtime non-finding:** The sources document lifecycle methods and error propagation but do not guarantee callback executor behavior for New result iteration, a particular number of result emissions, or a universal “final result is always reissued” event. Target-runtime probes remain necessary for those observations.

