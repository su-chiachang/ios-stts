import Foundation

/// One recognized word with its start/end time (seconds) and confidence in
/// (0,1]. Produced by `ParakeetStt.transcribeFileWords` from the native
/// per-word timestamp JSON.
struct TranscriptWord: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double
}

/// A run of words grouped into a sentence, carrying the sentence's overall
/// start/end (the first word's start and the last word's end).
struct TranscriptSentence: Identifiable, Equatable {
    let id: Int
    let text: String
    let start: Double
    let end: Double
    let words: [TranscriptWord]
}

/// Groups a flat `[TranscriptWord]` list into sentences. The native STT layer
/// only gives per-word timing, so sentence boundaries are derived here from
/// sentence-terminating punctuation and large inter-word silences.
enum TranscriptSegmenter {
    /// Sentence-ending punctuation, Latin and CJK.
    private static let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "；", ";"]

    /// Splits `words` into sentences. A sentence closes after a word that ends
    /// with terminating punctuation, or before a gap to the next word longer
    /// than `gapThreshold`. `frameSec` (the encoder frame stride) scales the
    /// gap threshold; when unavailable a 0.6 s default is used.
    static func sentences(from words: [TranscriptWord], frameSec: Double) -> [TranscriptSentence] {
        guard !words.isEmpty else { return [] }
        let gapThreshold = frameSec > 0 ? max(0.6, frameSec * 8) : 0.6

        var result: [TranscriptSentence] = []
        var current: [TranscriptWord] = []

        func flush() {
            defer { current = [] }
            guard let first = current.first, let last = current.last else { return }
            let text = current.reduce("") { appended($0, $1.text) }
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }   // drop punctuation-only / empty tails
            result.append(TranscriptSentence(id: result.count, text: text,
                                             start: first.start, end: last.end, words: current))
        }

        for (i, word) in words.enumerated() {
            current.append(word)
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            let endsSentence = trimmed.last.map { terminators.contains($0) } ?? false
            let bigGap = i + 1 < words.count && (words[i + 1].start - word.end) > gapThreshold
            if endsSentence || bigGap { flush() }
        }
        flush()
        return result
    }

    /// Joins `word` onto `text`, inserting a space only where detokenization
    /// wants one — i.e. not around CJK characters and not before leading
    /// punctuation. Yields "Hello world." for Latin and "你好世界。" for CJK.
    private static func appended(_ text: String, _ word: String) -> String {
        guard !text.isEmpty else { return word }
        guard let last = text.unicodeScalars.last, let first = word.unicodeScalars.first else { return text + word }
        let needsSpace = !isCJK(first) && !isCJK(last) && !isPunctuation(first)
        return text + (needsSpace ? " " : "") + word
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.punctuationCharacters.contains(scalar)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,          // CJK punctuation
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFF00...0xFFEF,          // fullwidth forms
             0x20000...0x2EBEF, 0x30000...0x323AF:
            true
        default:
            false
        }
    }
}
