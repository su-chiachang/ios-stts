import SwiftUI

/// The [stt] tab: import an mp3/wav (or any AVFoundation-readable file) and see
/// its transcript with timestamps, switchable between sentence-level (default)
/// and per-word granularity.
struct SttView: View {
    var engine: StsEngine
    var settings = AppSettings.shared
    @State private var granularity: Granularity = .sentence
    @State private var supportedLocales: [String] = []

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
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 500)
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $granularity) {
                ForEach(Granularity.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 132, idealWidth: 150, maxWidth: 150)
            .layoutPriority(1)
            .disabled(engine.timestampedWords.isEmpty)

            Spacer(minLength: 8)

            // Only Apple Speech is locale-bound. Parakeet auto-detects the
            // file's language and transcribeFileTimestamped passes it no
            // locale at all, so the control would be inert there.
            if settings.sttBackend == .apple {
                localePicker
            }

            MediaSourceMenu(onPick: engine.transcribeFileTimestamped, onError: engine.reportError) {
                Text("Import…")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .disabled(!engine.isSTTReady || engine.isProcessing)
        }
        .font(.callout)
        .padding()
    }

    /// Sits next to Import because it has to match the language of the clip
    /// being imported: Apple Speech never auto-detects, and a mismatch
    /// transcribes to nothing at all. Regional variants are separate entries
    /// for the same reason — picking zh-CN for Traditional audio transcribes
    /// it as Simplified.
    private var localePicker: some View {
        Menu {
            Button("Auto") {
                selectLocale(AppleSpeechLocaleResolver.autoTag)
            }
            ForEach(localeOptions, id: \.self) { tag in
                Button(AppleSpeechLocaleResolver.displayName(for: Locale(identifier: tag))) {
                    selectLocale(tag)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedLocaleTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .frame(minWidth: 64, idealWidth: 86, maxWidth: 120, alignment: .trailing)
        }
        .font(.callout)
        .layoutPriority(1)
        .disabled(engine.isProcessing || engine.state == .loadingModels)
        .task {
            guard supportedLocales.isEmpty else { return }
            supportedLocales = await AppleSpeechLocaleResolver.supportedLocales()
                .map { AppleSpeechLocaleResolver.tag(for: $0) }
        }
    }

    private var selectedLocaleTitle: String {
        let selected = AppleSpeechLocaleResolver.tag(for: settings.sttLocale)
        guard selected != AppleSpeechLocaleResolver.autoTag else { return "Auto" }
        return AppleSpeechLocaleResolver.displayName(for: Locale(identifier: selected))
    }

    private func selectLocale(_ newValue: String) {
        settings.sttLocale = newValue
        Task { await engine.loadModels() }
    }

    /// The saved locale is always one of the rows, even before the async
    /// supported-locale load lands — a selection with no matching tag renders
    /// the Picker blank.
    private var localeOptions: [String] {
        let selected = AppleSpeechLocaleResolver.tag(for: settings.sttLocale)
        guard selected != AppleSpeechLocaleResolver.autoTag,
              !supportedLocales.contains(where: { $0.caseInsensitiveCompare(selected) == .orderedSame })
        else { return supportedLocales }
        return [selected] + supportedLocales
    }

    @ViewBuilder
    private var content: some View {
        if engine.state == .listening {
            VStack(spacing: 12) {
                ProgressView()
                Text("Transcribing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.state == .loadingModels {
            // Switching to a locale whose assets aren't installed makes
            // SttApple.make download them, which is slow and silent; without
            // this the tab looks idle while the download runs.
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing speech models…").foregroundStyle(.secondary)
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
    SttView(engine: StsEngine())
}
