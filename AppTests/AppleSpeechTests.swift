import Foundation
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

}
