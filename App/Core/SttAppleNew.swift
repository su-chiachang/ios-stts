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

enum SttAppleVersion: String, CaseIterable, Identifiable {
    case new
    case old

    static let key = "sttAppleVersion"
    static let defaultValue: Self = .new

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: "New"
        case .old: "Old"
        }
    }

    static func resolve(rawValue: String?) -> Self {
        guard let rawValue, let value = Self(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }
}

private enum SttAppleNewWords {
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
            return sortedForDisplay(await SpeechTranscriber.supportedLocales)
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
    case unavailable
    case localeNotSupported(String)
    case modelInstallationFailed(String)
    case noCompatibleAudioFormat
    case authorizationDenied
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple SpeechTranscriber is unavailable on this OS or device."
        case .localeNotSupported(let locale):
            "Apple Speech does not support the locale \(locale) on this device."
        case .modelInstallationFailed(let message):
            "Apple Speech model installation failed: \(message)"
        case .noCompatibleAudioFormat:
            "Apple SpeechTranscriber has no compatible audio format for this device."
        case .authorizationDenied:
            "Apple Speech recognition permission was not granted."
        case .recognizerUnavailable:
            "Apple Speech recognition is currently unavailable."
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

    func transcribeFile(_ url: URL) async throws -> SttFileTranscription {
        switch self {
        case .new(let stt):
            return try await stt.transcribeFile(url)
        case .old(let stt):
            return try await stt.transcribeFile(url)
        }
    }
}

/// File-only Apple SpeechTranscriber adapter. The module has one narrow
/// interface: give it a complete audio file and receive its transcript.
@available(macOS 26.0, iOS 26.0, *)
actor SttAppleNew {
    private let locale: Locale

    /// Asset installation and audio-format selection happen before the engine
    /// is returned, so file transcription starts with a ready model.
    static func make(localeIdentifier: String) async throws -> SttAppleNew {
        guard SpeechTranscriber.isAvailable else {
            throw SttAppleError.unavailable
        }

        let requested = SttAppleLocaleResolver.requestedLocale(for: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw SttAppleError.localeNotSupported(requested.identifier(.bcp47))
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains {
            SttAppleLocaleResolver.isEquivalent($0, to: locale)
        }

        if !isInstalled {
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                    let installedAfterRequest = await SpeechTranscriber.installedLocales
                    guard installedAfterRequest.contains(where: {
                        SttAppleLocaleResolver.isEquivalent($0, to: locale)
                    }) else {
                        throw SttAppleError.modelInstallationFailed("no installation request was available")
                    }
                    return try await makeReady(locale: locale, transcriber: transcriber)
                }
                try await request.downloadAndInstall()
            } catch let error as SttAppleError {
                throw error
            } catch {
                throw SttAppleError.modelInstallationFailed(error.localizedDescription)
            }
        }

        return try await makeReady(locale: locale, transcriber: transcriber)
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
        transcriber: SpeechTranscriber
    ) async throws -> SttAppleNew {
        try await reserve(locale: locale)
        guard await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) != nil else {
            throw SttAppleError.noCompatibleAudioFormat
        }
        return SttAppleNew(locale: locale)
    }

    private init(locale: Locale) {
        self.locale = locale
    }

    func transcribeFile(_ url: URL) async throws -> SttFileTranscription {
        let audioFile = try AVAudioFile(forReading: url)
        return try await transcribeFile(audioFile)
    }

    /// Reads the complete file through SpeechAnalyzer. It never feeds chunks
    /// through a turn, so pauses in the recording cannot stop transcription.
    func transcribeFile(_ audioFile: AVAudioFile) async throws -> SttFileTranscription {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let transcriptionTask = Task { () throws -> SttFileTranscription in
            var transcription = AttributedString()
            for try await result in transcriber.results {
                transcription += result.text
            }

            return SttFileTranscription(
                text: String(transcription.characters),
                words: SttAppleNewWords.words(from: transcription))

        }

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
}
