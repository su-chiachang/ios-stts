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

/// File-only adapter for the legacy SFSpeechURLRecognitionRequest API.
///
/// This is intentionally kept beside SttAppleNew so the two Apple file
/// transcription implementations can be compared without changing the UI's
/// result type.
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

    func transcribeFile(_ url: URL) async throws -> SttFileTranscription {
        try Task.checkCancellation()

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await recognize(request)
    }

    private func recognize(_ request: SFSpeechURLRecognitionRequest) async throws -> SttFileTranscription {
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
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Synchronizes the callback-based recognition task with async cancellation
/// and prevents a late callback from resuming a continuation twice.
private final class LegacyRecognitionTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SttFileTranscription, Error>?
    private var task: SFSpeechRecognitionTask?
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

    func complete(with result: Result<SttFileTranscription, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        task = nil
        lock.unlock()

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
        lock.unlock()

        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}
