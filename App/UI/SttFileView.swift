import SwiftUI
import UniformTypeIdentifiers

/// The [stt] tab: import an mp3/wav (or any AVFoundation-readable file) and see
/// its transcript with timestamps, switchable between sentence-level (default)
/// and per-word granularity.
struct SttFileView: View {
    var engine: ConversationEngine
    @State private var granularity: Granularity = .sentence

    enum Granularity: String, CaseIterable, Identifiable {
        case sentence = "Sentence"
        case word = "Word"
        var id: String { rawValue }
    }

    private var sentences: [TranscriptSentence] {
        TranscriptSegmenter.sentences(from: engine.timestampedWords, frameSec: engine.timestampFrameSec)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 500)
    }

    private var header: some View {
        HStack {
            Text("Speech → Text")
                .font(.headline)
            Spacer()
            Picker("", selection: $granularity) {
                ForEach(Granularity.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .disabled(engine.timestampedWords.isEmpty)

            Button("Transcribe File…") { pickFile() }
                .disabled(!engine.isReady || engine.isProcessing)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if engine.state == .listening {
            VStack(spacing: 12) {
                ProgressView()
                Text("Transcribing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .error(let msg) = engine.state {
            message(msg, isError: true)
        } else if engine.timestampedWords.isEmpty {
            message("Choose an mp3 or wav file to transcribe.", isError: false)
        } else {
            ScrollView {
                switch granularity {
                case .sentence: sentenceList
                case .word: wordList
                }
            }
        }
    }

    private var sentenceList: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(sentences) { sentence in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(timecode(sentence.start)) – \(timecode(sentence.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(sentence.text)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private var wordList: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(engine.timestampedWords.enumerated()), id: \.offset) { _, word in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(secs(word.start)) – \(secs(word.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(word.text)
                        .textSelection(.enabled)
                    Spacer()
                    Text(String(format: "%.0f%%", word.confidence * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
    }

    private func message(_ text: String, isError: Bool) -> some View {
        Text(text)
            .foregroundStyle(isError ? .red : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    // Uses NSOpenPanel (not SwiftUI's .fileImporter) to match the rest of this
    // AppKit-hosted app: its panel-selected URLs are authorized for the process
    // by the sandbox's user-selected read-only entitlement, so the engine can
    // read them directly — no security-scoped copy needed. This is the same
    // pattern ConversationView's Transcribe/Dictate buttons use.
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        if panel.runModal() == .OK, let url = panel.url {
            engine.transcribeFileTimestamped(url)
        }
    }

    /// mm:ss for sentence bounds.
    private func timecode(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    /// Seconds with 2 decimals for per-word bounds.
    private func secs(_ t: Double) -> String {
        String(format: "%.2fs", t)
    }
}

#Preview {
    SttFileView(engine: ConversationEngine())
}
