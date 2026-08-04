import Foundation

enum SttBackend: String, CaseIterable, Identifiable, Sendable {
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: "Parakeet"
        }
    }
}

struct SttFeedResult: Sendable {
    let newText: String
    let eou: Bool
    let eob: Bool
}

struct SttTimestampedResult: Sendable {
    let words: [TranscriptWord]
    let frameSec: Double
}

protocol SttEngine: AnyObject, Sendable {
    /// Buffered engines cannot emit partial text, but the endpoint detector
    /// may still end a turn after speech followed by silence.
    var canEndTurnWithoutTranscript: Bool { get async }

    func beginTurn(lang: String?) async throws
    func feed(_ pcm: [Float]) async throws -> SttFeedResult
    func endTurn() async throws -> String
    func transcribeFileWords(pcm: [Float], lang: String?) async throws -> SttTimestampedResult
}

enum SttEngineError: LocalizedError {
    case wordTimestampsUnavailable(backend: String)

    var errorDescription: String? {
        switch self {
        case .wordTimestampsUnavailable(let backend):
            "\(backend) does not provide per-word timestamps for file transcription."
        }
    }
}
