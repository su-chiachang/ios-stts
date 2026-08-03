@preconcurrency import AVFoundation
import CAudio8
import Foundation

enum Audio8TtsError: Error, LocalizedError {
    case loadFailed(String)
    case synthesisFailed(String)
    case invalidReferenceAudio(String)
    case missingReferenceTranscript

    var errorDescription: String? {
        switch self {
        case .loadFailed(let message):
            "Failed to load Audio8 models: \(message)"
        case .synthesisFailed(let message):
            "Audio8 synthesis failed: \(message)"
        case .invalidReferenceAudio(let message):
            "Audio8 reference audio is invalid: \(message)"
        case .missingReferenceTranscript:
            "Audio8 reference synthesis requires the reference transcript."
        }
    }
}

/// Owns one Audio8 C-ABI runtime and serializes all mutable native access.
/// The native runtime itself owns the generator/codec/tokenizer state.
actor Audio8Tts: TtsEngine {
    private var runtime: OpaquePointer?

    init(generatorURL: URL,
         codecURL: URL,
         tokenizerURL: URL,
         expectedExportDtype: String) throws {
        let paths = [generatorURL, codecURL, tokenizerURL]
        let fileManager = FileManager.default
        for url in paths where !fileManager.fileExists(atPath: url.path) {
            throw Audio8TtsError.loadFailed("missing \(url.lastPathComponent)")
        }

        var nativeError = audio8_error()
        let loaded = expectedExportDtype.withCString { expected in
            generatorURL.path.withCString { generator in
                codecURL.path.withCString { codec in
                    tokenizerURL.path.withCString { tokenizer in
                        audio8_runtime_create_for_export_dtype(
                            generator, codec, tokenizer, expected, &nativeError)
                    }
                }
            }
        }
        guard let loaded else {
            let message = Self.takeError(&nativeError)
            throw Audio8TtsError.loadFailed(message)
        }
        runtime = loaded
    }

    deinit {
        if let runtime {
            audio8_runtime_destroy(runtime)
        }
    }

    func synthesize(
        _ text: String,
        language: SpokenLanguage,
        referenceWavPath: String? = nil,
        referenceTranscript: String? = nil,
        speaker: String? = nil,
        instruction: String? = nil,
        maxAudioTokens: Int32 = 1200
    ) throws -> TtsAudioChunk {
        // Audio8's prompt contract is text-only; the native API has no
        // language field, so language selection remains a Qwen-only control.
        _ = language
        guard speaker == nil, instruction == nil else {
            throw Audio8TtsError.synthesisFailed("Audio8 does not support Qwen speaker or instruction controls.")
        }
        guard let runtime else { throw Audio8TtsError.synthesisFailed("runtime is not loaded") }

        let transcript = referenceTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        if referenceWavPath != nil && (transcript?.isEmpty ?? true) {
            throw Audio8TtsError.missingReferenceTranscript
        }

        let reference: (samples: [Float], sampleRate: UInt32)?
        if let referenceWavPath {
            reference = try Self.referenceSamples(at: URL(fileURLWithPath: referenceWavPath))
        } else {
            reference = nil
        }

        var request = audio8_synthesis_request()
        request.max_new_tokens = UInt32(max(1, maxAudioTokens))
        request.prefer_metal = 1
        var output = audio8_audio_buffer()
        var nativeError = audio8_error()

        let status: Int32 = text.withCString { textPointer in
            request.text = textPointer
            return Self.withOptionalCString(transcript) { transcriptPointer in
                request.reference_text = transcriptPointer
                if let reference {
                    return reference.samples.withUnsafeBufferPointer { samples in
                        request.reference_audio = samples.baseAddress
                        request.reference_audio_samples = samples.count
                        request.reference_audio_sample_rate = reference.sampleRate
                        return audio8_runtime_synthesize(runtime, &request, &output, &nativeError)
                    }
                }
                return audio8_runtime_synthesize(runtime, &request, &output, &nativeError)
            }
        }
        defer { audio8_audio_buffer_free(&output) }

        guard status != 0 else {
            throw Audio8TtsError.synthesisFailed(Self.takeError(&nativeError))
        }
        guard let samples = output.samples,
              output.sample_count > 0,
              output.sample_rate == 44_100,
              output.channels == 1 else {
            throw Audio8TtsError.synthesisFailed("runtime returned audio that is not mono 44.1 kHz PCM")
        }

        return TtsAudioChunk(
            samples: Array(UnsafeBufferPointer(start: samples, count: Int(output.sample_count))),
            sampleRate: Double(output.sample_rate))
    }

    func warmUpVoice(referenceWavPath: String) throws {
        _ = referenceWavPath
    }

    func availableSpeakers() -> [String] { [] }

    private static func takeError(_ error: inout audio8_error) -> String {
        defer { audio8_error_free(&error) }
        guard let message = error.message else { return "unknown Audio8 error" }
        return String(cString: message)
    }

    private static func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> T
    ) rethrows -> T {
        if let value { return try value.withCString { try body($0) } }
        return try body(nil)
    }

    private static func referenceSamples(at url: URL) throws -> (samples: [Float], sampleRate: UInt32) {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw Audio8TtsError.invalidReferenceAudio("could not open the file")
        }
        let source = file.processingFormat
        guard source.sampleRate > 0, file.length > 0 else {
            throw Audio8TtsError.invalidReferenceAudio("empty or invalid audio format")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: source.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                                             frameCapacity: AVAudioFrameCount(file.length) + 4_096),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw Audio8TtsError.invalidReferenceAudio("could not create a mono PCM converter")
        }
        try file.read(into: input)

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error,
              conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            throw Audio8TtsError.invalidReferenceAudio("could not convert to mono float PCM")
        }

        return (
            Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))),
            UInt32(source.sampleRate.rounded()))
    }
}
