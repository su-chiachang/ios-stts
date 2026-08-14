import AVFoundation
import Foundation
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
    @AppStorage(SttAppleVersion.key)
    private var sttAppleVersionRawValue = SttAppleVersion.defaultValue.rawValue
    @AppStorage(SttInputType.key)
    private var sttInputTypeRawValue = SttInputType.defaultValue.rawValue
    @State private var stt: SttAppleAdapter?
    @State private var elapsedTime: Double?
    @State private var durationTime: Double?
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
        .task(id: "\(localeIdentifier)|\(sttAppleVersionRawValue)|\(sttInputTypeRawValue)") { await load() }
        .onDisappear { cancel() }
    }

    private var header: some View {
        ZStack {
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

            HStack(spacing: 8) {
                Text(elapsedTime.map(formatDuration) ?? "--:--:--.--")
                    .help("Transcribe elapsed time")
                Text(durationTime.map(formatDuration) ?? "--:--:--.--")
                    .help("Audio duration")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
        }
        .font(.callout)
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .transcribing:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Transcribing…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !transcript.isEmpty {
                        Text(transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
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
                VStack(alignment: .leading, spacing: 12) {
                    Text(transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if timestampedWords.isEmpty {
                        Text("Word timestamps are not available for this result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Divider()
                        wordList
                    }
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
            let loaded = try await SttAppleAdapter.make(
                version: SttAppleVersion.resolve(rawValue: sttAppleVersionRawValue),
                localeIdentifier: localeIdentifier)
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
        let inputType = SttInputType.resolve(rawValue: sttInputTypeRawValue)
        durationTime = nil
        elapsedTime = 0

        transcriptionTask = Task { @MainActor [stt] in
            defer {
                if accessingScope { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let fileDuration = await audioDuration(for: url)
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                durationTime = fileDuration

                let startedAt = Date()
                let result = try await stt.transcribeFile(
                    url,
                    inputType: inputType
                ) { paragraph in
                    guard activeRequestID == requestID else { return }
                    appendParagraph(paragraph)
                    elapsedTime = Date().timeIntervalSince(startedAt)
                }
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                elapsedTime = Date().timeIntervalSince(startedAt)
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

    private func appendParagraph(_ paragraph: SttFileTranscription) {
        let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transcript += transcript.isEmpty ? text : "\n\n\(text)"
        timestampedWords.append(contentsOf: paragraph.words)
    }

    private func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeRequestID = nil
        elapsedTime = nil
        durationTime = nil
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

    private func audioDuration(for url: URL) async -> Double? {
        do {
            let asset = AVURLAsset(url: url)
            guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                return nil
            }
            let timeRange = try await audioTrack.load(.timeRange)
            let duration = timeRange.duration.seconds
            return duration.isFinite && duration >= 0 ? duration : nil
        } catch {
            return nil
        }
    }

    private func formatDuration(_ value: Double) -> String {
        guard value.isFinite else { return "--:--:--.--" }
        let centiseconds = max(0, Int((value * 100).rounded()))
        let hh = centiseconds / 360_000
        let mm = (centiseconds / 6_000) % 60
        let ss = (centiseconds / 100) % 60
        let ff = centiseconds % 100
        return String(format: "%02d:%02d:%02d.%02d", hh, mm, ss, ff)
    }

    private func message(_ text: String, isError: Bool) -> some View {
        Text(text)
            .foregroundStyle(isError ? .red : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}
