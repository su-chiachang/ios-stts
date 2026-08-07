import XCTest
@testable import STTS

final class SttBackendTests: XCTestCase {
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

    /// Settings saved before the picker listed every supported locale hold
    /// compact identifiers. They have to normalize onto a tag the picker
    /// actually renders, or the control comes up with nothing selected.
    func testAppleSpeechLocaleTagsNormalizeLegacySettings() {
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: "en"), "en-US")
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: "zh-Hant"), "zh-TW")
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: "en-GB"), "en-GB")
        // Supported locales must survive the alias table untouched, or their
        // picker row silently snaps to whatever the alias points at.
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: "zh-HK"), "zh-HK")
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: "zh-CN"), "zh-CN")
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: "auto"), "auto")
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: ""), "auto")
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: nil), "auto")
        // A tag written back by the picker must survive a second round trip.
        XCTAssertEqual(AppleSpeechLocaleResolver.tag(for: AppleSpeechLocaleResolver.tag(for: "en")),
                       "en-US")
    }

    func testAppleSpeechSupportedLocalesSortAndDeduplicate() {
        let sorted = AppleSpeechLocaleResolver.sortedForDisplay([
            Locale(identifier: "ja-JP"),
            Locale(identifier: "en-US"),
            Locale(identifier: "en_US"),
        ])
        XCTAssertEqual(sorted.map { AppleSpeechLocaleResolver.tag(for: $0) }, ["en-US", "ja-JP"])
        // Names come from the locale itself, not the app's language.
        XCTAssertTrue(AppleSpeechLocaleResolver.displayName(for: Locale(identifier: "ja-JP"))
            .contains("日本語"))
    }

    func testSpeechTextUpdatesPreserveAppendAndReplaceSemantics() {
        XCTAssertEqual(SttTextUpdate.append("hello"), .append("hello"))
        XCTAssertEqual(SttTextUpdate.replace("hello, revised"), .replace("hello, revised"))
        XCTAssertNotEqual(SttTextUpdate.append("hello"), .replace("hello"))

        let appended = SttTextUpdate.append(" world").applying(to: "hello")
        let replaced = SttTextUpdate.replace("hello, revised").applying(to: appended)
        XCTAssertEqual(appended, "hello world")
        XCTAssertEqual(replaced, "hello, revised")
    }
}
