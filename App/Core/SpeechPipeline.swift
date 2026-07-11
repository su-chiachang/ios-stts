import Foundation

/// Keeps sentence synthesis and scheduling ordered without making the LLM
/// stream wait for playback. `QwenTts` remains the serialization point for its
/// native, non-thread-safe handle.
actor SpeechPipeline {
    private let tts: QwenTts
    private let player: AudioPlayer
    private var tail: Task<Void, Error>?

    init(tts: QwenTts, player: AudioPlayer) {
        self.tts = tts
        self.player = player
    }

    func enqueue(_ sentence: String) {
        let predecessor = tail
        tail = Task {
            if let predecessor { try await predecessor.value }
            try Task.checkCancellation()
            let audio = try await tts.synthesize(sentence, language: LanguageDetect.spokenLanguage(for: sentence))
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
