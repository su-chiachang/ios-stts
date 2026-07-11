import AVFoundation
import Foundation

struct AudioInputChunk: Sendable {
    let samples: [Float]
    let rms: Float
}

enum AudioInputError: LocalizedError {
    case alreadyRunning
    case unavailableInput
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Microphone capture is already running."
        case .unavailableInput: "No microphone input is available."
        case .converterCreationFailed: "Unable to convert microphone audio to 16 kHz mono PCM."
        }
    }
}

/// Captures the system microphone and yields 100 ms, 16 kHz mono Float32
/// chunks. The AVAudioEngine tap may arrive on a realtime audio thread, so the
/// continuation and pending chunk state are protected by a short lock.
final class AudioInputManager: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false)!
    private let samplesPerChunk = 1_600
    private var converter: AVAudioConverter?
    private var continuation: AsyncThrowingStream<AudioInputChunk, Error>.Continuation?
    private var pending: [Float] = []
    private var isRunning = false

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: false
        @unknown default: false
        }
    }

    func stream() throws -> AsyncThrowingStream<AudioInputChunk, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { throw AudioInputError.alreadyRunning }

        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            do {
                try self.startEngine()
            } catch {
                self.continuation = nil
                continuation.finish(throwing: error)
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        pending.removeAll(keepingCapacity: false)
        isRunning = false
        lock.unlock()
        continuation?.finish()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioInputError.unavailableInput
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioInputError.converterCreationFailed
        }
        self.converter = converter
        isRunning = true

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength)
            * targetFormat.sampleRate / buffer.format.sampleRate).advanced(by: 1))
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var suppliedInput = false
        let status = converter.convert(to: converted, error: nil) { _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0,
              let samples = converted.floatChannelData?[0] else { return }
        emit(Array(UnsafeBufferPointer(start: samples, count: Int(converted.frameLength))))
    }

    private func emit(_ samples: [Float]) {
        lock.lock()
        guard isRunning, let continuation else {
            lock.unlock()
            return
        }
        pending.append(contentsOf: samples)
        var chunks: [[Float]] = []
        while pending.count >= samplesPerChunk {
            chunks.append(Array(pending.prefix(samplesPerChunk)))
            pending.removeFirst(samplesPerChunk)
        }
        lock.unlock()

        for chunk in chunks {
            let rms = sqrt(chunk.reduce(Float.zero) { $0 + $1 * $1 } / Float(chunk.count))
            continuation.yield(AudioInputChunk(samples: chunk, rms: rms))
        }
    }
}
