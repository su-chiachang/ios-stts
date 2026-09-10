import Foundation
import NaturalLanguage
import XCTest
@testable import STTS

final class SttSentenceBreakingTests: XCTestCase {
    private func words(_ pairs: [(String, Double, Double)]) -> [SttWordTimestamp] {
        pairs.map { SttWordTimestamp(text: $0.0, start: $0.1, end: $0.2) }
    }

    // MARK: - characterLimit / resolveLanguage

    func testCharacterLimitIsSixteenForChineseAndFortyTwoOtherwise() {
        XCTAssertEqual(SttSentenceBreaking.characterLimit(for: .simplifiedChinese), 16)
        XCTAssertEqual(SttSentenceBreaking.characterLimit(for: .traditionalChinese), 16)
        XCTAssertEqual(SttSentenceBreaking.characterLimit(for: .english), 42)
        XCTAssertEqual(SttSentenceBreaking.characterLimit(for: .japanese), 42)
    }

    func testResolveLanguageUsesTheSelectedLocaleFirst() {
        XCTAssertEqual(
            SttSentenceBreaking.resolveLanguage(localeIdentifier: "zh-TW", text: "hello"),
            .traditionalChinese)
        XCTAssertEqual(
            SttSentenceBreaking.resolveLanguage(localeIdentifier: "zh-CN", text: "hello"),
            .simplifiedChinese)
        XCTAssertEqual(
            SttSentenceBreaking.resolveLanguage(localeIdentifier: "en-US", text: "你好"),
            .english)
    }

    func testResolveLanguageFallsBackToRecognizerWhenTheLocaleIsUnmappable() {
        XCTAssertEqual(
            SttSentenceBreaking.resolveLanguage(
                localeIdentifier: "???", text: "這是一個測試句子，看看能不能偵測到中文。"),
            .traditionalChinese)
        XCTAssertEqual(
            SttSentenceBreaking.resolveLanguage(
                localeIdentifier: "???", text: "This is a test sentence written in English."),
            .english)
    }

    /// Regression: a locale this feature doesn't special-case (Cantonese) must
    /// still land in the Chinese bucket when its text is actually CJK-scripted,
    /// rather than silently defaulting to the English 42-character limit.
    func testResolveLanguageBucketsAnUnspecialCasedCjkLocaleAsChineseViaTheText() {
        let cantonese = "呢個係廣東話嘅測試句子，用嚟驗證斷句演算法喺呢種情況下嘅表現。"
        XCTAssertEqual(
            SttSentenceBreaking.resolveLanguage(localeIdentifier: "yue-HK", text: cantonese),
            .traditionalChinese)
    }

    func testResolveLanguageFallsBackToRecognizerForALocaleOtherThanEnglishOrChinese() {
        XCTAssertEqual(
            SttSentenceBreaking.resolveLanguage(
                localeIdentifier: "ja-JP", text: "これはテストの文章です。"),
            NLLanguage("ja"))
    }

    // MARK: - segments(for:locale:)

    func testEmptyTranscriptionProducesNoSegments() {
        let transcription = SttFileTranscription(text: "", words: [])
        XCTAssertEqual(SttSentenceBreaking.segments(for: transcription, locale: "en-US"), [])
    }

    func testShortSentenceIsOneSegmentWithFullWordRange() {
        let text = "Hello world."
        let ts = words([("Hello", 0.0, 0.4), ("world.", 0.5, 1.0)])
        let transcription = SttFileTranscription(text: text, words: ts)

        let segments = SttSentenceBreaking.segments(for: transcription, locale: "en-US")

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello world.")
        XCTAssertEqual(segments[0].wordRange, 0..<2)
    }

    func testSentencesAreNeverMergedEvenWhenShort() {
        let text = "Hi there. Ok."
        let transcription = SttFileTranscription(text: text, words: [])

        let segments = SttSentenceBreaking.segments(for: transcription, locale: "en-US")

        XCTAssertEqual(segments.map(\.text), ["Hi there.", "Ok."])
        XCTAssertTrue(segments.allSatisfy { $0.wordRange == nil })
    }

    func testOverLongSentenceSplitsAtTheCommaNearestTheLimitNotTheFirstOne() {
        let text =
            "Well, this is a long English sentence, and it definitely continues past the limit."
        let transcription = SttFileTranscription(text: text, words: [])

        let segments = SttSentenceBreaking.segments(for: transcription, locale: "en-US")

        XCTAssertEqual(segments.first?.text, "Well, this is a long English sentence,")
        XCTAssertEqual(segments.joined(separator: " "), text)
    }

