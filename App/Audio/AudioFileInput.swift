import AVFoundation
import Foundation

enum AudioFileError: Error, LocalizedError {
    case noAudioTrack

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "The selected file has no audio track."
        }
    }
}

/// Decodes the audio track of ANY AVFoundation-readable container (plain
/// audio files like wav/mp3/m4a, or video files like mp4/mov — the audio
/// track is extracted the same way either way) to 16 kHz mono Float32,
/// chunked to match what ParakeetStt.feed expects.
///
/// Used as the M2 STT input source (deterministic, no mic/permissions
/// needed) ahead of live mic capture (M6).
struct AudioFileInput {
    let url: URL

    /// `realtime: true` paces chunk delivery to the file's own playback
    /// rate, so the partial-transcript UI behaves like it will once fed by
    /// a live mic. Set false to decode as fast as possible.
    func stream(chunkMs: Double = 100, realtime: Bool = true) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard let track = tracks.first else { throw AudioFileError.noAudioTrack }

                    let reader = try AVAssetReader(asset: asset)
                    let outputSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 16000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false,
                        AVLinearPCMIsBigEndianKey: false,
                    ]
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                    reader.add(output)
                    reader.startReading()

                    let samplesPerChunk = Int(16000 * chunkMs / 1000)
                    let chunkDuration = chunkMs / 1000
                    var pending: [Float] = []

                    while let sampleBuffer = output.copyNextSampleBuffer() {
                        try Task.checkCancellation()
                        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                        var length = 0
                        var dataPointer: UnsafeMutablePointer<Int8>?
                        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                                     totalLengthOut: &length, dataPointerOut: &dataPointer)
                        guard let dataPointer else { continue }
                        let floatCount = length / MemoryLayout<Float>.size
                        dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
                            pending.append(contentsOf: UnsafeBufferPointer(start: ptr, count: floatCount))
                        }
                        while pending.count >= samplesPerChunk {
                            let chunk = Array(pending.prefix(samplesPerChunk))
                            pending.removeFirst(samplesPerChunk)
                            continuation.yield(chunk)
                            if realtime {
                                try await Task.sleep(for: .seconds(chunkDuration))
                            }
                        }
                    }
                    if reader.status == .failed {
                        throw reader.error ?? AudioFileError.noAudioTrack
                    }
                    if !pending.isEmpty {
                        continuation.yield(pending)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
