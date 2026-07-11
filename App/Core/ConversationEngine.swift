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
    let id = UUID()
    let role: Role
    var text: String
}

/// Owns the two native engines and the conversation state machine. M2 scope:
/// load both models, transcribe an audio/video file end-to-end through the
/// same streaming STT path live mic input will use later (M6). LLM
/// round-trip and TTS playback are wired in M3-M4.
@MainActor
@Observable
final class ConversationEngine {
    private(set) var state: ConversationState = .loadingModels
    private(set) var bubbles: [ChatBubble] = []
    private(set) var partialTranscript: String = ""

    private var stt: ParakeetStt?
    private var tts: QwenTts?
    private var transcriptionTask: Task<Void, Never>?

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
        transcriptionTask?.cancel()
        partialTranscript = ""
        state = .listening

        transcriptionTask = Task {
            do {
                try await stt.beginTurn(lang: AppSettings.shared.sttLocale)
                let source = AudioFileInput(url: url)
                for try await chunk in source.stream() {
                    try Task.checkCancellation()
                    let result = try await stt.feed(chunk)
                    if !result.newText.isEmpty {
                        partialTranscript += result.newText
                    }
                }
                let tail = try await stt.endTurn()
                let finalText = (partialTranscript + tail)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                partialTranscript = ""
                if !finalText.isEmpty {
                    bubbles.append(ChatBubble(role: .user, text: finalText))
                }
                state = .idle
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}
