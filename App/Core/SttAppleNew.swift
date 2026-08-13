import AVFoundation
import CoreMedia
import Foundation
import Speech

struct SttWordTimestamp: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct SttFileTranscription: Equatable, Sendable {
    let text: String
    let words: [SttWordTimestamp]
}

typealias SttTranscriptionUpdate = @MainActor @Sendable (SttFileTranscription) -> Void

enum SttAppleVersion: String, CaseIterable, Identifiable {
    case new
    case old

    static let key = "sttAppleVersion"
    static let defaultValue: Self = .new

    var id: String { rawValue }

    static func resolve(rawValue: String?) -> Self {
        guard let rawValue, let value = Self(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }
}

enum SttInputType: String, CaseIterable, Identifiable {
    case file
    case live

    static let key = "sttInputType"
    static let defaultValue: Self = .file

    var id: String { rawValue }

    static func resolve(rawValue: String?) -> Self {
        guard let rawValue, let value = Self(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }
}

enum SttAppleNewWords {
    static func words(from transcription: AttributedString) -> [SttWordTimestamp] {
        transcription.runs.compactMap { run in
            let text = String(transcription[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let timeRange: CMTimeRange? = run[
                AttributeScopes.SpeechAttributes.TimeRangeAttribute.self
            ]
            guard let timeRange, timeRange.isValid else { return nil }

            let start = timeRange.start.seconds
            let end = timeRange.end.seconds
            guard start.isFinite, end.isFinite, end >= start else { return nil }

            return SttWordTimestamp(text: text, start: start, end: end)
        }
    }
}

enum SttLocalePreferences {
    static let key = "sttLocale"
    static let defaultIdentifier = Locale.current.identifier(.bcp47)

    static var identifier: String {
        UserDefaults.standard.string(forKey: key) ?? defaultIdentifier
    }

    static func save(_ identifier: String) {
        UserDefaults.standard.set(SttAppleLocaleResolver.tag(for: identifier), forKey: key)
    }
}

/// Maps a persisted locale identifier to one concrete locale for Apple's
/// locale-dependent speech APIs.
enum SttAppleLocaleResolver {
    static func requestedLocale(for identifier: String, current: Locale = .current) -> Locale {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return current }

        switch value.lowercased() {
        case "en": return Locale(identifier: "en-US")
        case "zh", "zh-cn", "zh-hans": return Locale(identifier: "zh-CN")
        case "zh-tw", "zh-hant": return Locale(identifier: "zh-TW")
        default: return Locale(identifier: value)
        }
    }

    static func isEquivalent(_ lhs: Locale, to rhs: Locale) -> Bool {
        lhs.identifier(.bcp47).caseInsensitiveCompare(rhs.identifier(.bcp47)) == .orderedSame
    }

    /// The identifier form used for persistence and picker tags. Older values
    /// such as "en" are canonicalized so they still select a visible row.
    static func tag(for identifier: String) -> String {
        tag(for: requestedLocale(for: identifier))
    }

    static func tag(for locale: Locale) -> String {
        locale.identifier(.bcp47)
    }

    static func supportedLocales(for version: SttAppleVersion) async -> [Locale] {
        switch version {
        case .new:
            return sortedForDisplay(await DictationTranscriber.supportedLocales)
        case .old:
            return sortedForDisplay(Array(SFSpeechRecognizer.supportedLocales()))
        }
    }

    static func sortedForDisplay(_ locales: [Locale]) -> [Locale] {
        var seen = Set<String>()
        let unique = locales.filter { seen.insert(tag(for: $0).lowercased()).inserted }
        return unique.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    static func displayName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? tag(for: locale)
    }
}

enum SttAppleError: LocalizedError {
    case localeNotSupported(String)
    case modelInstallationFailed(String)
    case noCompatibleAudioFormat
    case authorizationDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let locale):
            "Apple Speech does not support the locale \(locale) on this device."
        case .modelInstallationFailed(let message):
            "Apple Speech model installation failed: \(message)"
        case .noCompatibleAudioFormat:
            "Apple DictationTranscriber has no compatible audio format for this device."
        case .authorizationDenied:
            "Apple Speech recognition permission was not granted."
        case .recognizerUnavailable:
            "Apple Speech recognition is currently unavailable."
        case .onDeviceRecognitionUnavailable(let locale):
            "Apple on-device speech recognition is unavailable for locale \(locale) on this device."
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
enum SttAppleAdapter {
    case new(SttAppleNew)
    case old(SttAppleOld)

