import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    var engine: ConversationEngine

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
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 420, minHeight: 500)
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text("STTS")
                .font(.headline)
            Spacer()
            Button("Transcribe File…") { pickFile() }
                .disabled(!engine.isReady)
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

    private var stateLabel: String {
        switch engine.state {
        case .loadingModels: "Loading models…"
        case .idle: "Idle"
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
        HStack {
            if bubble.role == .assistant { Spacer(minLength: 40) }
            Text(bubble.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubble.role == .user ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if bubble.role == .user { Spacer(minLength: 40) }
        }
    }
}

#Preview {
    ConversationView(engine: ConversationEngine())
}
