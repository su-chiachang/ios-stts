import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    var engine: ConversationEngine
    var settings = AppSettings.shared
    @State private var draft = ""
    #if os(iOS)
    @State private var showTranscribePicker = false
    @State private var showDictatePicker = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            statusBanner
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(engine.bubbles) { bubble in
                            BubbleView(bubble: bubble).id(bubble.id)
                        }
                        if !engine.partialTranscript.isEmpty {
                            BubbleView(bubble: ChatBubble(role: .user, text: engine.partialTranscript))
                                .opacity(0.5)
                        }
                        if engine.state == .thinking,
                           engine.bubbles.last?.role == .assistant,
                           engine.bubbles.last?.text.isEmpty == true {
                            TypingIndicator()
                        }
                    }
                    .padding()
                }
                .onChange(of: engine.bubbles.last?.text) { _, _ in
                    guard let last = engine.bubbles.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            composer
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 500)
        #endif
        .onChange(of: engine.dictatedText) { _, text in
            guard !text.isEmpty else { return }
            draft = draft.isEmpty ? text : draft + " " + text
            engine.clearDictatedText()
        }
        #if os(iOS)
        .fileImporter(isPresented: $showTranscribePicker,
                      allowedContentTypes: [.audio, .movie, .mpeg4Movie, .wav, .mp3]) { result in
            if case .success(let url) = result { engine.transcribeFile(url) }
        }
        .fileImporter(isPresented: $showDictatePicker,
                      allowedContentTypes: [.audio, .movie, .mpeg4Movie, .wav, .mp3]) { result in
            if case .success(let url) = result { engine.dictateFile(url) }
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text("STTS")
                .font(.system(.headline, design: .rounded))
            Spacer()

            if engine.isProcessing {
                headerButton("stop.circle", help: "Stop", action: engine.stop)
            }

            Toggle(isOn: Binding(get: { settings.readAloudMode },
                                 set: { settings.readAloudMode = $0 })) {
                Image(systemName: "waveform")
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .help(readAloudHelp)

            headerButton("doc.badge.plus", help: "Transcribe an audio file", action: pickFile)
                .disabled(!engine.isReady || engine.isProcessing)

            headerButton("square.and.pencil", help: "New conversation", action: engine.resetConversation)
                .disabled(engine.bubbles.isEmpty && engine.partialTranscript.isEmpty && !engine.isProcessing)
        }
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func headerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Status banner

    /// Deliberately quiet: only surfaces when there's something the user
    /// can't infer from the message list itself (loading, listening, error).
    /// "Thinking" already shows via the typing indicator in the list.
    private var statusBanner: some View {
        Group {
            if showsStatusBanner {
                HStack(spacing: 6) {
                    Text(stateLabel)
                    if engine.state == .listening {
                        Text("RMS \(engine.inputRMS, specifier: "%.3f")")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if case .error = engine.state {
                        Button("Reload Models") { Task { await engine.loadModels() } }
                            .font(.caption.weight(.semibold))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showsStatusBanner)
    }

    private var showsStatusBanner: Bool {
        switch engine.state {
        case .loadingModels, .listening, .error: true
        case .idle, .thinking, .speaking: false
        }
    }

    private func pickFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        if panel.runModal() == .OK, let url = panel.url {
            engine.transcribeFile(url)
        }
        #else
        showTranscribePicker = true
        #endif
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button(action: dictateFromFile) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!engine.isReady || engine.isProcessing)
            .help("Dictate: transcribe an audio file into the message box")

            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.vertical, 5)
                .disabled(!engine.isReady || engine.isProcessing)
                // Return sends (or reads aloud); Shift+Return inserts a newline.
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return, !press.modifiers.contains(.shift) else {
                        return .ignored
                    }
                    sendDraft()
                    return .handled
                }

            Button(action: toggleMicrophone) {
                Image(systemName: engine.state == .listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(engine.state == .listening ? Color.red : .secondary)
            .disabled(!canControlMicrophone)
            .help(engine.state == .listening ? "Stop listening" : "Start voice input")

            Button(action: sendDraft) {
                Image(systemName: settings.readAloudMode ? "speaker.wave.2.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(canSend ? Color.accentColor : Color.gray.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(settings.readAloudMode ? "Read aloud in my voice" : "Send message")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 10)
        .padding(.top, 6)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && engine.isReady && !engine.isProcessing
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
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        if panel.runModal() == .OK, let url = panel.url {
            engine.dictateFile(url)
        }
        #else
        showDictatePicker = true
        #endif
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
        HStack(spacing: 0) {
            if bubble.role == .user { Spacer(minLength: 56) }
            Text(bubble.text)
                .textSelection(.enabled)
                .padding(.horizontal, bubble.role == .user ? 14 : 0)
                .padding(.vertical, bubble.role == .user ? 10 : 0)
                .background(bubble.role == .user ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: bubble.role == .user ? .trailing : .leading)
    }
}

/// Three-dot "assistant is typing" indicator, left-aligned like an
/// assistant bubble but with no text yet.
private struct TypingIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1 : 0.5)
                    .opacity(animate ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.15),
                               value: animate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animate = true }
    }
}

#Preview {
    ConversationView(engine: ConversationEngine())
}
