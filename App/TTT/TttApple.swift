import Foundation
import FoundationModels

/// Foundation Models adapter for ttt.
@MainActor
final class TttApple: TttEngine {
    nonisolated static let defaultInstructions = "You are a helpful assistant. Be concise."

    let model = SystemLanguageModel.default
    private let instructions: String
    private var session: LanguageModelSession
    private let respond: (LanguageModelSession, String) -> AsyncThrowingStream<String, Error>

    /// `respond` is a test seam. The injected stream may contain cumulative
    /// snapshots, matching `LanguageModelSession.streamResponse`.
    init(
        instructions: String = TttApple.defaultInstructions,
        respond: ((LanguageModelSession, String) -> AsyncThrowingStream<String, Error>)? = nil
    ) {
        self.instructions = instructions
        session = LanguageModelSession(instructions: instructions)
        self.respond = respond ?? { session, prompt in
            AsyncThrowingStream { continuation in
                let task = Task { @MainActor in
                    do {
                        for try await snapshot in session.streamResponse(to: prompt) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    var availability: TttAvailability {
        switch model.availability {
        case .available:
            .available
        case .unavailable(let reason):
            switch reason {
            case .modelNotReady:
                .unavailable(.modelNotReady)
            case .appleIntelligenceNotEnabled:
                .unavailable(.appleIntelligenceNotEnabled)
            case .deviceNotEligible:
                .unavailable(.deviceNotEligible)
            @unknown default:
                .unavailable(.other)
            }
        @unknown default:
            .unavailable(.other)
        }
    }

    func streamChat(messages: [TttMessage]) -> AsyncThrowingStream<String, Error> {
        guard let prompt = messages.last(where: { $0.role == .user })?.content else {
            return AsyncThrowingStream { $0.finish() }
        }

        let session = session
        let respond = respond
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    var previousSnapshot = ""
                    for try await snapshot in respond(session, prompt) {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }

                        let fragment: String
                        if snapshot.hasPrefix(previousSnapshot) {
                            fragment = String(snapshot.dropFirst(previousSnapshot.count))
                        } else {
                            // Keep the adapter tolerant of a test/provider
                            // that emits deltas instead of cumulative text.
                            fragment = snapshot
                        }
                        previousSnapshot = snapshot
                        if !fragment.isEmpty {
                            continuation.yield(fragment)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func reset() {
        session = LanguageModelSession(instructions: instructions)
    }
}
