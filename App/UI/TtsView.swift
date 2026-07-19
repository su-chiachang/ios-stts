import SwiftUI
import UniformTypeIdentifiers

/// The [tts] tab: type text, choose a voice, and hear it spoken. Voice modes are
/// scoped to what the local qwen3-tts.cpp port supports — the model's default
/// voice and zero-shot cloning (import or record a 3–5 s reference clip).
/// Preset voices and text-prompt voice design aren't in the local model and are
/// surfaced as a disabled "coming soon" note.
struct TtsView: View {
    var engine: ConversationEngine
    var settings = AppSettings.shared
    @State private var text = "Hello world"
    @State private var voice: VoiceChoice = .standard
    @State private var recorder = VoiceClipRecorder()
    @State private var showImporter = false
    @State private var message: String?
    @State private var isError = false

    enum VoiceChoice: Hashable { case standard, cloned }

    private var hasClonedVoice: Bool { settings.customVoiceReferenceURL() != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                voiceSection
                textSection
                comingSoonSection
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 500)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio, .wav, .mp3, .mpeg4Audio]) { result in
            handleImport(result)
        }
        .onChange(of: recorder.isRecording) { wasRecording, nowRecording in
            if wasRecording && !nowRecording { saveRecordedClip() }
        }
    }

    private var voiceSection: some View {
        GroupBox("Voice") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $voice) {
                    Text("Default").tag(VoiceChoice.standard)
                    Text(hasClonedVoice ? "My voice" : "My voice (none)").tag(VoiceChoice.cloned)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Text(hasClonedVoice ? "Reference: \(settings.customVoiceName)" : "No cloned voice yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Import clip…") { showImporter = true }
                        .disabled(recorder.isRecording)
                    Button(recorder.isRecording
                           ? String(format: "Recording %.0fs…", recorder.elapsed)
                           : "Record 3–5s") {
                        toggleRecording()
                    }
                }
                Text("Zero-shot cloning: a 3–5 s clip of your voice is enough; the words spoken in it don't matter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var textSection: some View {
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
                    Button("Stop") { engine.stop() }
                        .disabled(!engine.isProcessing)
                    Button {
                        speak()
                    } label: {
                        Label("Speak", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSpeak)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var comingSoonSection: some View {
        GroupBox("Coming soon") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Preset voices (Vivian, Uncle_Fu, Dylan…)", systemImage: "person.2")
                Label("Voice design — describe a voice in words", systemImage: "wand.and.stars")
                Text("Not available in the local model.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(true)
    }

    private var canSpeak: Bool {
        engine.isReady && !engine.isProcessing
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (voice == .standard || hasClonedVoice)
    }

    private func speak() {
        message = nil
        let reference = voice == .cloned ? settings.customVoiceReferenceURL()?.path : nil
        engine.speak(text, referenceWavPath: reference)
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()   // triggers saveRecordedClip via onChange
        } else {
            message = nil
            Task {
                let ok = await recorder.start(maxSeconds: 6)
                if !ok {
                    message = VoiceClipRecorder.RecorderError.permissionDenied.localizedDescription
                    isError = true
                }
            }
        }
    }

    private func saveRecordedClip() {
        do {
            let url = try recorder.writeWav()
            defer { try? FileManager.default.removeItem(at: url) }
            try settings.importCustomVoice(from: url, displayName: "Recorded voice")
            voice = .cloned
            message = "Recorded voice saved."
            isError = false
            Task { try? await engine.warmCustomVoice() }
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { message = error.localizedDescription; isError = true }
            return
        }
        message = "Importing voice…"
        isError = false
        Task { @MainActor in
            do {
                try settings.importCustomVoice(from: url, displayName: url.lastPathComponent)
                try await engine.warmCustomVoice()
                voice = .cloned
                message = "Voice imported."
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
        }
    }
}

#Preview {
    TtsView(engine: ConversationEngine())
}
