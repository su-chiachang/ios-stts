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

/// Talker/tokenizer quantization pairing. qwen3-tts.cpp's loader always
/// pairs a given talker with a specific vocoder ("tokenizer") file — the two
/// aren't independently selectable, so this enum is the unit of choice.
enum QwenTtsVariant: String, CaseIterable, Identifiable {
    case f16
    case q8_0
    case q4_k_m

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .f16: "F16 (talker + tokenizer)"
        case .q8_0: "Q8 (talker) + F16 (tokenizer)"
        case .q4_k_m: "Q4 (talker + tokenizer)"
        }
    }
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

    init(modelDir: String, variant: QwenTtsVariant, threads: Int32 = 4) throws {
        guard let tts = variant.rawValue.withCString({ qwen3_tts_create(modelDir, $0, threads) }) else {
            throw QwenTtsError.loadFailed("qwen3_tts_create returned NULL for \(modelDir) (variant: \(variant.rawValue))")
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
