import Foundation
import FoundationModels
import Observation

/// Drives the ttt (text-to-text) chat tab: a single, in-memory conversation
/// against the on-device `LanguageModelSession`. Standalone — does not hook
/// into `ConversationEngine`'s per-tab load/unload lifecycle (see wayfinder
/// map https://github.com/su-chiachang/ios-stts/issues/21), since the model
/// is system-managed rather than app-downloaded.
///
/// Built against the `LanguageModelSession.GenerationError` surface actually
/// shipped in this SDK (Xcode 26.3 / iOS 26.2), not the `LanguageModelError`
/// split described in Apple's live web docs — that split (plus a queryable
/// `contextSize`) isn't present in this toolchain's FoundationModels
/// swiftinterface, so error handling here targets the case set that's
/// really available to compile against.
@MainActor
@Observable
final class TttEngine {
    struct Message: Identifiable {
        enum Role: Equatable { case user, assistant }
        enum Kind: Equatable {
            case normal
            case error(retryable: Bool)
        }

        let id = UUID()
        let role: Role
        var text: String
        var kind: Kind = .normal
    }

    private(set) var messages: [Message] = []
    var draft = ""
    private(set) var isStreaming = false
    private(set) var isSessionExhausted = false

    let model = SystemLanguageModel.default
    private var session: LanguageModelSession
    private var lastUserPrompt: String?
    private let respond: (LanguageModelSession, String) -> AsyncThrowingStream<String, Error>

    private static let instructions = "You are a helpful assistant. Be concise."

    /// `respond` is a seam for tests — injecting a fake avoids the default
    /// implementation's real `LanguageModelSession.streamResponse` call,
    /// which isn't mockable directly since `ResponseStream` has no public
    /// initializer outside the framework.
    init(respond: ((LanguageModelSession, String) -> AsyncThrowingStream<String, Error>)? = nil) {
        session = LanguageModelSession(instructions: Self.instructions)
        self.respond = respond ?? { session, prompt in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await snapshot in session.streamResponse(to: prompt) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    var canSend: Bool {
        !isStreaming && !isSessionExhausted
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, !isSessionExhausted, !session.isResponding else { return }
        draft = ""
        messages.append(Message(role: .user, text: text))
        stream(prompt: text)
    }

    func retry(_ message: Message) {
        guard let prompt = lastUserPrompt, !isStreaming, !isSessionExhausted, !session.isResponding else { return }
        messages.removeAll { $0.id == message.id }
        stream(prompt: prompt)
    }

    func newChat() {
        session = LanguageModelSession(instructions: Self.instructions)
        messages.removeAll()
        draft = ""
        isStreaming = false
        isSessionExhausted = false
        lastUserPrompt = nil
    }

    private func stream(prompt: String) {
        lastUserPrompt = prompt
        isStreaming = true
        let index = messages.count
        messages.append(Message(role: .assistant, text: ""))
        Task {
            do {
                for try await chunk in respond(session, prompt) {
                    guard index < messages.count else { return }
                    messages[index].text = chunk
                }
            } catch let error as LanguageModelSession.GenerationError {
                guard index < messages.count else { isStreaming = false; return }
                messages[index] = errorMessage(for: error)
            } catch {
                guard index < messages.count else { isStreaming = false; return }
                messages[index] = Message(role: .assistant, text: "Couldn't get a response. Try again.", kind: .error(retryable: true))
            }
            isStreaming = false
        }
    }

    func errorMessage(for error: LanguageModelSession.GenerationError) -> Message {
        switch error {
        case .exceededContextWindowSize:
            isSessionExhausted = true
            return Message(role: .assistant,
                            text: "This conversation's gotten too long for the model to continue. Start a new chat to keep going.",
                            kind: .error(retryable: false))
        case .guardrailViolation, .refusal:
            return Message(role: .assistant, text: "This can't be answered.", kind: .error(retryable: false))
        case .unsupportedLanguageOrLocale:
            return Message(role: .assistant, text: "This language isn't supported.", kind: .error(retryable: false))
        case .unsupportedGuide, .decodingFailure, .assetsUnavailable:
            return Message(role: .assistant, text: "Something about this request isn't supported.", kind: .error(retryable: false))
        case .rateLimited, .concurrentRequests:
            return Message(role: .assistant, text: "Couldn't get a response. Try again.", kind: .error(retryable: true))
        @unknown default:
            return Message(role: .assistant, text: "Couldn't get a response. Try again.", kind: .error(retryable: true))
        }
    }
}
