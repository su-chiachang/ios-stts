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
///
/// The vendored loader (unmodified — see qwen3-tts.cpp/src/qwen3tts_c_api.h)
/// takes no variant argument. It hardcodes what it scans `model_dir` for: a
/// talker named "qwen3-tts-0.6b-q8_0.gguf" (preferred if present) or
/// "qwen3-tts-0.6b-f16.gguf" (fallback), paired with a tokenizer always
/// literally named "qwen3-tts-tokenizer-f16.gguf". `QwenTts.init` stages
/// symlinks under those exact expected names so this unmodified loader picks
/// up whichever real variant the user selected — see `stagedModelDir`.
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

    /// Real on-disk filenames, as published by scripts/fetch-models.sh.
    fileprivate var talkerFilename: String {
        switch self {
        case .f16: "qwen3-tts-0.6b-f16.gguf"
        case .q8_0: "qwen3-tts-0.6b-q8_0.gguf"
        case .q4_k_m: "qwen3-tts-0.6b-q4-k-m.gguf"
        }
    }

    fileprivate var tokenizerFilename: String {
        switch self {
        case .f16, .q8_0: "qwen3-tts-tokenizer-f16.gguf"
        case .q4_k_m: "qwen3-tts-tokenizer-0.6b-q4-k-m.gguf"
        }
    }

    /// Filename the unmodified loader must see the talker under to make it
    /// load this variant: the fixed "f16" name for .f16, or the fixed
    /// "q8_0" name (which the loader always prefers when present) for
    /// anything else — GGUF is self-describing, so a q4_k_m talker loads
    /// fine under that name despite it not saying "q4".
    fileprivate var stagedTalkerFilename: String {
        self == .f16 ? "qwen3-tts-0.6b-f16.gguf" : "qwen3-tts-0.6b-q8_0.gguf"
    }

    /// The loader only ever opens a tokenizer at this fixed path.
    fileprivate static let stagedTokenizerFilename = "qwen3-tts-tokenizer-f16.gguf"
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

    /// Memoized speaker embedding for the last reference WAV. Extracting it is
    /// an encoder pass; caching lets per-sentence synthesis reuse it via
    /// `qwen3_tts_synthesize_with_embedding`. Keyed by path — importing a new
    /// voice writes a uniquely-named file, so a changed voice never hits a
    /// stale entry.
    private var cachedEmbedding: (referencePath: String, values: [Float])?

    init(modelDir: String, variant: QwenTtsVariant, threads: Int32 = 4) throws {
        let staged = try Self.stagedModelDir(sourceDir: modelDir, variant: variant)
        guard let tts = qwen3_tts_create(staged.path, threads) else {
            throw QwenTtsError.loadFailed("qwen3_tts_create returned NULL for \(staged.path) (variant: \(variant.rawValue))")
        }
        self.tts = tts
    }

    /// Symlinks the chosen variant's real model files into a per-variant
    /// scratch directory under the fixed names the unmodified loader scans
    /// for (see QwenTtsVariant doc comment).
    private static func stagedModelDir(sourceDir: String, variant: QwenTtsVariant) throws -> URL {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: sourceDir)
        let talkerSource = source.appendingPathComponent(variant.talkerFilename)
        let tokenizerSource = source.appendingPathComponent(variant.tokenizerFilename)
        for path in [talkerSource, tokenizerSource] where !fm.fileExists(atPath: path.path) {
            throw QwenTtsError.loadFailed("missing \(path.lastPathComponent) in \(sourceDir) for variant \(variant.rawValue)")
        }

        let staged = fm.temporaryDirectory
            .appendingPathComponent("QwenTtsStaged", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try relink(talkerSource, to: staged.appendingPathComponent(variant.stagedTalkerFilename))
        try relink(tokenizerSource, to: staged.appendingPathComponent(QwenTtsVariant.stagedTokenizerFilename))
        return staged
    }

    private static func relink(_ source: URL, to link: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
    }

    deinit {
        if let tts { qwen3_tts_destroy(tts) }
    }

    private func lastError() -> String {
        guard let tts, let cstr = qwen3_tts_get_error(tts) else { return "unknown error" }
        return String(cString: cstr)
    }

    /// Synthesizes `text`. When `referenceWavPath` is non-nil the output is
    /// spoken in that reference voice (voice cloning); otherwise the model's
    /// default voice is used.
    func synthesize(_ text: String, language: SpokenLanguage,
                    referenceWavPath: String? = nil,
                    maxAudioTokens: Int32 = 1200) throws -> Chunk {
        guard let tts else { throw QwenTtsError.synthesizeFailed("model not loaded") }
        var params = Qwen3TtsParams()
        qwen3_tts_default_params(&params)
        params.language_id = language.rawValue
        params.max_audio_tokens = maxAudioTokens

        let audio: UnsafeMutablePointer<Qwen3TtsAudio>?
        if let referenceWavPath {
            let embedding = try speakerEmbedding(forReferenceWav: referenceWavPath)
            audio = embedding.withUnsafeBufferPointer { buffer in
                qwen3_tts_synthesize_with_embedding(tts, text, buffer.baseAddress,
                                                    Int32(buffer.count), &params)
            }
        } else {
            audio = qwen3_tts_synthesize(tts, text, &params)
        }
        guard let audio else { throw QwenTtsError.synthesizeFailed(lastError()) }
        defer { qwen3_tts_free_audio(audio) }
        let n = Int(audio.pointee.n_samples)
        let samples = Array(UnsafeBufferPointer(start: audio.pointee.samples, count: n))
        return Chunk(samples: samples, sampleRate: Double(audio.pointee.sample_rate))
    }

    /// Pre-extracts (and caches) the speaker embedding for a reference WAV so
    /// the first spoken sentence isn't slowed by the encoder pass, and so a bad
    /// reference clip surfaces its error at import time rather than mid-speech.
    func warmUpVoice(referenceWavPath: String) throws {
        _ = try speakerEmbedding(forReferenceWav: referenceWavPath)
    }

    private func speakerEmbedding(forReferenceWav path: String) throws -> [Float] {
        if let cachedEmbedding, cachedEmbedding.referencePath == path {
            return cachedEmbedding.values
        }
        guard let tts else { throw QwenTtsError.synthesizeFailed("model not loaded") }
        // Embedding is ~1024 floats; a 4096 buffer leaves generous headroom.
        var buffer = [Float](repeating: 0, count: 4_096)
        let size = qwen3_tts_extract_embedding_file(tts, path, &buffer, Int32(buffer.count))
        guard size > 0 else {
            throw QwenTtsError.synthesizeFailed("Failed to extract speaker embedding: \(lastError())")
        }
        let values = Array(buffer.prefix(Int(size)))
        cachedEmbedding = (path, values)
        return values
    }
}
