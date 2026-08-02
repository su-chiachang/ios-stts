import AVFoundation
import Foundation

/// Converts an arbitrary user-picked audio file into a mono, 16-bit PCM WAV.
/// The stored sample rate is preserved: QwenTts resamples its copy to 24 kHz
/// before extracting a voice reference, while Audio8 forwards the source rate
/// to its native codec for the required 44.1 kHz conditioning conversion.
enum ReferenceAudioImporter {
    enum ImportError: LocalizedError {
        case unreadableSource
        case conversionFailed
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadableSource: "Could not read the selected audio file."
            case .conversionFailed: "Could not convert the audio to mono PCM."
            case .empty: "The selected audio file contains no audio."
            }
        }
    }

    /// Reads `source` (any Core Audio-decodable file), downmixes it to mono at
    /// the source sample rate, and writes a 16-bit PCM WAV at `destination`,
    /// replacing any existing file there.
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

        guard inputFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: inputFormat.sampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw ImportError.conversionFailed
        }

        // Size the output for the whole clip plus slack so one convert() call
        // drains all input before it reports noDataNow.
        let capacity = frameCount + 4_096
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
            AVSampleRateKey: inputFormat.sampleRate,
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
