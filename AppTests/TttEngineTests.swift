import Foundation
import FoundationModels
import XCTest
@testable import STTS

@MainActor
final class TttEngineTests: XCTestCase {
    private static func snapshotRespond(_: LanguageModelSession, _: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("hello")
            continuation.yield("hello world")
            continuation.finish()
        }
    }

    private static func noopRespond(_: LanguageModelSession, _: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func testBackendChoices() {
        XCTAssertEqual(TttBackend.allCases, [.apple, .webapi])
    }

    func testAppleAdapterConvertsCumulativeSnapshotsToFragments() async throws {
        let provider = TttApple(respond: Self.snapshotRespond)
        var iterator = provider.streamChat(
            messages: [TttMessage(role: .user, content: "hi")]
        ).makeAsyncIterator()

        let first = try await iterator.next()
        let second = try await iterator.next()
        let end = try await iterator.next()
        XCTAssertEqual(first, "hello")
        XCTAssertEqual(second, " world")
        XCTAssertNil(end)
    }

    func testWebapiRejectsInvalidBaseURL() {
        XCTAssertThrowsError(try TttWebapi(baseURL: "not a URL", apiKey: "", model: "test"))
    }

    func testSttsEngineOwnsTheLoadedTttProvider() {
        let provider = TttApple(respond: Self.noopRespond)
        let engine = StsEngine(tttLoader: { _ in provider })

        XCTAssertTrue(engine.tttEngine is TttApple)
    }

    func testTttLoaderRebuildsTheProviderWhenBackendChanges() {
        let settings = AppSettings.shared
        let previousBackend = settings.tttBackend
        defer { settings.tttBackend = previousBackend }

        var loadedBackends: [TttBackend] = []
        settings.tttBackend = .apple
        let engine = StsEngine(tttLoader: { settings in
            loadedBackends.append(settings.tttBackend)
            return settings.tttBackend == .apple
                ? TttApple(respond: Self.noopRespond)
                : TttWebapi(settings: settings)
        })

        engine.setTttBackend(.webapi, settings: settings)

        XCTAssertEqual(loadedBackends, [.apple, .webapi])
        XCTAssertTrue(engine.tttEngine is TttWebapi)
    }
}
