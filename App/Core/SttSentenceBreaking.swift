import Foundation
import NaturalLanguage

/// A chunk of transcript text sized for comfortable reading. See
/// `Wayfinder: Readable-length transcript segmentation (CN/EN)` (issue #71)
/// for the decisions this type and `SttSentenceBreaking` implement.
struct SttReadableSegment: Equatable, Sendable {
    let text: String
    let wordRange: Range<Int>?
}

enum SttSentenceBreaking {
    static let englishCharacterLimit = 42
    static let chineseCharacterLimit = 16
    static let pauseGapThreshold: Double = 0.3

    private static let clauseBreakCharacters: Set<Character> = [",", ";", "，", "、", "；"]

    /// The pieces a sentence is being split against: the whole transcript
    /// text, this language's character limit, the tokenizer language, and
    /// the word timestamps with their matched ranges in `text`.
    private struct Context {
        let text: String
        let limit: Int
        let language: NLLanguage
        let words: [SttWordTimestamp]
        let wordRanges: [Range<String.Index>?]
    }

    /// Breaks `transcription.text` into readable segments: one segment per
    /// sentence (sentences are never merged), further split at a clause
    /// punctuation mark, then a word-timestamp pause gap, then a plain word
    /// boundary — in that priority order — when a sentence exceeds the
    /// per-language character limit. Never force-breaks mid-token; a
    /// sentence with no valid break point before the limit is allowed to
    /// overflow it.
    static func segments(
        for transcription: SttFileTranscription,
        locale localeIdentifier: String
    ) -> [SttReadableSegment] {
        let text = transcription.text
        guard !text.isEmpty else { return [] }

        let language = resolveLanguage(localeIdentifier: localeIdentifier, text: text)
        let context = Context(
            text: text,
            limit: characterLimit(for: language),
            language: language,
            words: transcription.words,
            wordRanges: matchWordRanges(words: transcription.words, in: text))

        return sentenceRanges(in: text, language: language)
            .flatMap { splitRange($0, context: context) }
            .map { makeSegment(range: $0, context: context) }
    }

    static func characterLimit(for language: NLLanguage) -> Int {
        switch language {
        case .simplifiedChinese, .traditionalChinese:
            return chineseCharacterLimit
        default:
            return englishCharacterLimit
        }
    }

    /// The user's already-selected STT locale (`SttLocalePreferences`) is the
    /// primary language signal, since it is already fed to
    /// `SpeechTranscriber`/`DictationTranscriber`. `NLLanguageRecognizer` is
    /// the fallback for anything other than the two languages this feature
    /// targets — which also correctly routes a CJK-scripted locale this
    /// feature doesn't special-case (e.g. Cantonese) to the Chinese bucket
    /// by detecting the actual script of the text, rather than silently
    /// falling into the English bucket.
    static func resolveLanguage(localeIdentifier: String, text: String) -> NLLanguage {
        let locale = SttAppleLocaleResolver.requestedLocale(for: localeIdentifier)
        switch locale.language.languageCode?.identifier {
        case "zh":
            return locale.language.script?.identifier == "Hans"
                ? .simplifiedChinese
                : .traditionalChinese
        case "en":
            return .english
        default:
            return NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        }
    }

    // MARK: - Sentence boundaries

