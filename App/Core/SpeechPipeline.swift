import Foundation

/// Keeps sentence synthesis and scheduling ordered without making the LLM
/// stream wait for playback. Each backend actor remains the serialization
/// point for its native, non-thread-safe handle.
actor SpeechPipeline {
    private let tts: any TtsEngine
    private let player: AudioPlayer
    /// When set, sentences are synthesized in this reference voice (see
    /// the selected backend's reference-audio contract); nil uses its default.
    private let referenceWavPath: String?
    private let referenceTranscript: String?
    private let speaker: String?
    private let instruction: String?
    private var tail: Task<Void, Error>?

    init(tts: any TtsEngine, player: AudioPlayer, referenceWavPath: String? = nil,
         referenceTranscript: String? = nil,
         speaker: String? = nil, instruction: String? = nil) {
        self.tts = tts
        self.player = player
        self.referenceWavPath = referenceWavPath
        self.referenceTranscript = referenceTranscript
        self.speaker = speaker
        self.instruction = instruction
    }

    func enqueue(_ sentence: String) {
        let predecessor = tail
        tail = Task {
            if let predecessor { try await predecessor.value }
            try Task.checkCancellation()
            let audio = try await tts.synthesize(sentence,
                                                 language: LanguageDetect.spokenLanguage(for: sentence),
                                                 referenceWavPath: referenceWavPath,
                                                 referenceTranscript: referenceTranscript,
                                                 speaker: speaker,
                                                 instruction: instruction,
                                                 maxAudioTokens: 1200)
            try Task.checkCancellation()
            try await player.enqueue(audio)
        }
    }

    func finish() async throws {
        try await tail?.value
        await player.waitUntilFinished()
    }

    func cancel() async {
        let pending = tail
        pending?.cancel()
        tail = nil
        await player.stopAndFlush()
        _ = await pending?.result
        // A synthesis task can finish between the first flush and its
        // cancellation check. Flush once more after it has fully exited so a
        // reload cannot leave audio from the previous backend queued.
        await player.stopAndFlush()
    }
}
