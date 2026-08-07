import Foundation

enum SpokenLanguage: String, Sendable {
    case en = "English"
    case zh = "Chinese"
    case ja = "Japanese"
}

struct TtsAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

enum TtsEngineError: Error, LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: "TTS engine is not loaded."
        }
    }
}

protocol TtsEngine: AnyObject, Sendable {
    func synthesize(_ text: String, language: SpokenLanguage) async throws -> TtsAudioChunk
}
