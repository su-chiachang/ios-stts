import CQwen3TTS
import Foundation

enum QwenTtsError: Error, LocalizedError {
    case loadFailed(String)
    case synthesizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let m): "Failed to load qwen3-tts models: \(m)"
        case .synthesizeFailed(let m): m
        }
    }
}

enum SpokenLanguage: Int32 {
    case en = 2050
    case zh = 2055
    case ja = 2058
}

/// Wraps the qwen3-tts C API. `actor` because the opaque handle is not
/// documented as thread-safe. Synthesis is full-utterance only (no
/// streaming) — see SentenceChunker for how the app hides this latency.
actor QwenTts {
    struct Chunk {
        let samples: [Float]
        let sampleRate: Double
    }

    private var tts: OpaquePointer?

    init(modelDir: String, threads: Int32 = 4) throws {
        guard let tts = qwen3_tts_create(modelDir, threads) else {
            throw QwenTtsError.loadFailed("qwen3_tts_create returned NULL for \(modelDir)")
        }
        self.tts = tts
    }

    deinit {
        if let tts { qwen3_tts_destroy(tts) }
    }

    private func lastError() -> String {
        guard let tts, let cstr = qwen3_tts_get_error(tts) else { return "unknown error" }
        return String(cString: cstr)
    }

    func synthesize(_ text: String, language: SpokenLanguage, maxAudioTokens: Int32 = 1200) throws -> Chunk {
        guard let tts else { throw QwenTtsError.synthesizeFailed("model not loaded") }
        var params = Qwen3TtsParams()
        qwen3_tts_default_params(&params)
        params.language_id = language.rawValue
        params.max_audio_tokens = maxAudioTokens

        guard let audio = qwen3_tts_synthesize(tts, text, &params) else {
            throw QwenTtsError.synthesizeFailed(lastError())
        }
        defer { qwen3_tts_free_audio(audio) }
        let n = Int(audio.pointee.n_samples)
        let samples = Array(UnsafeBufferPointer(start: audio.pointee.samples, count: n))
        return Chunk(samples: samples, sampleRate: Double(audio.pointee.sample_rate))
    }
}
