@preconcurrency import AVFoundation

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
    /// Keep one stable player-node format while allowing Qwen (24 kHz) and
    /// Audio8 (44.1 kHz) chunks to share the same queue across backend reloads.
    /// The mixer still adapts this mono stream to the hardware output format.
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var pendingBuffers = 0
    private var playbackGeneration = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        try engine.start()
    }

    func enqueue(_ chunk: TtsAudioChunk) throws {
        guard !chunk.samples.isEmpty,
              chunk.sampleRate > 0,
              let buffer = makePlaybackBuffer(from: chunk) else {
            throw AudioPlayerError.invalidAudioBuffer
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

    private func makePlaybackBuffer(from chunk: TtsAudioChunk) -> AVAudioPCMBuffer? {
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate,
                                               channels: 1),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                             frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let sourceChannel = source.floatChannelData?[0] else {
            return nil
        }
        source.frameLength = source.frameCapacity
        chunk.samples.withUnsafeBufferPointer { samples in
            sourceChannel.update(from: samples.baseAddress!, count: chunk.samples.count)
        }
        guard sourceFormat.sampleRate != playbackFormat.sampleRate else { return source }

        let outputCapacity = AVAudioFrameCount(
            (Double(source.frameLength) * playbackFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)
        ) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                            frameCapacity: outputCapacity),
              let converter = AVAudioConverter(from: sourceFormat, to: playbackFormat) else {
            return nil
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
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
