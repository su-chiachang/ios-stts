@preconcurrency import AVFoundation
import CQwenTTS
import Foundation

enum QwenTtsError: Error, LocalizedError {
    case loadFailed(String)
    case synthesizeFailed(String)
    case invalidReferenceAudio

    var errorDescription: String? {
        switch self {
        case .loadFailed(let message): "Failed to load qwentts.cpp models: \(message)"
        case .synthesizeFailed(let message): message
        case .invalidReferenceAudio: "Could not decode the reference audio as 24 kHz mono PCM."
        }
    }
}

enum SpokenLanguage: String {
    case en = "English"
    case zh = "Chinese"
    case ja = "Japanese"
}

/// A matched qwentts.cpp talker/codec pair.  The selected talker determines
/// whether synthesis is Base, CustomVoice, or VoiceDesign.
enum QwenTtsVariant: String, CaseIterable, Identifiable {
    case base06b = "base-0.6b"
    case base17b = "base-1.7b"
    case customVoice06b = "customvoice-0.6b"
    case customVoice17b = "customvoice-1.7b"
    case voiceDesign17b = "voicedesign-1.7b"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base06b: "Base 0.6B"
        case .base17b: "Base 1.7B"
        case .customVoice06b: "CustomVoice 0.6B"
        case .customVoice17b: "CustomVoice 1.7B"
        case .voiceDesign17b: "VoiceDesign 1.7B"
        }
    }

    var talkerStem: String {
        switch self {
        case .base06b: "qwen-talker-0.6b-base"
        case .base17b: "qwen-talker-1.7b-base"
        case .customVoice06b: "qwen-talker-0.6b-customvoice"
        case .customVoice17b: "qwen-talker-1.7b-customvoice"
        case .voiceDesign17b: "qwen-talker-1.7b-voicedesign"
        }
    }
}

/// The qwentts.cpp distribution calls its 16-bit artifact BF16. The app uses
/// the familiar F16 label while preserving that exact upstream filename.
enum QwenTtsQuantization: String, CaseIterable, Identifiable {
    case f16
    case q8_0
    case q4_k_m

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .f16: "F16"
        case .q8_0: "Q8_0"
        case .q4_k_m: "Q4_K_M"
        }
    }
    var upstreamName: String {
        switch self {
        case .f16: "BF16"
        case .q8_0: "Q8_0"
        case .q4_k_m: "Q4_K_M"
        }
    }
    func talkerFilename(for variant: QwenTtsVariant) -> String {
        "\(variant.talkerStem)-\(upstreamName).gguf"
    }
    var codecFilename: String { "qwen-tokenizer-12hz-\(upstreamName).gguf" }
}

