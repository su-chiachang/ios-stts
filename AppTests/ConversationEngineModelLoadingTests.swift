import XCTest
@testable import STTS

@MainActor
final class ConversationEngineModelLoadingTests: XCTestCase {
    func testLoadModelsUsesPersistedTtsBackendAndReleasesPreviousEngine() async {
        let settings = AppSettings.shared
        let previousBackend = settings.ttsBackend
        defer { settings.ttsBackend = previousBackend }

        var loadedBackends: [TtsBackend] = []
        var loadCount = 0
        weak var firstEngine: StubTtsEngine?
        let engine = StsEngine(
            sttLoader: { _ in StubSttEngine() },
            ttsLoader: { settings in
                loadedBackends.append(settings.ttsBackend)
                let loaded = StubTtsEngine()
                if loadCount == 0 { firstEngine = loaded }
                loadCount += 1
                return loaded
            })

        settings.ttsBackend = .qwen
        await engine.loadModels()
        XCTAssertEqual(loadedBackends, [.qwen])
        XCTAssertTrue(engine.isReady)

        settings.ttsBackend = .audio8
        await engine.loadModels()

        XCTAssertEqual(loadedBackends, [.qwen, .audio8])
        XCTAssertTrue(engine.isReady)
        XCTAssertNil(firstEngine, "reload must release the previous TTS runtime")

        settings.ttsBackend = .appleSpeech
        await engine.loadModels()

        XCTAssertEqual(loadedBackends, [.qwen, .audio8, .appleSpeech])
        XCTAssertTrue(engine.isReady)
    }

    func testLoadModelsDoesNotPublishPartialSttWhenTtsLoadFails() async {
        let settings = AppSettings.shared
        let previousBackend = settings.ttsBackend
        defer { settings.ttsBackend = previousBackend }

        let engine = StsEngine(
            sttLoader: { _ in StubSttEngine() },
            ttsLoader: { _ in throw StubTtsError.loadFailed })

        settings.ttsBackend = .audio8
        await engine.loadModels()

        XCTAssertFalse(engine.isReady)
        guard case .error(let message) = engine.state else {
            return XCTFail("expected a backend load error")
        }
        XCTAssertEqual(message, "Audio8 test loader failed")
    }
}

private enum StubTtsError: Error, LocalizedError {
    case loadFailed

    var errorDescription: String? { "Audio8 test loader failed" }
}

private actor StubTtsEngine: TtsEngine {
    func synthesize(
        _ text: String,
        language: SpokenLanguage,
        referenceWavPath: String?,
        referenceTranscript: String?,
        speaker: String?,
        instruction: String?,
        maxAudioTokens: Int32
    ) throws -> TtsAudioChunk {
        TtsAudioChunk(samples: [0], sampleRate: 44_100)
    }

    func warmUpVoice(referenceWavPath: String) throws {}

    func availableSpeakers() -> [String] { [] }
}

private actor StubSttEngine: SttEngine {
    var canEndTurnWithoutTranscript: Bool { true }

    func beginTurn(lang: String?) throws {}

    func feed(_ pcm: [Float]) throws -> SttFeedResult {
        SttFeedResult(textUpdate: .append(""), eou: false, eob: false)
    }

    func endTurn() throws -> SttTextUpdate { .append("") }

    func transcribeFileWords(pcm: [Float], lang: String?) throws -> SttTimestampedResult {
        SttTimestampedResult(words: [], frameSec: 0)
    }
}
