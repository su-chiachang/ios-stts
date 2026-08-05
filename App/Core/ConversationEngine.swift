import Foundation

enum ConversationState: Equatable {
    case loadingModels
    case idle
    case listening
    case thinking
    case speaking
    case error(String)
}

private enum ConversationModelLoadError: Error, LocalizedError {
    case stt(String)
    case tts(String)

    var errorDescription: String? {
        switch self {
        case .stt(let message), .tts(let message): message
        }
    }
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
    typealias SttModelLoader = @MainActor (AppSettings) async throws -> any SttEngine
    typealias TtsModelLoader = @MainActor (AppSettings) throws -> any TtsEngine

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

    private var stt: (any SttEngine)?
    private var tts: (any TtsEngine)?
    private var turnTask: Task<Void, Never>?
    private var audioPlayer: AudioPlayer?
    private var speechPipeline: SpeechPipeline?
    private var activeTurnID: UUID?
    private var activeInput: TurnInput?
    private var audioInput: AudioInputManager?
    private var sourceMediaPlayer: SourceMediaPlayer?
    private var pendingCancellation: Task<Void, Never>?
    private(set) var inputRMS: Float = 0

    private let sttLoader: SttModelLoader
    private let ttsLoader: TtsModelLoader

    init(
        sttLoader: @escaping SttModelLoader = ConversationEngine.defaultSttModel,
        ttsLoader: @escaping TtsModelLoader = ConversationEngine.defaultTtsModel
    ) {
        self.sttLoader = sttLoader
        self.ttsLoader = ttsLoader
    }

