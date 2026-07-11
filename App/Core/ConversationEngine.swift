import Foundation

enum ConversationState: Equatable {
    case loadingModels
    case idle
    case listening
    case thinking
    case speaking
    case error(String)
}

struct ChatBubble: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Owns the two native engines and the conversation state machine. File input
/// follows the same STT/endpoint/LLM path that live mic input will use in M6.
@MainActor
@Observable
final class ConversationEngine {
    private(set) var state: ConversationState = .loadingModels
    private(set) var bubbles: [ChatBubble] = []
    private(set) var partialTranscript: String = ""

    private var stt: ParakeetStt?
    private var tts: QwenTts?
    private var turnTask: Task<Void, Never>?
    private var audioPlayer: AudioPlayer?
    private var speechPipeline: SpeechPipeline?

    func loadModels() async {
        state = .loadingModels
        guard let parakeetURL = AppSettings.shared.parakeetModelURL() else {
            state = .error("No STT model selected. Pick a parakeet .gguf file in Settings.")
            return
        }
        guard let qwenDirURL = AppSettings.shared.qwenModelDirURL() else {
            state = .error("No TTS model directory selected. Pick the qwen3-tts model folder in Settings.")
            return
        }
        do {
            stt = try ParakeetStt(modelPath: parakeetURL.path)
            tts = try QwenTts(modelDir: qwenDirURL.path)
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    var isReady: Bool { stt != nil && tts != nil }

    /// Streams the file's audio track through the STT actor exactly like a
    /// live mic turn will (beginTurn → repeated feed → endTurn), publishing
    /// incrementally finalized text to `partialTranscript` as it arrives.
    func transcribeFile(_ url: URL) {
        guard let stt else {
            state = .error("STT model not loaded.")
            return
        }
        turnTask?.cancel()
        if let speechPipeline {
            Task { await speechPipeline.cancel() }
        }
        partialTranscript = ""
        state = .listening

        turnTask = Task {
            do {
                try await stt.beginTurn(lang: AppSettings.shared.sttLocale)
                let source = AudioFileInput(url: url)
                var endpoint = EndpointDetector(rmsThreshold: AppSettings.shared.rmsThreshold,
                                                silenceHangMs: AppSettings.shared.silenceHangMs)
                for try await chunk in source.stream() {
                    try Task.checkCancellation()
                    let result = try await stt.feed(chunk)
                    if !result.newText.isEmpty {
                        partialTranscript += result.newText
                    }
                    if endpoint.process(chunk, modelEOU: result.eou,
                                        hasTranscript: !partialTranscript.isEmpty) {
                        break
                    }
                }
                let tail = try await stt.endTurn()
                let finalText = (partialTranscript + tail)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                partialTranscript = ""
                if !finalText.isEmpty {
                    bubbles.append(ChatBubble(role: .user, text: finalText))
                    try await requestAssistantReply()
                } else {
                    state = .idle
                }
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func requestAssistantReply() async throws {
        guard let tts else {
            throw QwenTtsError.synthesizeFailed("TTS model not loaded.")
        }
        let settings = AppSettings.shared
        let client = try OpenAIChatClient(baseURL: settings.llmBaseURL,
                                          apiKey: settings.llmAPIKey,
                                          model: settings.llmModel)
        let messages = [OpenAIChatClient.Message(role: .system, content: settings.systemPrompt)]
            + bubbles.map { bubble in
                OpenAIChatClient.Message(role: bubble.role == .user ? .user : .assistant,
                                         content: bubble.text)
            }
        let assistantID = UUID()
        bubbles.append(ChatBubble(id: assistantID, role: .assistant, text: ""))
        state = .thinking
        let player: AudioPlayer
        if let audioPlayer {
            player = audioPlayer
        } else {
            let newPlayer = try AudioPlayer()
            audioPlayer = newPlayer
            player = newPlayer
        }
        let pipeline = SpeechPipeline(tts: tts, player: player)
        speechPipeline = pipeline
        defer { speechPipeline = nil }
        var chunker = SentenceChunker()

        for try await fragment in client.streamChat(messages: messages) {
            try Task.checkCancellation()
            guard let index = bubbles.firstIndex(where: { $0.id == assistantID }) else { continue }
            bubbles[index].text += fragment
            for sentence in chunker.append(fragment) {
                await pipeline.enqueue(sentence)
                state = .speaking
            }
        }
        for sentence in chunker.finish() {
            await pipeline.enqueue(sentence)
            state = .speaking
        }
        if let index = bubbles.firstIndex(where: { $0.id == assistantID }), bubbles[index].text.isEmpty {
            bubbles.remove(at: index)
        }
        try await pipeline.finish()
        state = .idle
    }
}
