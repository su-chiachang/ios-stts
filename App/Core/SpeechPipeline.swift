import Foundation

/// Keeps sentence synthesis and scheduling ordered without making the LLM
/// stream wait for playback. The actor serializes synthesis and playback.
actor SpeechPipeline {
    private let tts: any TtsEngine
    private let player: AudioPlayer
    private var tail: Task<Void, Error>?

    init(tts: any TtsEngine, player: AudioPlayer) {
        self.tts = tts
        self.player = player
    }

    func enqueue(_ sentence: String) {
        let predecessor = tail
        tail = Task {
            if let predecessor { try await predecessor.value }
            try Task.checkCancellation()
            let audio = try await tts.synthesize(sentence,
                                                 language: LanguageDetect.spokenLanguage(for: sentence))
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
        // reload cannot leave audio from the previous turn queued.
        await player.stopAndFlush()
    }
}