    /// Both native models loaded at once pushed resident memory past the OS
    /// jetsam limit on-device (fine on macOS, which has no equivalent
    /// ceiling). Full validation from Settings still needs both; routine tab
    /// navigation should only ever pay for what that tab actually uses.
    func loadModels() async {
        await cancelCurrentTurnAndWait()
        state = .loadingModels
        stt = nil
        tts = nil
        let settings = AppSettings.shared
        do {
            // Construct both selected engines off to the side. Publishing the
            // pair only after both loaders succeed prevents a failed TTS
            // switch from leaving a newly loaded STT engine visible as a
            // partially ready model set.
            let loadedStt = try await sttLoader(settings)
            let loadedTts = try ttsLoader(settings)
            stt = loadedStt
            tts = loadedTts
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    static func defaultSttModel(_ settings: AppSettings) async throws -> any SttEngine {
        switch settings.sttBackend {
        case .parakeet:
            guard let parakeetURL = settings.parakeetModelURL() else {
                throw ConversationModelLoadError.stt(
                    "Parakeet STT is not ready. Pick a parakeet .gguf file in Settings or download a Parakeet asset.")
            }
            return try ParakeetStt(modelPath: parakeetURL.path)
        case .appleSpeech:
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw ConversationModelLoadError.stt(
                    "Apple Speech requires iOS 26 or macOS 26. Select Parakeet in Settings on this OS.")
            }
            return try await AppleSpeechStt.make(localeIdentifier: settings.sttLocale)
        }
    }

    static func defaultTtsModel(_ settings: AppSettings) throws -> any TtsEngine {
        switch settings.ttsBackend {
        case .qwen:
            guard let qwenDirURL = settings.qwenModelDirURL() else {
                throw ConversationModelLoadError.tts(
                    "Qwen TTS is not ready. Pick the qwen3-tts model folder in Settings or download a Qwen asset.")
            }
            return try QwenTts(modelDir: qwenDirURL.path,
                               variant: settings.qwenModelVariant,
                               quantization: settings.qwenModelQuantization)
        case .audio8:
            if let memoryMessage = settings.audio8MemoryCompatibilityMessage() {
                throw ConversationModelLoadError.tts(memoryMessage)
            }
            guard let resources = settings.audio8ModelResources() else {
                throw ConversationModelLoadError.tts(settings.audio8ModelReadinessMessage())
            }
            return try Audio8Tts(generatorURL: resources.generatorURL,
                                 codecURL: resources.codecURL,
                                 tokenizerURL: resources.tokenizerURL,
                                 expectedExportDtype: settings.audio8TtsVariant.exportDtype)
        }
    }

    enum ModelScope { case stt, tts, both }

    /// Loads whichever model(s) `scope` needs and drops the other, so only
    /// one tab's worth of native models is ever resident at a time (the
    /// [stts] tab is the one exception — it genuinely needs both, since a
    /// spoken turn goes mic → STT → LLM → TTS). Called when the active tab
    /// changes; see `RootTabView`.
    func activate(_ scope: ModelScope) async {
        await cancelCurrentTurnAndWait()
        let needsSTT = scope == .stt || scope == .both
        let needsTTS = scope == .tts || scope == .both
        if !needsSTT { stt = nil }
        if !needsTTS { tts = nil }

        // Unconditional, not just when a load is about to happen: cancelling
        // above doesn't touch `state`, so a mid-turn tab switch would
        // otherwise leave `state` stuck on .listening/.thinking/.speaking
        // (isProcessing == true forever) or on a stale .error from whatever
        // the previous tab was doing.
        let needsLoad = (needsSTT && stt == nil) || (needsTTS && tts == nil)
        state = needsLoad ? .loadingModels : .idle
        let settings = AppSettings.shared
        var loadedStt = stt
        var loadedTts = tts
        do {
            if needsSTT && loadedStt == nil {
                loadedStt = try await sttLoader(settings)
            }
            if needsTTS && loadedTts == nil {
                loadedTts = try ttsLoader(settings)
            }
            stt = loadedStt
            tts = loadedTts
        } catch {
            state = .error(error.localizedDescription)
            return
        }
        if state == .loadingModels { state = .idle }
    }

    var isSTTReady: Bool { stt != nil }
    var isTTSReady: Bool { tts != nil }
    var isReady: Bool { isSTTReady && isTTSReady }
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

        let accessingScope = url.startAccessingSecurityScopedResource()
        turnTask = Task {
            defer { if accessingScope { url.stopAccessingSecurityScopedResource() } }
            do {
                await waitForPendingCancellation()
                try Task.checkCancellation()
                guard isCurrentTurn(turnID) else { throw CancellationError() }
                try await stt.beginTurn(lang: AppSettings.shared.sttLocale)
                let canEndTurnWithoutTranscript = await stt.canEndTurnWithoutTranscript
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
                    applySttUpdate(result.textUpdate)
                    if endpoint.process(chunk, modelEOU: result.eou,
                                        hasTranscript: !partialTranscript.isEmpty
                                            || canEndTurnWithoutTranscript) {
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
        guard let stt else {
            state = .error("STT model is not loaded. Pick a parakeet .gguf file in Settings.")
            return
        }
        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .file
        partialTranscript = ""
        state = .listening

        let accessingScope = url.startAccessingSecurityScopedResource()
        turnTask = Task {
            defer { if accessingScope { url.stopAccessingSecurityScopedResource() } }
            do {
                await waitForPendingCancellation()
                try Task.checkCancellation()
                guard isCurrentTurn(turnID) else { throw CancellationError() }
                try await stt.beginTurn(lang: AppSettings.shared.sttLocale)
                let source = AudioFileInput(url: url)
                for try await chunk in source.stream() {
                    try Task.checkCancellation()
                    let result = try await stt.feed(chunk)
                    guard isCurrentTurn(turnID) else { return }
                    applySttUpdate(result.textUpdate)
                }
                let finalUpdate = try await stt.endTurn()
                guard isCurrentTurn(turnID) else { return }
                applySttUpdate(finalUpdate)
                let finalText = partialTranscript
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

    /// Surfaces a failure from outside the turn state machine (e.g. a failed
    /// file pick) through the same `.error` state every other failure here
    /// uses, so it shows up in the usual status banner.
    func reportError(_ message: String) {
        state = .error(message)
    }

    /// Transcribes a whole audio file to per-word timestamps for the [stt] tab
    /// (STT only — no LLM, no playback). Decodes the entire clip to 16 kHz mono
    /// PCM, then runs the batched timestamp path. Results land in
    /// `timestampedWords` / `timestampFrameSec`.
    func transcribeFileTimestamped(_ url: URL) {
        guard let stt else {
            state = .error("STT model is not loaded. Pick a parakeet .gguf file in Settings.")
            return
        }
        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .file
        timestampedWords = []
        timestampFrameSec = 0
        state = .listening

        let accessingScope = url.startAccessingSecurityScopedResource()
        turnTask = Task {
            defer { if accessingScope { url.stopAccessingSecurityScopedResource() } }
            do {
                await waitForPendingCancellation()
                try Task.checkCancellation()
                guard isCurrentTurn(turnID) else { throw CancellationError() }
                var samples: [Float] = []
                for try await chunk in AudioFileInput(url: url).stream(realtime: false) {
                    try Task.checkCancellation()
                    samples.append(contentsOf: chunk)
                }
                // Parakeet can auto-detect a file language. Apple Speech is
                // locale-bound, so pass the loaded locale explicitly there.
                let fileLanguage = AppSettings.shared.sttBackend == .appleSpeech
                    ? AppSettings.shared.sttLocale
                    : nil
                let result = try await stt.transcribeFileWords(pcm: samples, lang: fileLanguage)
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
            await waitForPendingCancellation()
            guard isCurrentTurn(turnID) else { return }
            guard await AudioInputManager.requestPermission() else {
                finishTurn(turnID, with: .error("Microphone permission is required. Enable it in System Settings, then try again."))
                return
            }
            guard let stt, isCurrentTurn(turnID) else { return }
            do {
                try await stt.beginTurn(lang: AppSettings.shared.sttLocale)
                let canEndTurnWithoutTranscript = await stt.canEndTurnWithoutTranscript
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
                    applySttUpdate(result.textUpdate)
                    if endpoint.process(chunk.samples, modelEOU: result.eou,
                                        hasTranscript: !partialTranscript.isEmpty
                                            || canEndTurnWithoutTranscript) {
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
                await waitForPendingCancellation()
                try Task.checkCancellation()
                guard isCurrentTurn(turnID) else { throw CancellationError() }
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
        guard !text.isEmpty, isTTSReady, !isProcessing else { return false }

        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .text
        bubbles.append(ChatBubble(role: .user, text: text))
        state = .speaking
        let settings = AppSettings.shared
        turnTask = Task {
            do {
                await waitForPendingCancellation()
                try Task.checkCancellation()
                guard isCurrentTurn(turnID) else { throw CancellationError() }
                try await readAloud(text, turnID: turnID,
                                    referenceWavPath: settings.customVoiceReferenceURL()?.path,
                                    referenceTranscript: settings.ttsBackend == .audio8
                                        ? settings.audio8ReferenceTranscript
                                        : nil)
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
    func speak(_ text: String, referenceWavPath: String?, referenceTranscript: String? = nil,
               speaker: String? = nil, instruction: String? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isTTSReady, !isProcessing else { return false }

        cancelCurrentTurn()
        let turnID = UUID()
        activeTurnID = turnID
        activeInput = .text
        state = .speaking
        turnTask = Task {
            do {
                await waitForPendingCancellation()
                try Task.checkCancellation()
                guard isCurrentTurn(turnID) else { throw CancellationError() }
                try await readAloud(text, turnID: turnID, referenceWavPath: referenceWavPath,
                                    referenceTranscript: referenceTranscript,
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
            throw TtsEngineError.notLoaded
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
                           referenceTranscript: String? = nil,
                           speaker: String? = nil, instruction: String? = nil) async throws {
        guard let tts else {
            throw TtsEngineError.notLoaded
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
                                      referenceTranscript: referenceTranscript,
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

    private func applySttUpdate(_ update: SttTextUpdate) {
        partialTranscript = update.applying(to: partialTranscript)
    }

    private func finalizeSttTurn(_ stt: any SttEngine, turnID: UUID) async throws {
        let finalUpdate = try await stt.endTurn()
        guard isCurrentTurn(turnID) else { return }
        applySttUpdate(finalUpdate)
        let finalText = partialTranscript
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
        audioPlayer?.stopAndFlush()
        let predecessor = pendingCancellation
        pendingCancellation = Task { @MainActor in
            _ = await predecessor?.result
            if let pipeline { await pipeline.cancel() }
        }
    }

    /// Cancellation is normally fire-and-forget so UI actions remain
    /// synchronous. Model reload is different: the old pipeline and native
    /// runtime must be quiescent before the selected backend is replaced.
    private func cancelCurrentTurnAndWait() async {
        let task = turnTask
        task?.cancel()
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
        let predecessor = pendingCancellation
        pendingCancellation = nil
        _ = await predecessor?.result
        if let pipeline {
            await pipeline.cancel()
        } else {
            audioPlayer?.stopAndFlush()
        }
        _ = await task?.result
    }

    /// A synchronous UI action can request cancellation while the actor-based
    /// pipeline is still unwinding. New work waits for that cancellation task
    /// so its final flush cannot clear the next utterance's audio.
    private func waitForPendingCancellation() async {
        _ = await pendingCancellation?.result
    }
}

private enum TurnInput {
    case file
    case microphone
    case text
}
