import SwiftUI

/// The [tts] tab: type text and hear it spoken with Apple's system voice.
@MainActor
struct TtsView: View {
    @State private var tts: TtsApple
    @State private var player: AudioPlayer?
    @State private var speechTask: Task<Void, Never>?
    @State private var text = "Hello world"
    @State private var message: String?
    @State private var isError = false
    @State private var isSpeaking = false
    @State private var activeRequestID: UUID?

    init(tts: TtsApple = TtsApple()) {
        _tts = State(initialValue: tts)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Voice") {
                    Label("Apple: language-matched system voice", systemImage: "waveform")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Apple TTS uses the system voice for the detected language and needs no downloaded model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox("Text") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $text)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80, maxHeight: 160)
                            .padding(6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        HStack {
                            Spacer()
                            Button("Stop") { stop() }
                                .disabled(!isSpeaking)
                            Button {
                                speak()
                            } label: {
                                Label("Speak", systemImage: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSpeak)
                        }
                    }
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .onDisappear { stop() }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 500)
        #endif
    }

    private var canSpeak: Bool {
        !isSpeaking
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func speak() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !isSpeaking else { return }
        message = nil
        isError = false
        do {
            let player = try AudioPlayer()
            self.player = player
            isSpeaking = true
            let requestID = UUID()
            activeRequestID = requestID

            speechTask = Task { @MainActor in
                do {
                    let audio = try await tts.synthesize(
                        trimmedText,
                        language: LanguageDetect.spokenLanguage(for: trimmedText))
                    try Task.checkCancellation()
                    try player.enqueue(audio)
                    await player.waitUntilFinished()
                    guard activeRequestID == requestID else { return }
                    isSpeaking = false
                    self.player = nil
                    activeRequestID = nil
                    speechTask = nil
                } catch is CancellationError {
                    player.stopAndFlush()
                    guard activeRequestID == requestID else { return }
                    isSpeaking = false
                    self.player = nil
                    activeRequestID = nil
                    speechTask = nil
                } catch {
                    player.stopAndFlush()
                    guard activeRequestID == requestID else { return }
                    isSpeaking = false
                    self.player = nil
                    activeRequestID = nil
                    speechTask = nil
                    message = error.localizedDescription
                    isError = true
                }
            }
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func stop() {
        speechTask?.cancel()
        speechTask = nil
        player?.stopAndFlush()
        player = nil
        activeRequestID = nil
        isSpeaking = false
    }
}

#Preview {
    TtsView()
}
