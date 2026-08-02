import CAudio8
import Foundation

enum Audio8SttError: Error, LocalizedError {
    case loadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let message):
            "Failed to load Audio8 ARK-ASR model: \(message)"
        case .transcriptionFailed(let message):
            "Audio8 ARK-ASR transcription failed: \(message)"
        }
    }
}

/// Owns one Audio8 ARK-ASR C-ABI model. ARK-ASR currently exposes buffered
/// transcription rather than a streaming session, so microphone chunks are
/// accumulated and decoded once the endpoint detector closes the turn.
actor Audio8Stt: SttEngine {
    private var model: OpaquePointer?
    private var turnPCM: [Float] = []

    var canEndTurnWithoutTranscript: Bool { true }

    init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw Audio8SttError.loadFailed("missing \(modelURL.lastPathComponent)")
        }

        var options = audio8_ark_asr_options()
        options.n_threads = 4
        options.verbosity = 0
        options.use_gpu = 1
        options.temperature = 0
        options.beam_size = 1

        var nativeError = audio8_error()
        let loaded = modelURL.path.withCString { path in
            audio8_ark_asr_create(path, &options, &nativeError)
        }
        guard let loaded else {
            throw Audio8SttError.loadFailed(Self.takeError(&nativeError))
        }
        model = loaded
    }

    deinit {
        if let model {
            audio8_ark_asr_destroy(model)
        }
    }

    func beginTurn(lang: String?) throws {
        _ = lang
        turnPCM.removeAll(keepingCapacity: true)
        guard model != nil else {
            throw Audio8SttError.transcriptionFailed("model is not loaded")
        }
    }

    func feed(_ pcm: [Float]) throws -> SttFeedResult {
        guard model != nil else {
            throw Audio8SttError.transcriptionFailed("model is not loaded")
        }
        turnPCM.append(contentsOf: pcm)
        return SttFeedResult(newText: "", eou: false, eob: false)
    }

    @discardableResult
    func endTurn() throws -> String {
        defer { turnPCM.removeAll(keepingCapacity: true) }
        guard !turnPCM.isEmpty else { return "" }
        return try transcribe(turnPCM)
    }

    func transcribeFileWords(pcm: [Float], lang: String?) throws -> SttTimestampedResult {
        _ = pcm
        _ = lang
        throw SttEngineError.wordTimestampsUnavailable(backend: "Audio8 ARK-ASR")
    }

    private func transcribe(_ pcm: [Float]) throws -> String {
        guard let model else {
            throw Audio8SttError.transcriptionFailed("model is not loaded")
        }
        var textPointer: UnsafeMutablePointer<CChar>?
        var nativeError = audio8_error()
        let status = pcm.withUnsafeBufferPointer { samples in
            audio8_ark_asr_transcribe_pcm(model,
                                          samples.baseAddress,
                                          samples.count,
                                          &textPointer,
                                          &nativeError)
        }
        guard status != 0, let textPointer else {
            throw Audio8SttError.transcriptionFailed(Self.takeError(&nativeError))
        }
        defer { audio8_ark_asr_free_string(textPointer) }
        return String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func takeError(_ error: inout audio8_error) -> String {
        defer { audio8_error_free(&error) }
        guard let message = error.message else { return "unknown error" }
        return String(cString: message)
    }
}
