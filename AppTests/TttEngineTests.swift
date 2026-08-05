import XCTest
import FoundationModels
@testable import STTS

@MainActor
final class TttEngineTests: XCTestCase {
    func testSendAppendsUserMessageAndClearsDraft() {
        let engine = TttEngine()
        engine.draft = "hello"
        engine.send()
        XCTAssertEqual(engine.messages.first?.text, "hello")
        XCTAssertEqual(engine.messages.first?.role, .user)
        XCTAssertEqual(engine.draft, "")
    }

    func testCanSendRequiresNonBlankDraftAndNotStreaming() {
        let engine = TttEngine()
        XCTAssertFalse(engine.canSend)
        engine.draft = "   "
        XCTAssertFalse(engine.canSend)
        engine.draft = "hi"
        XCTAssertTrue(engine.canSend)
    }

    func testNewChatResetsState() {
        let engine = TttEngine()
        engine.draft = "hello"
        engine.send()
        XCTAssertFalse(engine.messages.isEmpty)
        engine.newChat()
        XCTAssertTrue(engine.messages.isEmpty)
        XCTAssertEqual(engine.draft, "")
        XCTAssertFalse(engine.isSessionExhausted)
    }

    func testExceededContextWindowMapsToNonRetryableAndExhaustsSession() {
        let engine = TttEngine()
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "too long")
        let message = engine.errorMessage(for: .exceededContextWindowSize(context))
        XCTAssertEqual(message.kind, .error(retryable: false))
        XCTAssertTrue(engine.isSessionExhausted)
    }

    func testGuardrailAndRefusalAreNotRetryable() {
        let engine = TttEngine()
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "blocked")
        let guardrail = engine.errorMessage(for: .guardrailViolation(context))
        XCTAssertEqual(guardrail.kind, .error(retryable: false))

        let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
        let refused = engine.errorMessage(for: .refusal(refusal, context))
        XCTAssertEqual(refused.kind, .error(retryable: false))
    }

    func testRateLimitedAndConcurrentRequestsAreRetryable() {
        let engine = TttEngine()
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "busy")
        XCTAssertEqual(engine.errorMessage(for: .rateLimited(context)).kind, .error(retryable: true))
        XCTAssertEqual(engine.errorMessage(for: .concurrentRequests(context)).kind, .error(retryable: true))
    }
}
