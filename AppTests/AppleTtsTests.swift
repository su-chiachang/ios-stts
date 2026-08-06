import XCTest
@testable import STTS

final class AppleTtsTests: XCTestCase {
    func testVoiceResolverMapsSupportedSpokenLanguages() {
        XCTAssertEqual(AppleTtsVoiceResolver.localeIdentifier(for: .en), "en-US")
        XCTAssertEqual(AppleTtsVoiceResolver.localeIdentifier(for: .zh), "zh-CN")
        XCTAssertEqual(AppleTtsVoiceResolver.localeIdentifier(for: .ja), "ja-JP")
    }

    func testAppleTtsExposesNoModelSpeakerCatalog() async throws {
        let engine = TtsApple()

        let speakers = await engine.availableSpeakers()
        XCTAssertEqual(speakers, [])
        try await engine.warmUpVoice(referenceWavPath: "/does/not/exist.wav")
    }
}