    /// Regression: the limit check must use the trimmed remainder length
    /// (after skipping the space left by the previous break), not the raw
    /// range length, or a tail that fits exactly at the limit gets split
    /// again into a stray fragment.
    func testTrailingPieceExactlyAtTheLimitAfterATrimmedLeadingSpaceIsNotSplitAgain() {
        let tail = String(repeating: "b", count: SttSentenceBreaking.englishCharacterLimit - 1) + "."
        let text = String(repeating: "a", count: 40) + ", " + tail
        let transcription = SttFileTranscription(text: text, words: [])

        let segments = SttSentenceBreaking.segments(for: transcription, locale: "en-US")

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.last?.text, tail)
    }

    func testOverLongSentenceWithoutPunctuationSplitsAtAPauseGap() {
        // No punctuation at all. A deliberate >=0.3s pause is placed between
        // "delta" and "echo"; ordinary word gaps are all 0.05s. Several word
        // boundaries fall between the pause and the 42-char limit, so
        // choosing the pause position over those closer boundaries proves
        // the pause tier is actually consulted (not just "nearest word
        // boundary before the limit").
        let tokens = [
            "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india",
            "juliet",
        ]
        var timestamps: [(String, Double, Double)] = []
        var cursor = 0.0
        for (index, token) in tokens.enumerated() {
            let duration = Double(token.count) * 0.05
            let start = cursor
            let end = start + duration
            timestamps.append((token, start, end))
            let gap = (token == "delta") ? 0.5 : 0.05
            cursor = end + gap
        }
        let text = tokens.joined(separator: " ")
        let transcription = SttFileTranscription(text: text, words: words(timestamps))

        let pauseEndIndex = text.range(of: "delta")!.upperBound
        let expectedFirstSegment = String(text[text.startIndex..<pauseEndIndex])
        // Sanity check on the fixture: the pause must land before the
        // 42-character limit, and more text must exist after it, or this
        // test would not actually exercise the pause tier.
        XCTAssertLessThan(expectedFirstSegment.count, SttSentenceBreaking.englishCharacterLimit)
        XCTAssertGreaterThan(text.count, SttSentenceBreaking.englishCharacterLimit)

        let segments = SttSentenceBreaking.segments(for: transcription, locale: "en-US")

        XCTAssertEqual(segments.first?.text, expectedFirstSegment)
    }

    func testOverLongSentenceWithoutAnyBreakPointOverflowsToNearestWordBoundary() {
        // A single run-on token far longer than the 42-character limit, with
        // no punctuation and no timestamps: must not be cut mid-token, so it
        // overflows as one segment.
        let longToken = String(repeating: "a", count: 60)
        let text = "\(longToken) end."
        let transcription = SttFileTranscription(text: text, words: [])

        let segments = SttSentenceBreaking.segments(for: transcription, locale: "en-US")

        XCTAssertEqual(segments.first?.text, longToken)
        XCTAssertEqual(segments.joined(separator: " "), text)
    }

    func testChineseSentenceSplitsAtSixteenCharacterLimitOnClausePunctuation() {
        let text =
            "這是一句非常長的中文句子、用來測試斷句演算法在中文情境下的表現、應該要在頓號附近切開。"
        let transcription = SttFileTranscription(text: text, words: [])

        let segments = SttSentenceBreaking.segments(for: transcription, locale: "zh-TW")

        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments.dropLast() {
            XCTAssertLessThanOrEqual(segment.text.count, SttSentenceBreaking.chineseCharacterLimit)
        }
        XCTAssertEqual(segments.joined(), text)
    }

    func testMixedChineseAndEnglishTextProducesNonEmptySegments() {
        let text = "Hello 你好 this is 混合 text testing 中文和英文."
        let transcription = SttFileTranscription(text: text, words: [])

        let segments = SttSentenceBreaking.segments(for: transcription, locale: "en-US")

        XCTAssertFalse(segments.isEmpty)
        XCTAssertEqual(segments.joined(), text)
    }
}

extension Array where Element == SttReadableSegment {
    /// Reassembles the original text (modulo the whitespace trimmed at each
    /// break) so tests can assert no characters were dropped or duplicated.
    /// Pass the whitespace that existed at the break point, if any (English
    /// prose breaks on a space; CJK text typically has none).
    func joined(separator: String = "") -> String {
        map(\.text).joined(separator: separator)
    }
}
