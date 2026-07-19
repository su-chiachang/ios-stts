import SwiftUI
import UniformTypeIdentifiers

/// The [stt] tab: import an mp3/wav (or any AVFoundation-readable file) and see
/// its transcript with timestamps, switchable between sentence-level (default)
/// and per-word granularity.
struct SttFileView: View {
    var engine: ConversationEngine
    @State private var granularity: Granularity = .sentence
    @State private var showImporter = false
    @State private var importError: String?

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
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio, .wav, .mp3, .mpeg4Movie, .movie]) { result in
            handleImport(result)
        }
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

            Button("Transcribe File…") { showImporter = true }
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
        } else if let importError {
            message(importError, isError: true)
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

    private func handleImport(_ result: Result<URL, Error>) {
        importError = nil
        guard case .success(let url) = result else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        // fileImporter hands back a security-scoped URL; copy it into our own
        // container while access is granted, then transcribe the copy (the read
        // happens asynchronously, outside the scoped-access window). A single
        // fixed path (per extension) is reused and overwritten each import, so
        // temp copies never accumulate — only one input clip is ever on disk.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("stt-import-input.\(ext)")
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: url, to: temp)
            engine.transcribeFileTimestamped(temp)
        } catch {
            importError = error.localizedDescription
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
