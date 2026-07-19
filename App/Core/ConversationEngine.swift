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
    /// Result of the most recent `dictateFile` (STT-only, no LLM). The composer
    /// picks this up into its draft, then calls `clearDictatedText`.
    private(set) var dictatedText: String = ""
    /// Per-word timestamps from the most recent `transcribeFileTimestamped`
    /// (the [stt] tab). Empty until a file has been processed.
    private(set) var timestampedWords: [TranscriptWord] = []
    /// Encoder frame stride (seconds) that accompanied `timestampedWords`;
    /// used by `TranscriptSegmenter` to scale sentence-gap thresholds.
    private(set) var timestampFrameSec: Double = 0

    private var stt: ParakeetStt?
    private var tts: QwenTts?
    private var turnTask: Task<Void, Never>?
    private var audioPlayer: AudioPlayer?
    private var speechPipeline: SpeechPipeline?
    private var activeTurnID: UUID?
    private var activeInput: TurnInput?
    private var audioInput: AudioInputManager?
    private var sourceMediaPlayer: SourceMediaPlayer?
    private(set) var inputRMS: Float = 0

    func loadModels() async {
        cancelCurrentTurn()
        state = .loadingModels
        stt = nil
        tts = nil
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
            tts = try QwenTts(modelDir: qwenDirURL.path, variant: AppSettings.shared.qwenModelVariant)
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    var isReady: Bool { stt != nil && tts != nil }
    var isProcessing: Bool {
        switch state {
        case .listening, .thinking, .speaking: true
        case .loadingModels, .idle, .error: false
        }
    }

    /// Streams the file's audio track through the STT actor exactly like a
    /// live mic turn will (beginTurn → repeated feed → endTurn), publishing
    /// incrementally finalized text to `partialTranscript` as it arrives.
    func transcribeFile(_ url: URL) {
        guard let stt, isReady else {
            state = .error("Models are not loaded. Choose both model locations in Settings, then reload.")
            return
        }
        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .file
        partialTranscript = ""
        state = .listening

        turnTask = Task {
            do {
                try await stt.beginTurn(lang: AppSettings.shared.sttLocale)
                let sourcePlayer = SourceMediaPlayer()
                sourceMediaPlayer = sourcePlayer
                sourcePlayer.play(url)
                let source = AudioFileInput(url: url)
                var endpoint = EndpointDetector(rmsThreshold: AppSettings.shared.rmsThreshold,
                                                silenceHangMs: AppSettings.shared.silenceHangMs)
                for try await chunk in source.stream() {
                    try Task.checkCancellation()
                    let result = try await stt.feed(chunk)
                    guard isCurrentTurn(turnID) else { return }
                    if !result.newText.isEmpty {
                        partialTranscript += result.newText
                    }
                    if endpoint.process(chunk, modelEOU: result.eou,
                                        hasTranscript: !partialTranscript.isEmpty) {
                        break
                    }
                }
                sourcePlayer.stop()
                if sourceMediaPlayer === sourcePlayer { sourceMediaPlayer = nil }
                try await finalizeSttTurn(stt, turnID: turnID)
            } catch is CancellationError {
                finishTurn(turnID, with: .idle)
            } catch {
                finishTurn(turnID, with: .error(error.localizedDescription))
            }
        }
    }

    /// Transcribes an audio file to text (STT only — no LLM, no TTS) and hands
    /// the result to `dictatedText` for the composer to load into its draft.
    /// Lets the user dictate the message they'll then read aloud in their own
    /// voice instead of typing it. Unlike `transcribeFile`, this consumes the
    /// whole clip (no endpoint cutoff) and never plays it back.
    func dictateFile(_ url: URL) {
        guard let stt, isReady else {
            state = .error("Models are not loaded. Choose both model locations in Settings, then reload.")
            return
        }
        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .file
        partialTranscript = ""
        state = .listening

        turnTask = Task {
            do {
                try await stt.beginTurn(lang: AppSettings.shared.sttLocale)
                let source = AudioFileInput(url: url)
                for try await chunk in source.stream() {
                    try Task.checkCancellation()
                    let result = try await stt.feed(chunk)
                    guard isCurrentTurn(turnID) else { return }
                    if !result.newText.isEmpty {
                        partialTranscript += result.newText
                    }
                }
                let tail = try await stt.endTurn()
                guard isCurrentTurn(turnID) else { return }
                let finalText = (partialTranscript + tail)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                partialTranscript = ""
                dictatedText = finalText
                finishTurn(turnID, with: .idle)
            } catch is CancellationError {
                finishTurn(turnID, with: .idle)
            } catch {
                finishTurn(turnID, with: .error(error.localizedDescription))
            }
        }
    }

    func clearDictatedText() { dictatedText = "" }

    /// Transcribes a whole audio file to per-word timestamps for the [stt] tab
    /// (STT only — no LLM, no playback). Decodes the entire clip to 16 kHz mono
    /// PCM, then runs the batched timestamp path. Results land in
    /// `timestampedWords` / `timestampFrameSec`.
    func transcribeFileTimestamped(_ url: URL) {
        guard let stt, isReady else {
            state = .error("Models are not loaded. Choose both model locations in Settings, then reload.")
            return
        }
        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .file
        timestampedWords = []
        timestampFrameSec = 0
        state = .listening

        turnTask = Task {
            do {
                var samples: [Float] = []
                for try await chunk in AudioFileInput(url: url).stream(realtime: false) {
                    try Task.checkCancellation()
                    samples.append(contentsOf: chunk)
                }
                // Auto-detect language (nil) for file transcription rather than
                // forcing the conversation tab's configured locale onto an
                // arbitrary file: forcing e.g. "en" onto Chinese audio makes the
                // model return zero clips (an empty transcript).
                let result = try await stt.transcribeFileWords(pcm: samples, lang: nil)
                guard isCurrentTurn(turnID) else { return }
                timestampedWords = result.words
                timestampFrameSec = result.frameSec
                if result.words.isEmpty {
                    // Don't fail silently — the [stt] tab would just revert to its
                    // empty prompt, looking like nothing happened. The usual cause
                    // is the wrong STT model (e.g. the EOU model, which can't
                    // transcribe); point the user at Settings.
                    finishTurn(turnID, with: .error("No speech was recognized. Check the STT model in Settings — use nemotron-3.5-asr, not the EOU model."))
                } else {
                    finishTurn(turnID, with: .idle)
                }
            } catch is CancellationError {
                finishTurn(turnID, with: .idle)
            } catch {
                finishTurn(turnID, with: .error(error.localizedDescription))
            }
        }
    }

    /// Starts microphone capture for one spoken turn. When the assistant has
    /// finished speaking, the same source automatically starts the next turn.
    func startListening() {
        guard isReady, !isProcessing else { return }
        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .microphone
        partialTranscript = ""
        inputRMS = 0
        state = .listening

        turnTask = Task {
            guard await AudioInputManager.requestPermission() else {
                finishTurn(turnID, with: .error("Microphone permission is required. Enable it in System Settings, then try again."))
                return
            }
            guard let stt, isCurrentTurn(turnID) else { return }
            do {
                try await stt.beginTurn(lang: AppSettings.shared.sttLocale)
                let input = AudioInputManager()
                audioInput = input
                let stream = try input.stream()
                var endpoint = EndpointDetector(rmsThreshold: AppSettings.shared.rmsThreshold,
                                                silenceHangMs: AppSettings.shared.silenceHangMs)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard isCurrentTurn(turnID) else { return }
                    inputRMS = chunk.rms
                    let result = try await stt.feed(chunk.samples)
                    if !result.newText.isEmpty {
                        partialTranscript += result.newText
                    }
                    if endpoint.process(chunk.samples, modelEOU: result.eou,
                                        hasTranscript: !partialTranscript.isEmpty) {
                        input.stop()
                        break
                    }
                }
                audioInput = nil
                try Task.checkCancellation()
                try await finalizeSttTurn(stt, turnID: turnID)
            } catch is CancellationError {
                finishTurn(turnID, with: .idle)
            } catch {
                finishTurn(turnID, with: .error(error.localizedDescription))
            }
        }
    }

    /// Sends typed text through the same LLM and sentence-level TTS pipeline
    /// as a finalized spoken turn, without starting microphone capture.
    @discardableResult
    func sendText(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isReady, !isProcessing else { return false }

        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .text
        bubbles.append(ChatBubble(role: .user, text: text))
        state = .thinking
        turnTask = Task {
            do {
                try await requestAssistantReply(turnID: turnID)
            } catch is CancellationError {
                finishTurn(turnID, with: .idle)
            } catch {
                finishTurn(turnID, with: .error(error.localizedDescription))
            }
        }
        return true
    }

    /// Reads typed text aloud verbatim in the custom voice, bypassing the LLM —
    /// the "speak as me" path. Falls back to the model's default voice when no
    /// custom voice is imported.
    @discardableResult
    func speakText(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isReady, !isProcessing else { return false }

        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .text
        bubbles.append(ChatBubble(role: .user, text: text))
        state = .speaking
        turnTask = Task {
            do {
                try await readAloud(text, turnID: turnID,
                                    referenceWavPath: AppSettings.shared.customVoiceReferenceURL()?.path)
            } catch is CancellationError {
                finishTurn(turnID, with: .idle)
            } catch {
                finishTurn(turnID, with: .error(error.localizedDescription))
            }
        }
        return true
    }

    /// Synthesizes `text` verbatim for the [tts] tab, without adding a chat
    /// bubble. `referenceWavPath == nil` uses the model's default voice; a path
    /// clones that reference voice.
    @discardableResult
    func speak(_ text: String, referenceWavPath: String?, speaker: String? = nil,
               instruction: String? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isReady, !isProcessing else { return false }

        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .text
        state = .speaking
        turnTask = Task {
            do {
                try await readAloud(text, turnID: turnID, referenceWavPath: referenceWavPath,
                                    speaker: speaker, instruction: instruction)
            } catch is CancellationError {
                finishTurn(turnID, with: .idle)
            } catch {
                finishTurn(turnID, with: .error(error.localizedDescription))
            }
        }
        return true
    }

    /// Pre-extracts the current custom voice's speaker embedding so the first
    /// spoken sentence isn't delayed and import errors surface right away.
    /// No-op when no voice is set or the model isn't loaded yet.
    func warmCustomVoice() async throws {
        guard let tts, let path = AppSettings.shared.customVoiceReferenceURL()?.path else { return }
        try await tts.warmUpVoice(referenceWavPath: path)
    }

    func availablePresetSpeakers() async -> [String] {
        guard let tts else { return [] }
        return await tts.availableSpeakers()
    }

    func stop() {
        cancelCurrentTurn()
        partialTranscript = ""
        inputRMS = 0
        state = .idle
    }

    func resetConversation() {
        stop()
        bubbles.removeAll()
    }

    private func requestAssistantReply(turnID: UUID) async throws {
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
        defer {
            if speechPipeline === pipeline { speechPipeline = nil }
        }
        var chunker = SentenceChunker()

        for try await fragment in client.streamChat(messages: messages) {
            try Task.checkCancellation()
            guard isCurrentTurn(turnID) else { throw CancellationError() }
            guard let index = bubbles.firstIndex(where: { $0.id == assistantID }) else { continue }
            bubbles[index].text += fragment
            for sentence in chunker.append(fragment) {
                await pipeline.enqueue(sentence)
                if isCurrentTurn(turnID) { state = .speaking }
            }
        }
        for sentence in chunker.finish() {
            await pipeline.enqueue(sentence)
            if isCurrentTurn(turnID) { state = .speaking }
        }
        guard isCurrentTurn(turnID) else { throw CancellationError() }
        if let index = bubbles.firstIndex(where: { $0.id == assistantID }), bubbles[index].text.isEmpty {
            bubbles.remove(at: index)
        }
        try await pipeline.finish()
        finishTurn(turnID, with: .idle)
    }

    private func readAloud(_ text: String, turnID: UUID, referenceWavPath: String?,
                           speaker: String? = nil, instruction: String? = nil) async throws {
        guard let tts else {
            throw QwenTtsError.synthesizeFailed("TTS model not loaded.")
        }
        let player: AudioPlayer
        if let audioPlayer {
            player = audioPlayer
        } else {
            let newPlayer = try AudioPlayer()
            audioPlayer = newPlayer
            player = newPlayer
        }
        let pipeline = SpeechPipeline(tts: tts, player: player, referenceWavPath: referenceWavPath,
                                      speaker: speaker, instruction: instruction)
        speechPipeline = pipeline
        defer {
            if speechPipeline === pipeline { speechPipeline = nil }
        }

        var chunker = SentenceChunker()
        var sentences = chunker.append(text)
        sentences += chunker.finish()
        for sentence in sentences {
            guard isCurrentTurn(turnID) else { throw CancellationError() }
            await pipeline.enqueue(sentence)
        }
        guard isCurrentTurn(turnID) else { throw CancellationError() }
        try await pipeline.finish()
        finishTurn(turnID, with: .idle)
    }

    private func isCurrentTurn(_ turnID: UUID) -> Bool {
        activeTurnID == turnID
    }

    private func finalizeSttTurn(_ stt: ParakeetStt, turnID: UUID) async throws {
        let tail = try await stt.endTurn()
        guard isCurrentTurn(turnID) else { return }
        let finalText = (partialTranscript + tail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        partialTranscript = ""
        if !finalText.isEmpty {
            bubbles.append(ChatBubble(role: .user, text: finalText))
            try await requestAssistantReply(turnID: turnID)
        } else {
            finishTurn(turnID, with: .idle)
        }
    }

    private func finishTurn(_ turnID: UUID, with newState: ConversationState) {
        guard isCurrentTurn(turnID) else { return }
        let shouldResumeMicrophone = activeInput == .microphone && newState == .idle
        activeTurnID = nil
        activeInput = nil
        turnTask = nil
        audioInput?.stop()
        audioInput = nil
        sourceMediaPlayer?.stop()
        sourceMediaPlayer = nil
        inputRMS = 0
        state = newState
        if shouldResumeMicrophone {
            Task { @MainActor [weak self] in self?.startListening() }
        }
    }

    private func cancelCurrentTurn() {
        turnTask?.cancel()
        turnTask = nil
        activeTurnID = nil
        activeInput = nil
        audioInput?.stop()
        audioInput = nil
        sourceMediaPlayer?.stop()
        sourceMediaPlayer = nil
        inputRMS = 0
        let pipeline = speechPipeline
        speechPipeline = nil
        if let pipeline {
            Task { await pipeline.cancel() }
        } else if let audioPlayer {
            audioPlayer.stopAndFlush()
        }
    }
}

private enum TurnInput {
    case file
    case microphone
    case text
}