    static func make(
        version: SttAppleVersion,
        localeIdentifier: String
    ) async throws -> Self {
        switch version {
        case .new:
            return .new(try await SttAppleNew.make(localeIdentifier: localeIdentifier))
        case .old:
            return .old(try await SttAppleOld.make(localeIdentifier: localeIdentifier))
        }
    }

    func transcribeFile(
        _ url: URL,
        inputType: SttInputType = .file,
        onUpdate: SttTranscriptionUpdate? = nil
    ) async throws -> SttFileTranscription {
        let ts = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - ts).formatted()
            print(">>> T(\(self)-\(inputType)) = \(elapsed)")
        }

        switch self {
        case .new(let stt):
            return try await stt.transcribeFile(url, inputType: inputType)
        case .old(let stt):
            return try await stt.transcribeFile(
                url,
                inputType: inputType,
                onUpdate: onUpdate)
        }
    }
}

/// Complete-file DictationTranscriber adapter. File mode lets SpeechAnalyzer
/// read the file; buffer mode decodes it into AVAudioPCMBuffer chunks first.
@available(macOS 26.0, iOS 26.0, *)
actor SttAppleNew {
    private let locale: Locale
    private let analyzerFormat: AVAudioFormat

    /// Asset installation and audio-format selection happen before the engine
    /// is returned, so file transcription starts with a ready model.
    static func make(localeIdentifier: String) async throws -> SttAppleNew {
        guard SpeechTranscriber.isAvailable else {
            throw SttAppleError.recognizerUnavailable
        }

        let requested = SttAppleLocaleResolver.requestedLocale(for: localeIdentifier)
        guard
            let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested),
            await SpeechTranscriber.supportedLocale(equivalentTo: requested) != nil
        else {
            throw SttAppleError.localeNotSupported(requested.identifier(.bcp47))
        }

        // Both module kinds are prepared here because the input mode is chosen
        // per transcription call, not when the actor is constructed.
        let transcribers = SttInputType.allCases.map { makeTranscriber(locale: locale, inputType: $0) }
        let isInstalled = await isLocaleInstalled(locale)

        if !isInstalled {
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: transcribers) else {
                    guard await isLocaleInstalled(locale) else {
                        throw SttAppleError.modelInstallationFailed("no installation request was available")
                    }
                    return try await makeReady(locale: locale, transcribers: transcribers)
                }
                try await request.downloadAndInstall()
            } catch let error as SttAppleError {
                throw error
            } catch {
                throw SttAppleError.modelInstallationFailed(error.localizedDescription)
            }
        }

        return try await makeReady(locale: locale, transcribers: transcribers)
    }

    private static func isLocaleInstalled(_ locale: Locale) async -> Bool {
        async let dictationInstalled = DictationTranscriber.installedLocales
        async let speechInstalled = SpeechTranscriber.installedLocales
        let (dictation, speech) = await (dictationInstalled, speechInstalled)
        return dictation.contains(where: { SttAppleLocaleResolver.isEquivalent($0, to: locale) })
            && speech.contains(where: { SttAppleLocaleResolver.isEquivalent($0, to: locale) })
    }

    /// SpeechAnalyzer requires modules to reserve their locale first.
    private static func reserve(locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { SttAppleLocaleResolver.isEquivalent($0, to: locale) }) {
            return
        }

        for stale in reserved.dropFirst(max(0, AssetInventory.maximumReservedLocales - 1)) {
            await AssetInventory.release(reservedLocale: stale)
        }

        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            throw SttAppleError.modelInstallationFailed(error.localizedDescription)
        }
    }

    private static func makeReady(
        locale: Locale,
        transcribers: [any SpeechModule]
    ) async throws -> SttAppleNew {
        try await reserve(locale: locale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: transcribers
        ) else {
            throw SttAppleError.noCompatibleAudioFormat
        }
        return SttAppleNew(locale: locale, analyzerFormat: analyzerFormat)
    }

    private static func makeTranscriber(locale: Locale, inputType: SttInputType) -> any SpeechModule {
        switch inputType {
        case .file:
            SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        case .live:
            DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        }
    }

    private init(locale: Locale, analyzerFormat: AVAudioFormat) {
        self.locale = locale
        self.analyzerFormat = analyzerFormat
    }

    func transcribeFile(
        _ url: URL,
        inputType: SttInputType = .file
    ) async throws -> SttFileTranscription {
        let audioFile = try AVAudioFile(forReading: url)
        switch inputType {
        case .file:
            return try await transcribeAudioFile(audioFile)
        case .live:
            return try await transcribeAudioBuffers(audioFile)
        }
    }

    private func transcribeAudioFile(_ audioFile: AVAudioFile) async throws -> SttFileTranscription {
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let detector = SpeechDetector()
        let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
        let transcriptionTask = Self.collectResults(from: transcriber)

        do {
            guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                await analyzer.cancelAndFinishNow()
                transcriptionTask.cancel()
                _ = await transcriptionTask.result
                return SttFileTranscription(text: "", words: [])
            }

            try await analyzer.finalizeAndFinish(through: lastSample)
            return try await transcriptionTask.value
        } catch {
            transcriptionTask.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await transcriptionTask.result
            throw error
        }
    }

    private static let bufferFrameCount: AVAudioFrameCount = 4_096
    private func transcribeAudioBuffers(_ audioFile: AVAudioFile) async throws -> SttFileTranscription {
        let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        let detector = SpeechDetector()
        let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
        let transcriptionTask = Self.collectResults(from: transcriber)
        let reader = AnalyzerInputFileReader(
            audioFile: audioFile,
            analyzerFormat: analyzerFormat,
            frameCount: Self.bufferFrameCount)
        let inputSequence = AsyncThrowingStream<AnalyzerInput, Error> {
            try await reader.next()
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await transcriptionTask.value
        } catch {
            transcriptionTask.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await transcriptionTask.result
            throw error
        }
    }

    private static func collectResults(
        from transcriber: SpeechTranscriber
    ) -> Task<SttFileTranscription, Error> {
        Task {
            var transcription = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                transcription += result.text
            }

            return SttFileTranscription(
                text: String(transcription.characters),
                words: SttAppleNewWords.words(from: transcription))
        }
    }

    private static func collectResults(
        from transcriber: DictationTranscriber
    ) -> Task<SttFileTranscription, Error> {
        Task {
            var transcription = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                transcription += result.text
            }

            return SttFileTranscription(
                text: String(transcription.characters),
                words: SttAppleNewWords.words(from: transcription))
        }
    }
}

