import Foundation

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
        case "zh-tw", "zh-hk", "zh-hant": return Locale(identifier: "zh-TW")
        default: return Locale(identifier: value)
        }
    }

    static func isEquivalent(_ lhs: Locale, to rhs: Locale) -> Bool {
        lhs.identifier(.bcp47).caseInsensitiveCompare(rhs.identifier(.bcp47)) == .orderedSame
    }
}
