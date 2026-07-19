import AVFoundation
import Foundation

/// Records a short microphone clip (16 kHz mono) and writes it to a temporary
/// WAV suitable for `ReferenceAudioImporter`. The [tts] tab uses it to capture
/// a 3–5 s zero-shot voice-cloning reference on-device, reusing the same mic
/// capture path (`AudioInputManager`) as live transcription.
@MainActor
@Observable
final class VoiceClipRecorder {
    private(set) var isRecording = false
    /// Seconds captured so far (derived from sample count, so it stays exact).
    private(set) var elapsed: Double = 0

    private var manager: AudioInputManager?
    private var task: Task<Void, Never>?
    private var samples: [Float] = []
    private let sampleRate = 16_000.0

    enum RecorderError: LocalizedError {
        case permissionDenied
        case empty

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Microphone permission is required. Enable it in System Settings, then try again."
            case .empty: "No audio was recorded."
            }
        }
    }

    /// Requests mic permission and starts capture, auto-stopping after
    /// `maxSeconds`. Returns false if permission was denied or capture failed.
    @discardableResult
    func start(maxSeconds: Double = 6) async -> Bool {
        guard !isRecording else { return true }
        guard await AudioInputManager.requestPermission() else { return false }

        let manager = AudioInputManager()
        self.manager = manager
        samples.removeAll(keepingCapacity: true)
        elapsed = 0
        do {
            let stream = try manager.stream()
            isRecording = true
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        self.samples.append(contentsOf: chunk.samples)
                        self.elapsed = Double(self.samples.count) / self.sampleRate
                        if self.elapsed >= maxSeconds { break }
                    }
                } catch {}
                manager.stop()
                self.isRecording = false
            }
            return true
        } catch {
            self.manager = nil
            isRecording = false
            return false
        }
    }

    /// Stops capture early (the auto-stop timeout also ends recording).
    func stop() {
        task?.cancel()
        manager?.stop()
        isRecording = false
    }

    /// Writes the captured audio to a temp 16 kHz mono 16-bit WAV and returns
    /// its URL. `ReferenceAudioImporter` resamples it to the encoder's 24 kHz.
    func writeWav() throws -> URL {
        guard !samples.isEmpty else { throw RecorderError.empty }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clip-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw RecorderError.empty
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        return url
    }
}
