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

    private enum ViewMode: Hashable {
        case sentence
        case words
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
    @State private var readableSegments: [SttReadableSegment] = []
    @StateObject private var playback = AudioPlaybackController()
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var elapsedTimeTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?
    @State private var viewMode: ViewMode = .sentence
    @State private var playbackHeight: CGFloat?
    @State private var playbackResizeStart: CGFloat?

    private let minimumPlaybackHeight: CGFloat = 76
    private let maximumPlaybackHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            header
            if playback.hasMedia {
                PlaybackBar(
                    playback: playback,
                    height: playbackHeight ?? defaultPlaybackHeight)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                playbackResizeDivider
            }
            viewModePicker
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
                Text("stt:").font(.headline)
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
                Text("|")
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

    private var viewModePicker: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("View", selection: $viewMode) {
                Text("sentence").tag(ViewMode.sentence)
                Text("words").tag(ViewMode.words)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel("Transcript view")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 8)
    }

    private var defaultPlaybackHeight: CGFloat {
        playback.hasVideo ? 240 : minimumPlaybackHeight
    }

    private var playbackResizeDivider: some View {
        Divider()
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let startHeight = playbackResizeStart ?? defaultPlaybackHeight
                        if playbackResizeStart == nil {
                            playbackResizeStart = startHeight
                        }
                        playbackHeight = min(
                            max(startHeight + value.translation.height, minimumPlaybackHeight),
                            maximumPlaybackHeight)
                    }
                    .onEnded { _ in
                        playbackResizeStart = nil
                    })
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
            message(
                playback.hasMedia
                    ? "No transcript was found in this audio file."
                    : "Choose an audio file to transcribe.",
                isError: false)
        case .idle:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewMode == .sentence {
                        transcriptView
                    } else if timestampedWords.isEmpty {
                        Text("Word timestamps are not available for this result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Divider()
                        wordListView
                    }
                }
            }
            .padding()
        }
    }

    private func load() async {
        cancel()
        stt = nil
        resetTranscriptState()
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
        resetTranscriptState()
        state = .transcribing
        let requestID = UUID()
        activeRequestID = requestID
        let accessingScope = url.startAccessingSecurityScopedResource()
        let inputType = SttInputType.resolve(rawValue: sttInputTypeRawValue)
        let appleVersion = SttAppleVersion.resolve(rawValue: sttAppleVersionRawValue)
        durationTime = nil
        elapsedTime = 0
        let startedAt = Date()
        elapsedTimeTask = Task { @MainActor in
            while !Task.isCancelled {
                guard activeRequestID == requestID else { return }
                elapsedTime = Date().timeIntervalSince(startedAt)

                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
        }

        transcriptionTask = Task { @MainActor [stt] in
            defer {
                if accessingScope { url.stopAccessingSecurityScopedResource() }
                if activeRequestID == requestID {
                    stopElapsedTimer()
                    activeRequestID = nil
                    transcriptionTask = nil
                }
            }

            do {
                let fileDuration = await audioDuration(for: url)
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                durationTime = fileDuration

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
                let finalElapsed = Date().timeIntervalSince(startedAt)
                elapsedTime = finalElapsed
                transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                timestampedWords = result.words
                recomputeReadableSegments()
                saveTranscript(
                    transcript,
                    sourceURL: url,
                    version: appleVersion,
                    inputType: inputType,
                    elapsedSeconds: finalElapsed)
                playback.load(url: url)
                state = .idle
            } catch is CancellationError {
                guard activeRequestID == requestID else { return }
                state = .idle
            } catch {
                guard activeRequestID == requestID else { return }
                state = .error(error.localizedDescription)
            }
        }
    }

    private func saveTranscript(
        _ text: String,
        sourceURL: URL,
        version: SttAppleVersion,
        inputType: SttInputType,
        elapsedSeconds: Double
    ) {
        guard !text.isEmpty else { return }
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let seconds = String(format: "%.2f", elapsedSeconds)
        let fileName = "\(baseName)-stts-\(version.rawValue)-\(inputType.rawValue)-\(seconds)s.txt"
        let destination = sourceURL.deletingLastPathComponent().appendingPathComponent(fileName)
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            print("saveTranscript failed for \(destination.path): \(error)")
        }
    }

    private func appendParagraph(_ paragraph: SttFileTranscription) {
        let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transcript += transcript.isEmpty ? text : "\n\n\(text)"
        timestampedWords.append(contentsOf: paragraph.words)
    }

    private func stopElapsedTimer() {
        elapsedTimeTask?.cancel()
        elapsedTimeTask = nil
    }

    private func resetTranscriptState() {
        transcript = ""
        timestampedWords = []
        readableSegments = []
    }

    private func recomputeReadableSegments() {
        readableSegments = SttSentenceBreaking.segments(
            for: SttFileTranscription(text: transcript, words: timestampedWords),
            locale: localeIdentifier)
    }

    private func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        stopElapsedTimer()
        activeRequestID = nil
        elapsedTime = nil
        durationTime = nil
        playbackHeight = nil
        playbackResizeStart = nil
        playback.unload()
        if state == .transcribing {
            // A partial transcript may already be accumulated (streamed via
            // appendParagraph) when the user stops mid-transcription; keep
            // the Sentence view in sync with it rather than showing nothing.
            recomputeReadableSegments()
            state = .idle
        }
    }

    private func reportError(_ message: String) {
        state = .error(message)
    }

    private var activeWordIndex: Int? {
        SttWordHighlighting.activeWordIndex(
            at: playback.currentTime,
            in: timestampedWords)
    }

    @ViewBuilder
    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(readableSegments.enumerated()), id: \.offset) { _, segment in
                highlightedText(for: segment)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func highlightedText(for segment: SttReadableSegment) -> Text {
        guard let wordRange = segment.wordRange else {
            return Text(segment.text)
        }

        let activeIndex = activeWordIndex
        let words = Array(timestampedWords[wordRange])
        var result = AttributedString()

        for piece in SttWordHighlighting.transcriptSegments(in: segment.text, words: words) {
            var styledPiece = AttributedString(piece.text)
            if let localIndex = piece.wordIndex, wordRange.lowerBound + localIndex == activeIndex {
                styledPiece.foregroundColor = .accentColor
            }
            result += styledPiece
        }

        return Text(result)
    }

    private var wordListView: some View {
        let activeIndex = activeWordIndex
        return LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(timestampedWords.enumerated()), id: \.offset) { index, word in
                let isActive = index == activeIndex
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(seconds(word.start)) – \(seconds(word.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(word.text)
                        .foregroundStyle(
                            isActive ? Color.accentColor : Color.primary)
                        .fontWeight(isActive ? .bold : .regular)
                        .textSelection(.enabled)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    isActive ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
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