    private static func sentenceRanges(
        in text: String,
        language: NLLanguage
    ) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(language)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let trimmed = trimmed(range, in: text) {
                ranges.append(trimmed)
            }
            return true
        }
        return ranges
    }

    // MARK: - Splitting an over-long sentence

    private static func splitRange(
        _ range: Range<String.Index>,
        context: Context
    ) -> [Range<String.Index>] {
        guard range.lowerBound < range.upperBound else { return [] }
        guard context.text.distance(from: range.lowerBound, to: range.upperBound) > context.limit
        else {
            return [range]
        }
        guard
            let limitIndex = context.text.index(
                range.lowerBound, offsetBy: context.limit, limitedBy: range.upperBound)
        else {
            return [range]
        }

        let wordCandidates = wordBoundaries(in: range, context: context)

        let breakPoint =
            nearestCandidate(
                clauseBreakPositions(in: range, text: context.text),
                atOrBefore: limitIndex, after: range.lowerBound)
            ?? nearestCandidate(
                pauseBreakPositions(in: range, context: context),
                atOrBefore: limitIndex, after: range.lowerBound)
            ?? nearestCandidate(wordCandidates, atOrBefore: limitIndex, after: range.lowerBound)

        guard let breakPoint else {
            // No valid break point at or before the limit: extend to the
            // nearest word boundary past it rather than cutting mid-token.
            guard
                let overflowEnd = wordCandidates.filter({ $0 > limitIndex }).min(),
                overflowEnd < range.upperBound,
                let remainder = trimmedLeading(overflowEnd..<range.upperBound, in: context.text)
            else {
                return [range]
            }
            return [range.lowerBound..<overflowEnd] + splitRange(remainder, context: context)
        }

        guard let remainder = trimmedLeading(breakPoint..<range.upperBound, in: context.text)
        else {
            return [range.lowerBound..<breakPoint]
        }
        return [range.lowerBound..<breakPoint] + splitRange(remainder, context: context)
    }

    private static func nearestCandidate(
        _ candidates: [String.Index],
        atOrBefore limit: String.Index,
        after start: String.Index
    ) -> String.Index? {
        candidates.filter { $0 > start && $0 <= limit }.max()
    }

    /// Positions right after a clause-punctuation mark. Checked as literal
    /// characters regardless of the resolved language, so the minority
    /// script in a mixed-language sentence still gets a break candidate.
    private static func clauseBreakPositions(
        in range: Range<String.Index>,
        text: String
    ) -> [String.Index] {
        var positions: [String.Index] = []
        var index = range.lowerBound
        while index < range.upperBound {
            if clauseBreakCharacters.contains(text[index]) {
                positions.append(text.index(after: index))
            }
            index = text.index(after: index)
        }
        return positions
    }

    /// Positions right after a word whose gap to the next word is at least
    /// `pauseGapThreshold` seconds. Only relevant when timestamps are
    /// available.
    private static func pauseBreakPositions(
        in range: Range<String.Index>,
        context: Context
    ) -> [String.Index] {
        let words = context.words
        let wordRanges = context.wordRanges
        guard words.count == wordRanges.count, words.count > 1 else { return [] }
        var positions: [String.Index] = []
        for index in 0..<(words.count - 1) {
            guard
                let currentRange = wordRanges[index],
                wordRanges[index + 1] != nil,
                words[index + 1].start - words[index].end >= pauseGapThreshold
            else { continue }
            let position = currentRange.upperBound
            guard position > range.lowerBound, position <= range.upperBound else { continue }
            positions.append(position)
        }
        return positions
    }

    /// `NLTokenizer(unit: .word)` only returns lexical words, so trailing
    /// punctuation right after one (a sentence-final period, a closing
    /// quote) isn't part of any token's range. Each boundary is extended
    /// past a directly-adjacent non-whitespace run so that punctuation
    /// stays attached to the word before it, rather than becoming a
    /// candidate break point that would strand it as its own segment.
    private static func wordBoundaries(
        in range: Range<String.Index>,
        context: Context
    ) -> [String.Index] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(context.language)
        tokenizer.string = context.text
        var boundaries: [String.Index] = []
        tokenizer.enumerateTokens(in: range) { tokenRange, _ in
            boundaries.append(
                extendPastAdjacentPunctuation(
                    tokenRange.upperBound, upperBound: range.upperBound, text: context.text))
            return true
        }
        return boundaries
    }

    private static func extendPastAdjacentPunctuation(
        _ index: String.Index,
        upperBound: String.Index,
        text: String
    ) -> String.Index {
        var index = index
        while index < upperBound, !text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index
    }

    // MARK: - Whitespace trimming

    /// Advances `range`'s lower bound past leading whitespace and pulls its
    /// upper bound back before trailing whitespace, so every range's
    /// character count (used for the limit check) reflects only the text
    /// that will actually be displayed. `nil` if nothing but whitespace
    /// remains.
    private static func trimmed(_ range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        guard let start = trimmedLeading(range, in: text) else { return nil }
        var end = start.upperBound
        while end > start.lowerBound, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return start.lowerBound..<end
    }

    private static func trimmedLeading(
        _ range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        var start = range.lowerBound
        while start < range.upperBound, text[start].isWhitespace {
            start = text.index(after: start)
        }
        return start < range.upperBound ? start..<range.upperBound : nil
    }

    // MARK: - Word-range matching

    /// Derives each word's range in `text` by walking the pieces
    /// `SttWordHighlighting.transcriptSegments` already computes (it does
    /// the same cursor-forward search this needs), rather than re-searching
    /// the transcript a second time.
    private static func matchWordRanges(
        words: [SttWordTimestamp],
        in text: String
    ) -> [Range<String.Index>?] {
        var ranges = [Range<String.Index>?](repeating: nil, count: words.count)
        var cursor = text.startIndex
        for piece in SttWordHighlighting.transcriptSegments(in: text, words: words) {
            guard let end = text.index(cursor, offsetBy: piece.text.count, limitedBy: text.endIndex)
            else { break }
            if let wordIndex = piece.wordIndex {
                ranges[wordIndex] = cursor..<end
            }
            cursor = end
        }
        return ranges
    }

    private static func makeSegment(
        range: Range<String.Index>,
        context: Context
    ) -> SttReadableSegment {
        var firstIndex: Int?
        var lastIndex: Int?
        for (index, wordRange) in context.wordRanges.enumerated() {
            guard let wordRange,
                  wordRange.lowerBound < range.upperBound,
                  wordRange.upperBound > range.lowerBound
            else { continue }
            if firstIndex == nil { firstIndex = index }
            lastIndex = index
        }

        let wordRange: Range<Int>?
        if let firstIndex, let lastIndex {
            wordRange = firstIndex..<(lastIndex + 1)
        } else {
            wordRange = nil
        }

        return SttReadableSegment(text: String(context.text[range]), wordRange: wordRange)
    }
}
