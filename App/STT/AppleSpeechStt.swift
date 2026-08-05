import AVFoundation
import Foundation
import Speech

enum AppleSpeechSttError: LocalizedError {
    case unavailable
    case localeNotSupported(String)
    case localeChangedRequiresReload
    case modelInstallationFailed(String)
    case noCompatibleAudioFormat
    case noActiveTurn
    case invalidAudio
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple SpeechTranscriber is unavailable on this OS or device. Select Parakeet in Settings."
        case .localeNotSupported(let locale):
            "Apple SpeechTranscriber does not support the locale \(locale) on this device."
        case .localeChangedRequiresReload:
            "The Apple Speech locale changed. Reload models before starting another turn."
        case .modelInstallationFailed(let message):
            "Apple Speech model installation failed: \(message)"
        case .noCompatibleAudioFormat:
            "Apple SpeechTranscriber has no compatible audio format for this device."
        case .noActiveTurn:
            "Apple SpeechTranscriber has no active turn."
        case .invalidAudio:
            "The audio buffer could not be converted for Apple SpeechTranscriber."
        case .recognitionFailed(let message):
            "Apple SpeechTranscriber failed: \(message)"
        }
    }
}

/// Apple SpeechTranscriber backend. The actor owns one analyzer session at a
/// time and exposes transcript snapshots because volatile Speech results can
/// revise text already emitted by an earlier result.
@available(macOS 26.0, iOS 26.0, *)
actor AppleSpeechStt: SttEngine {
    private let locale: Locale
    private let analyzerFormat: AVAudioFormat
    private let converter = AnalyzerInputConverter()

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var recognitionError: String?
    private var finalizedText = ""
    private var volatileText = ""
    private var timestampedWords: [TranscriptWord] = []

    /// Asset installation and audio-format selection happen before the engine
    /// is returned, so a loaded Apple backend is ready for beginTurn.
    static func make(localeIdentifier: String?) async throws -> AppleSpeechStt {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechSttError.unavailable
        }

        let requested = AppleSpeechLocaleResolver.requestedLocale(for: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AppleSpeechSttError.localeNotSupported(requested.identifier(.bcp47))
        }

        let setupTranscriber = makeTranscriber(locale: locale)
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains {
            AppleSpeechLocaleResolver.isEquivalent($0, to: locale)
        }

        if !isInstalled {
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [setupTranscriber]) else {
                    let installedAfterRequest = await SpeechTranscriber.installedLocales
                    guard installedAfterRequest.contains(where: {
                        AppleSpeechLocaleResolver.isEquivalent($0, to: locale)
                    }) else {
                        throw AppleSpeechSttError.modelInstallationFailed("no installation request was available")
                    }
                    return try await makeReady(locale: locale, transcriber: setupTranscriber)
                }
                try await request.downloadAndInstall()
            } catch let error as AppleSpeechSttError {
                throw error
            } catch {
                throw AppleSpeechSttError.modelInstallationFailed(error.localizedDescription)
            }
        }

        return try await makeReady(locale: locale, transcriber: setupTranscriber)
    }

    private static func makeReady(locale: Locale, transcriber: SpeechTranscriber) async throws -> AppleSpeechStt {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechSttError.noCompatibleAudioFormat
        }
        return AppleSpeechStt(locale: locale, analyzerFormat: format)
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    private init(locale: Locale, analyzerFormat: AVAudioFormat) {
        self.locale = locale
        self.analyzerFormat = analyzerFormat
    }

    var canEndTurnWithoutTranscript: Bool { true }

    func beginTurn(lang: String?) async throws {
        await cancelActiveTurn()

        if let lang, !lang.isEmpty, lang.lowercased() != "auto" {
            let requested = AppleSpeechLocaleResolver.requestedLocale(for: lang)
            guard AppleSpeechLocaleResolver.isEquivalent(requested, to: locale) else {
                throw AppleSpeechSttError.localeChangedRequiresReload
            }
        }

        let newTranscriber = Self.makeTranscriber(locale: locale)
        let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber])
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        finalizedText = ""
        volatileText = ""
        timestampedWords = []
        recognitionError = nil
        transcriber = newTranscriber
        analyzer = newAnalyzer
        self.inputBuilder = inputBuilder

        resultTask = Task { [weak self, newTranscriber] in
            do {
                for try await result in newTranscriber.results {
                    await self?.consume(result)
                }
            } catch is CancellationError {
                // Cancellation is the normal path when a turn is replaced.
            } catch {
                await self?.recordRecognitionError(error)
            }
        }

        do {
            try await newAnalyzer.start(inputSequence: inputSequence)
        } catch {
            await cancelActiveTurn()
            throw error
        }
    }

    func feed(_ pcm: [Float]) throws -> SttFeedResult {
        guard inputBuilder != nil else { throw AppleSpeechSttError.noActiveTurn }
        guard !pcm.isEmpty else {
            return SttFeedResult(textUpdate: .replace(currentTranscript), eou: false, eob: false)
        }

        let source = try makeSourceBuffer(samples: pcm)
        let converted = try converter.convertBuffer(source, to: analyzerFormat)
        inputBuilder?.yield(AnalyzerInput(buffer: converted))
        return SttFeedResult(textUpdate: .replace(currentTranscript), eou: false, eob: false)
    }

    func endTurn() async throws -> SttTextUpdate {
        guard let activeAnalyzer = analyzer else {
            return .replace(currentTranscript)
        }

        inputBuilder?.finish()
        inputBuilder = nil

        do {
            try await activeAnalyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await cancelActiveTurn()
            throw error
        }

        if let resultTask {
            await resultTask.value
        }

        let finalText = finalizedText + volatileText
        let recognitionError = self.recognitionError
        clearTurnReferences()
        guard let recognitionError else {
            return .replace(finalText)
        }
        throw AppleSpeechSttError.recognitionFailed(recognitionError)
    }

    func transcribeFileWords(pcm: [Float], lang: String?) async throws -> SttTimestampedResult {
        guard !pcm.isEmpty else {
            return SttTimestampedResult(words: [], frameSec: 0)
        }

        try await beginTurn(lang: lang)
        let chunkSize = 1_600
        var offset = 0
        while offset < pcm.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, pcm.count)
            _ = try feed(Array(pcm[offset..<end]))
            offset = end
        }
        _ = try await endTurn()
        return SttTimestampedResult(words: timestampedWords, frameSec: 0)
    }

    private var currentTranscript: String { finalizedText + volatileText }

    private func consume(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            finalizedText += text
            volatileText = ""
            timestampedWords.append(contentsOf: words(from: result.text))
        } else {
            volatileText = text
        }
    }

    private func words(from attributed: AttributedString) -> [TranscriptWord] {
        attributed.runs.compactMap { run in
            guard let timeRange = run.audioTimeRange else { return nil }
            let text = String(attributed[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let start = timeRange.start.seconds
            let end = timeRange.end.seconds
            guard !text.isEmpty, start.isFinite, end.isFinite, end >= start else { return nil }
            return TranscriptWord(text: text,
                                  start: start,
                                  end: end,
                                  confidence: run.transcriptionConfidence ?? 1.0)
        }
    }

    private func makeSourceBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = Self.sourceFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0] else {
            throw AppleSpeechSttError.invalidAudio
        }
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    private static let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 16_000,
                                                    channels: 1,
                                                    interleaved: false)!

    private func recordRecognitionError(_ error: Error) {
        recognitionError = error.localizedDescription
    }

    private func cancelActiveTurn() async {
        inputBuilder?.finish()
        inputBuilder = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        resultTask?.cancel()
        if let resultTask {
            await resultTask.value
        }
        clearTurnReferences()
    }

    private func clearTurnReferences() {
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        resultTask = nil
        finalizedText = ""
        volatileText = ""
        recognitionError = nil
    }
}

/// Converts the app's fixed 16 kHz mono buffers into the format selected by
/// SpeechAnalyzer. Keeping this conversion inside the Apple actor avoids
/// sharing AVAudioConverter across audio and recognition tasks.
private final class AnalyzerInputConverter {
    enum Error: Swift.Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw Error.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                               frameCapacity: max(1, capacity)) else {
            throw Error.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: converted, error: &nsError) { _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw Error.conversionFailed(nsError) }
        return converted
    }
}
