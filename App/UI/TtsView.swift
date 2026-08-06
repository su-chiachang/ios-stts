import SwiftUI
import UniformTypeIdentifiers

/// The [tts] tab: type text, choose a voice, and hear it spoken. Voice modes are
/// adapts its controls to the qwentts.cpp checkpoint selected in Settings.
struct TtsView: View {
    var engine: StsEngine
    var settings = AppSettings.shared
    @State private var text = "Hello world"
    @State private var voice: VoiceChoice = .standard
    @State private var recorder = VoiceClipRecorder()
    @State private var message: String?
    @State private var isError = false
    #if os(iOS)
    @State private var showImportPicker = false
    #endif

    enum VoiceChoice: Hashable { case standard, cloned }

    private var hasClonedVoice: Bool { settings.customVoiceReferenceURL() != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                voiceSection
                textSection
                capabilitySection
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 500)
        #endif
        .onChange(of: recorder.isRecording) { wasRecording, nowRecording in
            if wasRecording && !nowRecording { saveRecordedClip() }
        }
        .onChange(of: settings.ttsBackend) { _, backend in
            if backend == .appleSpeech { voice = .standard }
        }
        #if os(iOS)
        .fileImporter(isPresented: $showImportPicker,
                      allowedContentTypes: [.audio, .wav, .mp3, .mpeg4Audio]) { result in
            guard case .success(let url) = result else { return }
            importClip(from: url)
        }
        #endif
    }

    private var voiceSection: some View {
        GroupBox("Voice") {
            if settings.ttsBackend == .appleSpeech {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Apple: language-matched system voice", systemImage: "waveform")
                    Text("Apple TTS selects a system voice from the sentence language and falls back to the system default. Reference voice controls belong to Qwen and Audio8.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
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
                        Button("Import clip…") { importClip() }
                            .disabled(recorder.isRecording)
                        Button(recorder.isRecording
                               ? String(format: "Recording %.0fs…", recorder.elapsed)
                               : "Record 3–5s") {
                            toggleRecording()
                        }
                    }
                    if settings.ttsBackend == .audio8 && voice == .cloned {
                        TextField("Reference transcript", text: Binding(
                            get: { settings.audio8ReferenceTranscript },
                            set: { settings.audio8ReferenceTranscript = $0 }))
                        Text("Audio8 requires the words spoken in the reference clip so it can condition the voice.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(settings.ttsBackend == .audio8
                         ? "Audio8 uses the reference clip and its transcript for reference conditioning."
                         : "Zero-shot cloning uses a 3–5 s clip. A matching transcript can also enable ICL through the native API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    private var capabilitySection: some View {
        GroupBox("Model capabilities") {
            VStack(alignment: .leading, spacing: 6) {
                if settings.ttsBackend == .appleSpeech {
                    Label("Apple: system-managed language-matched voices", systemImage: "waveform")
                    Text("No downloaded model or reference clip is required. The system default voice is used when a language-specific voice is unavailable.")
                        .font(.caption)
                } else if settings.ttsBackend == .audio8 {
                    Label("Audio8: default voice and reference conditioning", systemImage: "waveform.and.person.filled")
                    Text("Audio8 uses the generator, codec, and tokenizer resources selected in Settings. Qwen speaker and instruction controls do not apply.")
                        .font(.caption)
                } else {
                    Label("Base: default voice, x-vector cloning, and ICL cloning", systemImage: "person.wave.2")
                    Text("The built-in download choices use Base checkpoints. qwentts.cpp also supports CustomVoice and VoiceDesign through its native API.")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canSpeak: Bool {
        guard engine.isTTSReady,
              !engine.isProcessing,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if settings.ttsBackend == .appleSpeech { return true }
        return voice == .standard
            || (voice == .cloned
                && hasClonedVoice
                && (settings.ttsBackend == .qwen
                    || !settings.audio8ReferenceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    private func speak() {
        message = nil
        let usesCustomVoice = settings.ttsBackend != .appleSpeech && voice == .cloned
        let reference = usesCustomVoice ? settings.customVoiceReferenceURL()?.path : nil
        let transcript = usesCustomVoice && settings.ttsBackend == .audio8
            ? settings.audio8ReferenceTranscript
            : nil
        engine.speak(text, referenceWavPath: reference, referenceTranscript: transcript)
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

    // macOS uses NSOpenPanel to match SettingsView's voice import (and the
    // rest of the app); .fileImporter doesn't reliably fire in this
    // AppKit-hosted app. iOS has no AppKit host, so it presents
    // .fileImporter instead (see the modifier on `body`).
    private func importClip() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importClip(from: url)
        #else
        showImportPicker = true
        #endif
    }

    private func importClip(from url: URL) {
        message = "Importing voice…"
        isError = false
        #if os(iOS)
        let accessingScope = url.startAccessingSecurityScopedResource()
        #endif
        Task { @MainActor in
            #if os(iOS)
            defer { if accessingScope { url.stopAccessingSecurityScopedResource() } }
            #endif
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
    TtsView(engine: StsEngine())
}
