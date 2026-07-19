import SwiftUI
import UniformTypeIdentifiers

/// The [tts] tab: type text, choose a voice, and hear it spoken. Voice modes are
/// adapts its controls to the qwentts.cpp checkpoint selected in Settings.
struct TtsView: View {
    var engine: ConversationEngine
    var settings = AppSettings.shared
    @State private var text = "Hello world"
    @State private var voice: VoiceChoice = .standard
    @State private var recorder = VoiceClipRecorder()
    @State private var message: String?
    @State private var isError = false
    @State private var presetSpeaker = "vivian"
    @State private var presetSpeakers: [String] = []
    @State private var voiceInstruction = "warm, clear, and conversational"

    enum VoiceChoice: Hashable { case standard, cloned, preset, designed }

    private var hasClonedVoice: Bool { settings.customVoiceReferenceURL() != nil }
    private var isBaseModel: Bool {
        settings.qwenModelVariant == .base06b || settings.qwenModelVariant == .base17b
    }
    private var isCustomVoiceModel: Bool {
        settings.qwenModelVariant == .customVoice06b || settings.qwenModelVariant == .customVoice17b
    }
    private var isVoiceDesignModel: Bool { settings.qwenModelVariant == .voiceDesign17b }

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
        .frame(minWidth: 420, minHeight: 500)
        .onChange(of: recorder.isRecording) { wasRecording, nowRecording in
            if wasRecording && !nowRecording { saveRecordedClip() }
        }
        .task(id: settings.qwenModelVariant) {
            let speakers = await engine.availablePresetSpeakers()
            presetSpeakers = speakers
            if let first = speakers.first, !speakers.contains(presetSpeaker) { presetSpeaker = first }
        }
    }

    private var voiceSection: some View {
        GroupBox("Voice") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $voice) {
                    if isBaseModel {
                        Text("Default").tag(VoiceChoice.standard)
                        Text(hasClonedVoice ? "My voice" : "My voice (none)").tag(VoiceChoice.cloned)
                    }
                    if isCustomVoiceModel { Text("Preset voice").tag(VoiceChoice.preset) }
                    if isVoiceDesignModel { Text("Designed voice").tag(VoiceChoice.designed) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if isBaseModel {
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
                    Text("Zero-shot cloning uses a 3–5 s clip. A matching transcript can also enable ICL through the native API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isCustomVoiceModel {
                    if presetSpeakers.isEmpty {
                        TextField("Speaker", text: $presetSpeaker)
                    } else {
                        Picker("Speaker", selection: $presetSpeaker) {
                            ForEach(presetSpeakers, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                if isVoiceDesignModel {
                    TextField("Voice description", text: $voiceInstruction)
                    Text("Describe gender, age, pitch, style, or delivery.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

    private var capabilitySection: some View {
        GroupBox("Model capabilities") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Base: default voice, x-vector cloning, and ICL cloning", systemImage: "person.wave.2")
                Label("CustomVoice: named preset speakers", systemImage: "person.2")
                Label("VoiceDesign: describe a voice in words", systemImage: "wand.and.stars")
                Text("Available controls follow the selected qwentts.cpp checkpoint.")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canSpeak: Bool {
        engine.isReady && !engine.isProcessing
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (voice == .standard || (voice == .cloned && hasClonedVoice)
                || (voice == .preset && !presetSpeaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                || (voice == .designed && !voiceInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    private func speak() {
        message = nil
        let reference = voice == .cloned ? settings.customVoiceReferenceURL()?.path : nil
        engine.speak(text, referenceWavPath: reference,
                     speaker: voice == .preset ? presetSpeaker : nil,
                     instruction: voice == .designed ? voiceInstruction : nil)
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

    // NSOpenPanel to match SettingsView's voice import (and the rest of the app);
    // .fileImporter doesn't reliably fire in this AppKit-hosted app.
    private func importClip() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
