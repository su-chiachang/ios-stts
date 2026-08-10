import AVFoundation
import Foundation
import Speech

enum SttLocalePreferences {
    static let key = "sttLocale"
    static let defaultIdentifier = "auto"

    static var identifier: String {
        UserDefaults.standard.string(forKey: key) ?? defaultIdentifier
    }

    static func save(_ identifier: String) {
        UserDefaults.standard.set(AppleSpeechLocaleResolver.tag(for: identifier), forKey: key)
    }
}

/// Maps the optional locale choice to one concrete locale for Apple's
/// locale-dependent SpeechTranscriber. A missing or `auto` value resolves to
/// the user's current system locale.
enum AppleSpeechLocaleResolver {
    static let autoTag = "auto"

    static func requestedLocale(for identifier: String?, current: Locale = .current) -> Locale {
        let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.lowercased() != "auto" else { return current }

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
    static func tag(for identifier: String?) -> String {
        let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.lowercased() != autoTag else { return autoTag }
        return tag(for: requestedLocale(for: value))
    }

    static func tag(for locale: Locale) -> String {
        locale.identifier(.bcp47)
    }

    static func supportedLocales() async -> [Locale] {
        sortedForDisplay(await SpeechTranscriber.supportedLocales)
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

enum AppleSpeechSttError: LocalizedError {
    case unavailable
    case localeNotSupported(String)
    case modelInstallationFailed(String)
    case noCompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple SpeechTranscriber is unavailable on this OS or device."
        case .localeNotSupported(let locale):
            "Apple SpeechTranscriber does not support the locale \(locale) on this device."
        case .modelInstallationFailed(let message):
            "Apple Speech model installation failed: \(message)"
        case .noCompatibleAudioFormat:
            "Apple SpeechTranscriber has no compatible audio format for this device."
        }
    }
}

/// File-only Apple SpeechTranscriber adapter. The module has one narrow
/// interface: give it a complete audio file and receive its transcript.
@available(macOS 26.0, iOS 26.0, *)
actor SttApple {
    private let locale: Locale

    /// Asset installation and audio-format selection happen before the engine
    /// is returned, so file transcription starts with a ready model.
    static func make(localeIdentifier: String?) async throws -> SttApple {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechSttError.unavailable
        }

        let requested = AppleSpeechLocaleResolver.requestedLocale(for: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AppleSpeechSttError.localeNotSupported(requested.identifier(.bcp47))
        }

        let transcriber = makeTranscriber(locale: locale)
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains {
            AppleSpeechLocaleResolver.isEquivalent($0, to: locale)
        }

        if !isInstalled {
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                    let installedAfterRequest = await SpeechTranscriber.installedLocales
                    guard installedAfterRequest.contains(where: {
                        AppleSpeechLocaleResolver.isEquivalent($0, to: locale)
                    }) else {
                        throw AppleSpeechSttError.modelInstallationFailed("no installation request was available")
                    }
                    return try await makeReady(locale: locale, transcriber: transcriber)
                }
                try await request.downloadAndInstall()
            } catch let error as AppleSpeechSttError {
                throw error
            } catch {
                throw AppleSpeechSttError.modelInstallationFailed(error.localizedDescription)
            }
        }

        return try await makeReady(locale: locale, transcriber: transcriber)
    }

    /// SpeechAnalyzer requires modules to reserve their locale first.
    private static func reserve(locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { AppleSpeechLocaleResolver.isEquivalent($0, to: locale) }) {
            return
        }

        for stale in reserved.dropFirst(max(0, AssetInventory.maximumReservedLocales - 1)) {
            await AssetInventory.release(reservedLocale: stale)
        }

        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            throw AppleSpeechSttError.modelInstallationFailed(error.localizedDescription)
        }
    }

    private static func makeReady(
        locale: Locale,
        transcriber: SpeechTranscriber
    ) async throws -> SttApple {
        try await reserve(locale: locale)
        guard await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) != nil else {
            throw AppleSpeechSttError.noCompatibleAudioFormat
        }
        return SttApple(locale: locale)
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    private init(locale: Locale) {
        self.locale = locale
    }

    func transcribeFile(_ url: URL) async throws -> String {
        let audioFile = try AVAudioFile(forReading: url)
        return try await transcribeFile(audioFile)
    }

    /// Reads the complete file through SpeechAnalyzer. It never feeds chunks
    /// through a turn, so pauses in the recording cannot stop transcription.
    func transcribeFile(_ audioFile: AVAudioFile) async throws -> String {
        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let transcriptionTask = Task { () throws -> String in
            var fragments: [String] = []
            for try await result in transcriber.results {
                fragments.append(String(result.text.characters))
            }
            return fragments.joined()
        }

        do {
            guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                await analyzer.cancelAndFinishNow()
                transcriptionTask.cancel()
                _ = await transcriptionTask.result
                return ""
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
