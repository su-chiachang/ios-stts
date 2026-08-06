import Foundation

enum TttWebapiError: LocalizedError {
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

/// OpenAI-compatible chat-completions adapter for ttt and the STTS voice
/// conversation. It emits the text fragments carried by an SSE response.
@MainActor
final class TttWebapi: TttEngine {

    private struct Configuration {
        let baseURL: String
        let apiKey: String
        let model: String
    }

    private enum ConfigurationSource {
        case fixed(Configuration)
        case settings(AppSettings)

        var current: Configuration {
            switch self {
            case .fixed(let configuration):
                configuration
            case .settings(let settings):
                Configuration(baseURL: settings.llmBaseURL,
                              apiKey: settings.llmAPIKey,
                              model: settings.llmModel)
            }
        }
    }

    private let source: ConfigurationSource
    private let session: URLSession

    /// Fixed configuration initializer, useful for non-UI callers and tests.
    init(baseURL: String, apiKey: String, model: String, session: URLSession = .shared) throws {
        let configuration = Configuration(baseURL: baseURL, apiKey: apiKey, model: model)
        _ = try Self.endpoint(for: configuration.baseURL)
        source = .fixed(configuration)
        self.session = session
    }

    /// Settings-backed configuration reads the latest URL, key, and model for
    /// each request, so editing Settings does not leave a stale client alive.
    init(settings: AppSettings, session: URLSession = .shared) {
        source = .settings(settings)
        self.session = session
    }

    var availability: TttAvailability { .available }

    func streamChat(messages: [TttMessage]) -> AsyncThrowingStream<String, Error> {
        let source = source
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let configuration = source.current
                    let endpoint = try Self.endpoint(for: configuration.baseURL)
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !configuration.apiKey.isEmpty {
                        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONEncoder().encode(
                        ChatRequest(model: configuration.model, messages: messages))

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else {
                        throw TttWebapiError.unexpectedResponse
                    }
                    guard (200...299).contains(response.statusCode) else {
                        throw TttWebapiError.unsuccessfulStatus(response.statusCode)
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

    func reset() {}

    private static func endpoint(for value: String) throws -> URL {
        guard let baseURL = URL(string: value), baseURL.scheme != nil else {
            throw TttWebapiError.invalidBaseURL(value)
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TttWebapiError.invalidBaseURL(baseURL.absoluteString)
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "chat", "completions"].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else {
            throw TttWebapiError.invalidBaseURL(baseURL.absoluteString)
        }
        return endpoint
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [TttMessage]
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
