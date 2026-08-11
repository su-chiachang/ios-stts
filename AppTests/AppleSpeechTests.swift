import CoreMedia
import Foundation
import Speech
import XCTest
@testable import STTS

final class AppleSpeechTests: XCTestCase {
    func testAppleSpeechLocaleResolverMapsCompactIdentifiers() {
        XCTAssertEqual(
            AppleSpeechLocaleResolver.requestedLocale(for: "en").identifier(.bcp47),
            "en-US")
        XCTAssertEqual(
            AppleSpeechLocaleResolver.requestedLocale(for: "zh-Hant").identifier(.bcp47),
            "zh-TW")
        XCTAssertEqual(
            AppleSpeechLocaleResolver.requestedLocale(for: "zh-CN").identifier(.bcp47),
            "zh-CN")
    }

    func testAppleSpeechAutoUsesProvidedCurrentLocale() {
        let current = Locale(identifier: "ja-JP")
        let resolved = AppleSpeechLocaleResolver.requestedLocale(for: "auto", current: current)
        XCTAssertEqual(resolved.identifier(.bcp47), "ja-JP")
    }

    func testSttLocalePreferencePersistsCanonicalIdentifier() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SttLocalePreferences.key)
        defer {
            if let previous {
                defaults.set(previous, forKey: SttLocalePreferences.key)
            } else {
                defaults.removeObject(forKey: SttLocalePreferences.key)
            }
        }

        SttLocalePreferences.save("zh-Hant")

        XCTAssertEqual(SttLocalePreferences.identifier, "zh-TW")
    }

    func testSttWordTimestampExtractorReadsTimedRuns() {
        var transcription = AttributedString("hello world")
        let helloRange = try! XCTUnwrap(transcription.range(of: "hello"))
        let worldRange = try! XCTUnwrap(transcription.range(of: "world"))

        transcription[helloRange][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] =
            CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 1000),
                duration: CMTime(seconds: 0.5, preferredTimescale: 1000))
        transcription[worldRange][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] =
            CMTimeRange(
                start: CMTime(seconds: 2, preferredTimescale: 1000),
                duration: CMTime(seconds: 0.75, preferredTimescale: 1000))

        let words = SttWordTimestampExtractor.extract(from: transcription)

        XCTAssertEqual(words.map(\.text), ["hello", "world"])
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(words[0].end, 1.5, accuracy: 0.001)
        XCTAssertEqual(words[1].start, 2, accuracy: 0.001)
        XCTAssertEqual(words[1].end, 2.75, accuracy: 0.001)
    }

}
