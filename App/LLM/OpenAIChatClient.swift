import Foundation

enum OpenAIChatError: LocalizedError {
    case invalidBaseURL(String)
    case unexpectedResponse
    case unsuccessfulStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value): "Invalid LLM base URL: \(value)"
        case .unexpectedResponse: "The LLM returned an invalid HTTP response."
        case .unsuccessfulStatus(let status): "The LLM request failed with HTTP \(status)."
        }
    }
}

/// Small client for OpenAI-compatible `POST /chat/completions` SSE streams.
/// It intentionally exposes text fragments only; sentence chunking and TTS
/// belong to M4.
struct OpenAIChatClient {
    struct Message: Encodable, Sendable {
        enum Role: String, Encodable, Sendable { case system, user, assistant }

        let role: Role
        let content: String
    }

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(baseURL: String, apiKey: String, model: String, session: URLSession = .shared) throws {
        guard let baseURL = URL(string: baseURL), baseURL.scheme != nil else {
            throw OpenAIChatError.invalidBaseURL(baseURL)
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OpenAIChatError.invalidBaseURL(baseURL.absoluteString)
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "chat", "completions"].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else {
            throw OpenAIChatError.invalidBaseURL(baseURL.absoluteString)
        }
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func streamChat(messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONEncoder().encode(ChatRequest(model: model, messages: messages))

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else {
                        throw OpenAIChatError.unexpectedResponse
                    }
                    guard (200...299).contains(response.statusCode) else {
                        throw OpenAIChatError.unsuccessfulStatus(response.statusCode)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        let event = try JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8))
                        for choice in event.choices {
                            if let text = choice.delta.content, !text.isEmpty {
                                continuation.yield(text)
                            }
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

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream = true
    }

    private struct StreamEvent: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let delta: Delta
        }

        struct Delta: Decodable {
            let content: String?
        }
    }
}
