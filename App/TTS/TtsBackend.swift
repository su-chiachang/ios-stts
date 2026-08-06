import Foundation

enum TtsBackend: String, CaseIterable, Identifiable, Sendable {
    case qwen
    case audio8
    case appleSpeech

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen: "Qwen"
        case .audio8: "Audio8"
        case .appleSpeech: "Apple Speech"
        }
    }
}

struct TtsAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

enum TtsEngineError: Error, LocalizedError {
    case notLoaded
    case synthesisFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            "TTS model is not loaded."
        case .synthesisFailed(let message), .unsupported(let message):
            message
        }
    }
}

protocol TtsEngine: AnyObject, Sendable {
    func synthesize(
        _ text: String,
        language: SpokenLanguage,
        referenceWavPath: String?,
        referenceTranscript: String?,
        speaker: String?,
        instruction: String?,
        maxAudioTokens: Int32
    ) async throws -> TtsAudioChunk

    func warmUpVoice(referenceWavPath: String) async throws
    func availableSpeakers() async -> [String]
}