/// qwentts.cpp owns the native context; this actor serializes access because
/// the model contexts are not documented as safe for concurrent synthesis.
actor QwenTts {
    struct Chunk {
        let samples: [Float]
        let sampleRate: Double
    }

    private struct CachedVoiceReference {
        let path: String
        let speakerEmbedding: [Float]
        let codes: [Int32]
        let frameCount: Int
    }

    private var context: OpaquePointer?
    private var cachedVoiceReference: CachedVoiceReference?

    init(modelDir: String, variant: QwenTtsVariant, quantization: QwenTtsQuantization) throws {
        let modelDirectory = URL(fileURLWithPath: modelDir, isDirectory: true)
        let talker = modelDirectory.appendingPathComponent(quantization.talkerFilename(for: variant))
        let codec = modelDirectory.appendingPathComponent(quantization.codecFilename)
        let fm = FileManager.default
        for path in [talker, codec] where !fm.fileExists(atPath: path.path) {
            throw QwenTtsError.loadFailed("missing \(path.lastPathComponent) in \(modelDir) for \(variant.displayName)")
        }

        var params = qt_init_params()
        qt_init_default_params(&params)
        let loaded: OpaquePointer? = talker.path.withCString { talkerPath in
            codec.path.withCString { codecPath in
                params.talker_path = talkerPath
                params.codec_path = codecPath
                return qt_init(&params)
            }
        }
        guard let loaded else { throw QwenTtsError.loadFailed(Self.lastError()) }
        context = loaded
    }

    deinit {
        qt_free(context)
    }

    func availableSpeakers() -> [String] {
        guard let context else { return [] }
        return (0..<Int(qt_n_speakers(context))).compactMap { index in
            qt_speaker_name(context, Int32(index)).map(String.init(cString:))
        }
    }

    /// For Base models, reference audio enables x-vector cloning. Passing a
    /// matching reference transcript additionally enables ICL cloning. For
    /// CustomVoice use `speaker`; VoiceDesign requires `instruction`.
    func synthesize(
        _ text: String,
        language: SpokenLanguage,
        referenceWavPath: String? = nil,
        referenceTranscript: String? = nil,
        speaker: String? = nil,
        instruction: String? = nil,
        maxAudioTokens: Int32 = 1200
    ) throws -> Chunk {
        guard let context else { throw QwenTtsError.synthesizeFailed("model not loaded") }
        var params = qt_tts_params()
        qt_tts_default_params(&params)
        params.max_new_tokens = maxAudioTokens

        var audio = qt_audio()
        let status = try text.withCString { textPointer in
            try language.rawValue.withCString { languagePointer in
                try withOptionalCString(instruction) { instructionPointer in
                    try withOptionalCString(speaker) { speakerPointer in
                        try withOptionalCString(referenceTranscript) { transcriptPointer in
                            params.text = textPointer
                            params.lang = languagePointer
                            params.instruct = instructionPointer
                            params.speaker = speakerPointer
                            params.ref_text = transcriptPointer
                            if let referenceWavPath {
                                let reference = try voiceReference(for: referenceWavPath)
                                return reference.speakerEmbedding.withUnsafeBufferPointer { embedding in
                                    params.ref_spk_emb = embedding.baseAddress
                                    params.ref_spk_dim = Int32(embedding.count)
                                    guard transcriptPointer != nil else {
                                        return qt_synthesize(context, &params, &audio)
                                    }
                                    return reference.codes.withUnsafeBufferPointer { codes in
                                        params.ref_codes = codes.baseAddress
                                        params.ref_T = Int32(reference.frameCount)
                                        return qt_synthesize(context, &params, &audio)
                                    }
                                }
                            }
                            return qt_synthesize(context, &params, &audio)
                        }
                    }
                }
            }
        }
        guard status == QT_STATUS_OK else { throw QwenTtsError.synthesizeFailed(Self.lastError()) }
        defer { qt_audio_free(&audio) }
        guard let samples = audio.samples, audio.n_samples > 0 else {
            throw QwenTtsError.synthesizeFailed("qwentts.cpp returned no audio")
        }
        return Chunk(samples: Array(UnsafeBufferPointer(start: samples, count: Int(audio.n_samples))),
                     sampleRate: Double(audio.sample_rate))
    }

    func warmUpVoice(referenceWavPath: String) throws {
        _ = try voiceReference(for: referenceWavPath)
    }

    private func voiceReference(for path: String) throws -> CachedVoiceReference {
        if let cachedVoiceReference, cachedVoiceReference.path == path { return cachedVoiceReference }
        guard let context else { throw QwenTtsError.synthesizeFailed("model not loaded") }
        let samples = try Self.referenceSamples(at: URL(fileURLWithPath: path))
        var extracted = qt_voice_ref()
        let status = samples.withUnsafeBufferPointer {
            qt_extract_voice_ref(context, $0.baseAddress, Int32($0.count), &extracted)
        }
        guard status == QT_STATUS_OK,
              let embedding = extracted.ref_spk_emb,
              let codes = extracted.ref_codes,
              extracted.ref_spk_dim > 0,
              extracted.ref_T > 0,
              extracted.num_codebooks > 0 else {
            qt_voice_ref_free(&extracted)
            throw QwenTtsError.synthesizeFailed(Self.lastError())
        }
        defer { qt_voice_ref_free(&extracted) }
        let reference = CachedVoiceReference(
            path: path,
            speakerEmbedding: Array(UnsafeBufferPointer(start: embedding, count: Int(extracted.ref_spk_dim))),
            codes: Array(UnsafeBufferPointer(start: codes,
                                              count: Int(extracted.ref_T * extracted.num_codebooks))),
            frameCount: Int(extracted.ref_T))
        cachedVoiceReference = reference
        return reference
    }

    private static func lastError() -> String {
        qt_last_error().map(String.init(cString:)) ?? "unknown qwentts.cpp error"
    }

    private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        if let value { return try value.withCString { try body($0) } }
        return try body(nil)
    }

    private static func referenceSamples(at url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { throw QwenTtsError.invalidReferenceAudio }
        let source = file.processingFormat
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let output = AVAudioPCMBuffer(pcmFormat: target,
                                      frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 24_000 / source.sampleRate) + 4_096)!
        guard let converter = AVAudioConverter(from: source, to: target) else { throw QwenTtsError.invalidReferenceAudio }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !supplied else { outStatus.pointee = .endOfStream; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { throw QwenTtsError.invalidReferenceAudio }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