/// A single-consumer, pull-based file sequence. SpeechAnalyzer requests the
/// next buffer only after consuming the previous one, which keeps memory
/// bounded for long recordings.
@available(macOS 26.0, iOS 26.0, *)
actor AnalyzerInputFileReader {
    private let audioFile: AVAudioFile
    private let analyzerFormat: AVAudioFormat
    private let frameCount: AVAudioFrameCount
    private let converter = AnalyzerInputConverter()
    private var reachedEndOfFile = false

    init(
        audioFile: AVAudioFile,
        analyzerFormat: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) {
        self.audioFile = audioFile
        self.analyzerFormat = analyzerFormat
        self.frameCount = frameCount
    }

    func next() throws -> AnalyzerInput? {
        try Task.checkCancellation()

        if !reachedEndOfFile, audioFile.framePosition < audioFile.length {
            let remaining = audioFile.length - audioFile.framePosition
            let count = AVAudioFrameCount(min(Int64(frameCount), remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: count
            ) else {
                throw AnalyzerInputConverter.Error.failedToCreateConversionBuffer
            }

            try audioFile.read(into: buffer, frameCount: count)
            if buffer.frameLength > 0 {
                let converted = try converter.convertBuffer(buffer, to: analyzerFormat)
                return AnalyzerInput(buffer: converted)
            }
        }

        reachedEndOfFile = true
        guard let trailingBuffer = try converter.finish() else { return nil }
        return AnalyzerInput(buffer: trailingBuffer)
    }
}

/// SpeechAnalyzer selects its own PCM format. Imported-file buffers are
/// converted as they are read so the full decoded file is never retained.
@available(macOS 26.0, iOS 26.0, *)
final class AnalyzerInputConverter {
    enum Error: LocalizedError {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)

        var errorDescription: String? {
            switch self {
            case .failedToCreateConverter:
                "Apple Speech could not create an audio converter."
            case .failedToCreateConversionBuffer:
                "Apple Speech could not allocate an audio buffer."
            case .conversionFailed(let error):
                "Apple Speech audio conversion failed: \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }

    private var converter: AVAudioConverter?
    private var finished = false

    func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard !finished else { throw Error.conversionFailed(nil) }
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw Error.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: max(1, capacity)
        ) else {
            throw Error.failedToCreateConversionBuffer
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw Error.conversionFailed(conversionError) }
        return converted
    }

    /// Signals EOF and drains frames retained by sample-rate conversion.
    func finish() throws -> AVAudioPCMBuffer? {
        guard let converter, !finished else { return nil }
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: 4_096
        ) else {
            throw Error.failedToCreateConversionBuffer
        }

        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
            outputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error else { throw Error.conversionFailed(conversionError) }

        if status == .endOfStream || converted.frameLength == 0 {
            finished = true
        }
        return converted.frameLength > 0 ? converted : nil
    }
}
