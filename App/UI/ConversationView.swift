import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    var engine: ConversationEngine
    var settings = AppSettings.shared
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(engine.bubbles) { bubble in
                        BubbleView(bubble: bubble)
                    }
                    if !engine.partialTranscript.isEmpty {
                        BubbleView(bubble: ChatBubble(role: .user, text: engine.partialTranscript))
                            .opacity(0.5)
                    }
                    if engine.state == .thinking,
                       engine.bubbles.last?.role == .assistant,
                       engine.bubbles.last?.text.isEmpty == true {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 12)
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Text(stateLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if engine.state == .listening {
                    Text("RMS \(engine.inputRMS, specifier: "%.3f")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if case .error = engine.state {
                    Button("Reload Models") {
                        Task { await engine.loadModels() }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            composer
        }
        .frame(minWidth: 420, minHeight: 500)
        .onChange(of: engine.dictatedText) { _, text in
            guard !text.isEmpty else { return }
            draft = draft.isEmpty ? text : draft + " " + text
            engine.clearDictatedText()
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text("STTS")
                .font(.headline)
            Spacer()
            Button("Stop") { engine.stop() }
                .disabled(!engine.isProcessing)
            Button("Reset") { engine.resetConversation() }
                .disabled(engine.bubbles.isEmpty && engine.partialTranscript.isEmpty && !engine.isProcessing)
            Button("Transcribe File…") { pickFile() }
                .disabled(!engine.isReady || engine.isProcessing)
        }
        .padding()
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        if panel.runModal() == .OK, let url = panel.url {
            engine.transcribeFile(url)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 40, maxHeight: 110)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .disabled(!engine.isReady || engine.isProcessing)
                // Return sends (or reads aloud); Shift+Return inserts a newline.
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return, !press.modifiers.contains(.shift) else {
                        return .ignored
                    }
                    sendDraft()
                    return .handled
                }

            Button(action: dictateFromFile) {
                Image(systemName: "doc.badge.plus")
            }
            .help("Dictate: transcribe an audio file into the message box")
            .disabled(!engine.isReady || engine.isProcessing)

            Toggle(isOn: Binding(get: { settings.readAloudMode },
                                 set: { settings.readAloudMode = $0 })) {
                Image(systemName: "waveform")
            }
            .toggleStyle(.button)
            .help(readAloudHelp)

            Button(action: toggleMicrophone) {
                Image(systemName: engine.state == .listening ? "stop.fill" : "mic.fill")
            }
            .help(engine.state == .listening ? "Stop listening" : "Start voice input")
            .disabled(!canControlMicrophone)

            Button(action: sendDraft) {
                Image(systemName: settings.readAloudMode ? "speaker.wave.2.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .help(settings.readAloudMode ? "Read aloud in my voice" : "Send message")
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || !engine.isReady || engine.isProcessing)
        }
        .padding()
    }

    private var readAloudHelp: String {
        let voice = settings.customVoiceName.isEmpty ? "default voice" : settings.customVoiceName
        return "Read-aloud mode: speak typed text verbatim in the custom voice (\(voice)) instead of asking the assistant"
    }

    private var canControlMicrophone: Bool {
        engine.isReady && (!engine.isProcessing || engine.state == .listening)
    }

    private func sendDraft() {
        let handled = settings.readAloudMode ? engine.speakText(draft) : engine.sendText(draft)
        if handled { draft = "" }
    }

    private func dictateFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        if panel.runModal() == .OK, let url = panel.url {
            engine.dictateFile(url)
        }
    }

    private func toggleMicrophone() {
        if engine.state == .listening {
            engine.stop()
        } else {
            engine.startListening()
        }
    }

    private var stateLabel: String {
        switch engine.state {
        case .loadingModels: "Loading models…"
        case .idle: "Ready"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: "Speaking…"
        case .error(let msg): "Error: \(msg)"
        }
    }

    private var stateColor: Color {
        switch engine.state {
        case .loadingModels: .yellow
        case .idle: .gray
        case .listening: .green
        case .thinking: .blue
        case .speaking: .purple
        case .error: .red
        }
    }
}

private struct BubbleView: View {
    let bubble: ChatBubble

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if bubble.role == .assistant {
                Image(systemName: "person.crop.circle.badge.sparkles")
                    .font(.title2)
                    .foregroundStyle(.purple)
            } else {
                Spacer(minLength: 40)
            }
            Text(bubble.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubble.role == .user ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if bubble.role == .user {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
            } else {
                Spacer(minLength: 40)
            }
        }
    }
}

#Preview {
    ConversationView(engine: ConversationEngine())
}
