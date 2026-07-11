import AVFoundation

enum AudioPlayerError: LocalizedError {
    case invalidAudioBuffer

    var errorDescription: String? {
        switch self {
        case .invalidAudioBuffer: "Unable to create an audio buffer for TTS output."
        }
    }
}

/// Serializes AVAudioPlayerNode scheduling while the audio engine performs
/// playback independently. This lets the next full-sentence TTS synthesis run
/// while the preceding buffer is audible.
@MainActor
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var pendingBuffers = 0
    private var playbackGeneration = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init() throws {
        engine.attach(player)
        // Qwen returns 24 kHz mono. Connecting the node with that explicit
        // format lets the mixer, rather than the player node, adapt to a
        // stereo or differently-clocked hardware output.
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        try engine.start()
    }

    func enqueue(_ chunk: QwenTts.Chunk) throws {
        guard !chunk.samples.isEmpty,
              chunk.sampleRate == playbackFormat.sampleRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                             frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let destination = buffer.floatChannelData?[0] else {
            throw AudioPlayerError.invalidAudioBuffer
        }

        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: chunk.samples.count)
        }
        if !engine.isRunning { try engine.start() }

        pendingBuffers += 1
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.didFinishBuffer(generation: generation)
            }
        }
        if !player.isPlaying { player.play() }
    }

    func waitUntilFinished() async {
        guard pendingBuffers > 0 else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func stopAndFlush() {
        playbackGeneration += 1
        player.stop()
        pendingBuffers = 0
        resumeIdleWaiters()
    }

    private func didFinishBuffer(generation: Int) {
        guard generation == playbackGeneration else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        if pendingBuffers == 0 { resumeIdleWaiters() }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
