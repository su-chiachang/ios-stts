import AVFoundation
import Foundation

/// Converts an arbitrary user-picked audio file into the exact WAV format the
/// qwen3-tts speaker encoder accepts: 24 kHz, mono, 16-bit PCM. The native
/// loader (qwen3_tts.cpp `load_audio_file`) only decodes integer PCM WAV
/// (16- or 32-bit) — it rejects compressed files and float32 WAV — so we can't
/// hand it the picked file directly.
enum ReferenceAudioImporter {
    enum ImportError: LocalizedError {
        case unreadableSource
        case conversionFailed
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadableSource: "Could not read the selected audio file."
            case .conversionFailed: "Could not convert the audio to 24 kHz mono."
            case .empty: "The selected audio file contains no audio."
            }
        }
    }

    /// The rate the speaker encoder expects. The native loader resamples too,
    /// but converting here keeps the on-disk reference in a single known shape.
    private static let sampleRate = 24_000.0

    /// Reads `source` (any Core Audio-decodable file), downmixes/resamples to
    /// 24 kHz mono, and writes a 16-bit PCM WAV at `destination`, replacing any
    /// existing file there.
    static func writeReferenceWav(from source: URL, to destination: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        guard let input = try? AVAudioFile(forReading: source) else {
            throw ImportError.unreadableSource
        }
        let inputFormat = input.processingFormat
        let frameCount = AVAudioFrameCount(input.length)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw ImportError.empty
        }
        try input.read(into: inputBuffer)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw ImportError.conversionFailed
        }

        // Size the output for the whole clip (sample-rate ratio + slack) so a
        // single convert() call drains all input before it reports noDataNow.
        let ratio = sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 4_096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw ImportError.conversionFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            throw ImportError.conversionFailed
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination,
                                     settings: settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)
        try output.write(from: outputBuffer)
    }
}
