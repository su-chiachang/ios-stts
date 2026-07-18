import Foundation

/// Keeps sentence synthesis and scheduling ordered without making the LLM
/// stream wait for playback. `QwenTts` remains the serialization point for its
/// native, non-thread-safe handle.
actor SpeechPipeline {
    private let tts: QwenTts
    private let player: AudioPlayer
    /// When set, sentences are synthesized in this reference voice (see
    /// `QwenTts.synthesize(referenceWavPath:)`); nil uses the default voice.
    private let referenceWavPath: String?
    private var tail: Task<Void, Error>?

    init(tts: QwenTts, player: AudioPlayer, referenceWavPath: String? = nil) {
        self.tts = tts
        self.player = player
        self.referenceWavPath = referenceWavPath
    }

    func enqueue(_ sentence: String) {
        let predecessor = tail
        tail = Task {
            if let predecessor { try await predecessor.value }
            try Task.checkCancellation()
            let audio = try await tts.synthesize(sentence,
                                                 language: LanguageDetect.spokenLanguage(for: sentence),
                                                 referenceWavPath: referenceWavPath)
            try Task.checkCancellation()
            try await player.enqueue(audio)
        }
    }

    func finish() async throws {
        try await tail?.value
        await player.waitUntilFinished()
    }

    func cancel() async {
        tail?.cancel()
        tail = nil
        await player.stopAndFlush()
    }
}
