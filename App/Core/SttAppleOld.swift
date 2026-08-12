import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Converts the segment timings exposed by the legacy Speech framework into
/// the same word result shape used by the SpeechAnalyzer adapter.
private enum SttAppleOldWords {
    static func words(from result: SFSpeechRecognitionResult) -> SttFileTranscription {
        let transcription = result.bestTranscription
        let words = transcription.segments.compactMap { segment -> SttWordTimestamp? in
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = segment.timestamp
            let end = start + segment.duration

            guard !text.isEmpty,
                  start.isFinite,
                  end.isFinite,
                  end >= start else {
                return nil
            }

            return SttWordTimestamp(text: text, start: start, end: end)
        }

        return SttFileTranscription(
            text: transcription.formattedString,
            words: words)
    }
}

/// Legacy adapter. File mode uses SFSpeechURLRecognitionRequest; buffer mode
/// decodes the imported file into native PCM CMSampleBuffers and appends them
/// to SFSpeechAudioBufferRecognitionRequest.
@available(macOS 10.15, iOS 10.0, *)
actor SttAppleOld {
    private let recognizer: SFSpeechRecognizer

    static func make(localeIdentifier: String) async throws -> SttAppleOld {
        let requested = SttAppleLocaleResolver.requestedLocale(for: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: requested) else {
            throw SttAppleError.localeNotSupported(requested.identifier(.bcp47))
        }

        let authorization = await authorizationStatus()
        guard authorization == .authorized else {
            throw SttAppleError.authorizationDenied
        }

        guard recognizer.isAvailable else {
            throw SttAppleError.recognizerUnavailable
        }

        return SttAppleOld(recognizer: recognizer)
    }

    private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    func transcribeFile(
        _ url: URL,
        inputType: SttInputType = .file
    ) async throws -> SttFileTranscription {
        try Task.checkCancellation()

        switch inputType {
        case .file:
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            return try await recognize(request)
        case .live:
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = false
            return try await recognize(request) {
                try await self.appendAudioSampleBuffers(from: url, to: request)
            }
        }
    }

    private func appendAudioSampleBuffers(
        from url: URL,
        to request: SFSpeechAudioBufferRecognitionRequest
    ) async throws {
        try await LegacyAudioSampleBufferReader.forEachSampleBuffer(
            from: url,
            nativeFormat: request.nativeAudioFormat
        ) { sampleBuffer in
            request.appendAudioSampleBuffer(sampleBuffer)
        }
    }

    private func recognize(
        _ request: SFSpeechRecognitionRequest,
        feedAudio: (() async throws -> Void)? = nil
    ) async throws -> SttFileTranscription {
        let state = LegacyRecognitionTaskState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)

                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        state.complete(with: .failure(error))
                    } else if let result, result.isFinal {
                        state.complete(with: .success(SttAppleOldWords.words(from: result)))
                    }
                }

                state.setTask(task)

                if let feedAudio {
                    let feedTask = Task<Void, Never> {
                        do {
                            try await feedAudio()
                            try Task.checkCancellation()
                            guard let audioRequest = request as? SFSpeechAudioBufferRecognitionRequest else {
                                return
                            }
                            audioRequest.endAudio()
                            task.finish()
                        } catch {
                            task.cancel()
                            state.complete(with: .failure(error))
                        }
                    }
                    state.setFeedTask(feedTask)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

enum LegacyAudioSampleBufferReader {
    static func forEachSampleBuffer(
        from url: URL,
        nativeFormat: AVAudioFormat,
        body: (CMSampleBuffer) throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LegacyAudioBufferError.missingAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: nativeFormat.sampleRate,
            AVNumberOfChannelsKey: Int(nativeFormat.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LegacyAudioBufferError.cannotAddReaderOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw LegacyAudioBufferError.readerFailed(reader.error)
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try body(sampleBuffer)
        }

        switch reader.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw LegacyAudioBufferError.readerFailed(reader.error)
        default:
            throw LegacyAudioBufferError.readerEndedUnexpectedly
        }
    }
}

enum LegacyAudioBufferError: LocalizedError {
    case missingAudioTrack
    case cannotAddReaderOutput
    case readerFailed(Error?)
    case readerEndedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack:
            "The imported file has no audio track."
        case .cannotAddReaderOutput:
            "The imported audio cannot be decoded into speech buffers."
        case .readerFailed(let error):
            "Reading imported audio failed: \(error?.localizedDescription ?? "unknown error")"
        case .readerEndedUnexpectedly:
            "Reading imported audio ended unexpectedly."
        }
    }
}

/// Synchronizes the callback-based recognition task with async cancellation
/// and prevents a late callback from resuming a continuation twice.
private final class LegacyRecognitionTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SttFileTranscription, Error>?
    private var task: SFSpeechRecognitionTask?
    private var feedTask: Task<Void, Never>?
    private var finished = false

    func setContinuation(_ continuation: CheckedContinuation<SttFileTranscription, Error>) {
        lock.lock()
        let shouldCancel = finished
        if !shouldCancel {
            self.continuation = continuation
        }
        lock.unlock()

        if shouldCancel {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let shouldCancel = finished
        if !shouldCancel {
            self.task = task
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func setFeedTask(_ feedTask: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = finished
        if !shouldCancel {
            self.feedTask = feedTask
        }
        lock.unlock()

        if shouldCancel {
            feedTask.cancel()
        }
    }

    func complete(with result: Result<SttFileTranscription, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let feedTask = self.feedTask
        self.feedTask = nil
        task = nil
        lock.unlock()

        feedTask?.cancel()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        let feedTask = self.feedTask
        self.feedTask = nil
        lock.unlock()

        feedTask?.cancel()
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}
