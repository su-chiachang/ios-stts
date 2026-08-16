import XCTest
@testable import STTS

final class AppleTtsTests: XCTestCase {
    func testVoiceResolverMapsSupportedSpokenLanguages() {
        XCTAssertEqual(AppleTtsVoiceResolver.localeIdentifier(for: .en), "en-US")
        XCTAssertEqual(AppleTtsVoiceResolver.localeIdentifier(for: .zh), "zh-CN")
        XCTAssertEqual(AppleTtsVoiceResolver.localeIdentifier(for: .ja), "ja-JP")
    }

    func testVoiceCatalogGroupsByLocaleAndSortsVoices() {
        let catalog = AppleTtsVoiceCatalog(
            displayLocale: Locale(identifier: "zh-TW"),
            source: {
                [
                    AppleTtsVoice(
                        identifier: "zh-tw-meijia",
                        language: "zh-TW",
                        name: "Meijia",
                        quality: .default),
                    AppleTtsVoice(
                        identifier: "en-us-samantha",
                        language: "en-US",
                        name: "Samantha",
                        quality: .default),
                    AppleTtsVoice(
                        identifier: "en-gb-daniel",
                        language: "en-GB",
                        name: "Daniel",
                        quality: .enhanced),
                    AppleTtsVoice(
                        identifier: "en-us-aaron",
                        language: "en-US",
                        name: "Aaron",
                        quality: .default),
                ]
            })

        let groups = catalog.groups()

        XCTAssertEqual(groups.map(\.language), ["en-GB", "en-US", "zh-TW"])
        XCTAssertEqual(groups[0].languageName, "英文（英國）")
        XCTAssertEqual(groups[1].voices.map(\.name), ["Aaron", "Samantha"])
        XCTAssertEqual(groups[0].voices.first?.quality, .enhanced)
    }

    func testVoiceCatalogDeduplicatesIdentifiersAndRefreshesFromSource() {
        var snapshots = [
            AppleTtsVoice(
                identifier: "en-us-samantha",
                language: "en-US",
                name: "Samantha",
                quality: .default),
            AppleTtsVoice(
                identifier: "en-us-samantha",
                language: "en-US",
                name: "Duplicate Samantha",
                quality: .enhanced),
        ]
        let catalog = AppleTtsVoiceCatalog(
            displayLocale: Locale(identifier: "en-US"),
            source: { snapshots })

        XCTAssertEqual(catalog.groups().flatMap(\.voices).map(\.name), ["Samantha"])

        snapshots = [
            AppleTtsVoice(
                identifier: "ja-jp-kyoko",
                language: "ja-JP",
                name: "Kyoko",
                quality: .enhanced),
        ]

        XCTAssertEqual(catalog.groups().map(\.language), ["ja-JP"])
        XCTAssertEqual(catalog.groups().flatMap(\.voices).map(\.name), ["Kyoko"])
    }

}
