import Foundation
import Speech

enum SttBackend: String, CaseIterable, Identifiable, Sendable {
    case parakeet
    case appleSpeech

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: "Parakeet"
        case .appleSpeech: "Apple Speech"
        }
    }
}

/// Describes how a backend's latest recognition result should be applied to
/// the conversation transcript. Parakeet emits append-only finalized text;
/// SpeechTranscriber can revise its volatile result, so it emits a snapshot.
enum SttTextUpdate: Sendable, Equatable {
    case append(String)
    case replace(String)

    func applying(to transcript: String) -> String {
        switch self {
        case .append(let text): transcript + text
        case .replace(let text): text
        }
    }
}

struct SttFeedResult: Sendable {
    let textUpdate: SttTextUpdate
    let eou: Bool
    let eob: Bool

    init(textUpdate: SttTextUpdate, eou: Bool, eob: Bool) {
        self.textUpdate = textUpdate
        self.eou = eou
        self.eob = eob
    }
}

struct SttTimestampedResult: Sendable {
    let words: [TranscriptWord]
    let frameSec: Double
}

protocol SttEngine: AnyObject, Sendable {
    /// Buffered engines cannot emit partial text, but the endpoint detector
    /// may still end a turn after speech followed by silence.
    var canEndTurnWithoutTranscript: Bool { get async }

    func beginTurn(lang: String?) async throws
    func feed(_ pcm: [Float]) async throws -> SttFeedResult
    func endTurn() async throws -> SttTextUpdate
    func transcribeFileWords(pcm: [Float], lang: String?) async throws -> SttTimestampedResult
}

enum SttEngineError: LocalizedError {
    case wordTimestampsUnavailable(backend: String)

    var errorDescription: String? {
        switch self {
        case .wordTimestampsUnavailable(let backend):
            "\(backend) does not provide per-word timestamps for file transcription."
        }
    }
}

/// Maps the app's compact locale choices to one concrete locale for Apple's
/// locale-dependent SpeechTranscriber. "auto" deliberately resolves to the
/// user's current locale; SpeechTranscriber does not expose an auto-language
/// mode.
enum AppleSpeechLocaleResolver {
    static func requestedLocale(for identifier: String?, current: Locale = .current) -> Locale {
        let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.lowercased() != "auto" else { return current }

        switch value.lowercased() {
        case "en": return Locale(identifier: "en-US")
        case "zh", "zh-cn", "zh-hans": return Locale(identifier: "zh-CN")
        // Only aliases that aren't themselves supported locales belong here.
        // zh-HK is one SpeechTranscriber supports on its own, so folding it
        // into zh-TW would make the 中文（香港）row impossible to select.
        case "zh-tw", "zh-hant": return Locale(identifier: "zh-TW")
        default: return Locale(identifier: value)
        }
    }

    static func isEquivalent(_ lhs: Locale, to rhs: Locale) -> Bool {
        lhs.identifier(.bcp47).caseInsensitiveCompare(rhs.identifier(.bcp47)) == .orderedSame
    }

    /// The identifier form used for persistence and for picker tags. Stored
    /// settings predate the full locale list ("en", "zh-CN"), so every value
    /// goes through `requestedLocale` first; otherwise an old "en" would match
    /// no row and the picker would render blank.
    static let autoTag = "auto"

    static func tag(for identifier: String?) -> String {
        let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.lowercased() != autoTag else { return autoTag }
        return tag(for: requestedLocale(for: value))
    }

    static func tag(for locale: Locale) -> String {
        locale.identifier(.bcp47)
    }

    /// Every locale SpeechTranscriber can transcribe, sorted by the name shown
    /// in the picker. Installation state is deliberately ignored: selecting an
    /// uninstalled locale is what triggers its asset download in `SttApple`.
    static func supportedLocales() async -> [Locale] {
        let supported = await SpeechTranscriber.supportedLocales
        return sortedForDisplay(supported)
    }

    static func sortedForDisplay(_ locales: [Locale]) -> [Locale] {
        var seen = Set<String>()
        let unique = locales.filter { seen.insert(tag(for: $0).lowercased()).inserted }
        return unique.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    /// Named in the locale's own language ("中文（台灣）"), which is what the
    /// person picking it reads, with the BCP-47 tag as the fallback.
    static func displayName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? tag(for: locale)
    }
}
