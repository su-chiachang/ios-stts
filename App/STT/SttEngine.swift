import Foundation
import Speech

/// Describes how Apple's latest recognition result should be applied to the
/// conversation transcript. SpeechTranscriber can revise its volatile result,
/// so it emits a snapshot.
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
    var canEndTurnWithoutTranscript: Bool { get async }

    func beginTurn(lang: String?) async throws
    func feed(_ pcm: [Float]) async throws -> SttFeedResult
    func endTurn() async throws -> SttTextUpdate
    func transcribeFileWords(pcm: [Float], lang: String?) async throws -> SttTimestampedResult
}

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

    /// Installation state is deliberately ignored: selecting an uninstalled
    /// locale lets `SttApple.make` prepare its Apple speech asset.
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

    /// Names the locale in its own language, with the BCP-47 tag available to
    /// distinguish regional variants such as en-US and en-GB.
    static func displayName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? tag(for: locale)
    }

}
