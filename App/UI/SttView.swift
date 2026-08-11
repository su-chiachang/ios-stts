import SwiftUI

/// The [stt] tab: import a file and transcribe the complete audio using the
/// complete-file SpeechAnalyzer flow.
@available(macOS 26.0, iOS 26.0, *)
@MainActor
struct SttView: View {
    private enum ViewState: Equatable {
        case loading
        case idle
        case transcribing
        case error(String)
    }

    @AppStorage(SttLocalePreferences.key)
    private var localeIdentifier = SttLocalePreferences.defaultIdentifier
    @State private var stt: SttApple?
    @State private var state: ViewState = .loading
    @State private var transcript = ""
    @State private var timestampedWords: [SttWordTimestamp] = []
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 500)
        #endif
        .task(id: localeIdentifier) { await load() }
        .onDisappear { cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("stt").font(.headline)
            Spacer(minLength: 8)

            if state == .transcribing {
                Button("Stop") { cancel() }
                    .buttonStyle(.plain)
            }

            MediaSourceMenu(onPick: transcribeFile, onError: reportError) {
                Text("Import…")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .disabled(stt == nil || state == .loading || state == .transcribing)
        }
        .font(.callout)
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .transcribing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Transcribing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing speech models…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            self.message(message, isError: true)
        case .idle where transcript.isEmpty:
            message("Choose an audio file to transcribe.", isError: false)
        case .idle:
            ScrollView {
                if timestampedWords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Text("Word timestamps are not available for this result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    wordList
                }
            }
            .padding()
        }
    }

    private func load() async {
        cancel()
        stt = nil
        transcript = ""
        timestampedWords = []
        state = .loading

        do {
            try Task.checkCancellation()
            let loaded = try await SttApple.make(localeIdentifier: localeIdentifier)
            try Task.checkCancellation()
            stt = loaded
            state = .idle
        } catch is CancellationError {
            // A locale change or view disappearance cancels model loading.
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func transcribeFile(_ url: URL) {
        guard let stt else {
            state = .error("Apple Speech is not ready. Try again in a moment.")
            return
        }

        cancel()
        transcript = ""
        timestampedWords = []
        state = .transcribing
        let requestID = UUID()
        activeRequestID = requestID
        let accessingScope = url.startAccessingSecurityScopedResource()

        transcriptionTask = Task { @MainActor [stt] in
            defer {
                if accessingScope { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let result = try await stt.transcribeFile(url)
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                timestampedWords = result.words
                state = .idle
                activeRequestID = nil
                transcriptionTask = nil
            } catch is CancellationError {
                guard activeRequestID == requestID else { return }
                activeRequestID = nil
                transcriptionTask = nil
                state = .idle
            } catch {
                guard activeRequestID == requestID else { return }
                activeRequestID = nil
                transcriptionTask = nil
                state = .error(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeRequestID = nil
        if state == .transcribing { state = .idle }
    }

    private func reportError(_ message: String) {
        state = .error(message)
    }

    private var wordList: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(timestampedWords.enumerated()), id: \.offset) { _, word in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(seconds(word.start)) – \(seconds(word.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(word.text)
                        .textSelection(.enabled)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }

    private func message(_ text: String, isError: Bool) -> some View {
        Text(text)
            .foregroundStyle(isError ? .red : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}

#Preview {
    if #available(macOS 26.0, iOS 26.0, *) {
        SttView()
    }
}
