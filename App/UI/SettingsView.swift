import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var engine: StsEngine
    var settings = AppSettings.shared

    @State private var parakeetPath: String = ""
    @State private var qwenDirPath: String = ""
    @State private var audio8DirPath: String = ""
    @State private var modelMessage: String?
    @State private var modelMessageIsError = false
    @State private var showDownloadModels = false
    @State private var voiceMessage: String?
    @State private var voiceMessageIsError = false
    #if os(iOS)
    @State private var showParakeetPicker = false
    @State private var showAudio8ModelPicker = false
    @State private var showVoicePicker = false
    #endif

    var body: some View {
        Form {
            Section("Models") {
                Picker("STT backend", selection: Binding(
                    get: { settings.sttBackend },
                    set: {
                        settings.sttBackend = $0
                        reloadModels()
                    })) {
                    ForEach(SttBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                Picker("TTS backend", selection: Binding(
                    get: { settings.ttsBackend },
                    set: {
                        settings.ttsBackend = $0
                        reloadModels()
                    })) {
                    ForEach(TtsBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                if settings.sttBackend == .parakeet {
                    LabeledContent("Parakeet STT") {
                        HStack {
                            Text(parakeetPath.isEmpty ? "Not set" : parakeetPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(parakeetPath.isEmpty ? .secondary : .primary)
                            Button("Choose…") { pickParakeetModel() }
                        }
                    }
                } else {
                    LabeledContent("Apple Speech") {
                        Label("System-managed on-device model", systemImage: "checkmark.shield")
                            .foregroundStyle(.secondary)
                    }
                    Text("Apple Speech requires iOS 26 or macOS 26. Its locale model is prepared when you reload models; Auto uses the current system locale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.ttsBackend == .qwen {
                    LabeledContent("Qwen TTS dir") {
                        HStack {
                            Text(qwenDirPath.isEmpty ? "Not set" : qwenDirPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(qwenDirPath.isEmpty ? .secondary : .primary)
                            #if os(macOS)
                            Button("Choose…") { pickQwenModelDir() }
                            #endif
                        }
                    }
                } else if settings.ttsBackend == .audio8 {
                    Picker("Audio8 TTS variant", selection: Binding(
                        get: { settings.audio8TtsVariant },
                        set: {
                            settings.audio8TtsVariant = $0
                            reloadModels()
                        })) {
                        ForEach(Audio8TtsVariant.allCases, id: \.self) { variant in
                            Text(variant.displayName).tag(variant)
                        }
                    }
                    LabeledContent("Audio8 model dir") {
                        HStack {
                            Text(audio8DirPath.isEmpty ? "Not set" : audio8DirPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(audio8DirPath.isEmpty ? .secondary : .primary)
                            Button("Choose…") { pickAudio8ModelDir() }
                        }
                    }
                    Text(settings.audio8ModelReadinessMessage())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LabeledContent("Apple TTS") {
                        Label("System-managed voice", systemImage: "checkmark.shield")
                            .foregroundStyle(.secondary)
                    }
                    Text("Apple TTS needs no downloaded model. It selects a system voice from each sentence's language and falls back to the system default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Download Models…") { showDownloadModels = true }
                }
                if let modelMessage {
                    Text(modelMessage)
                        .font(.caption)
                        .foregroundStyle(modelMessageIsError ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Section("LLM") {
                Picker("ttt backend", selection: Binding(
                    get: { settings.tttBackend },
                    set: {
                        engine.setTttBackend($0, settings: settings)
                    })) {
                        ForEach(TttBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(settings.tttBackend == .apple
                     ? "Use Apple's on-device Foundation Models for ttt."
                     : "Use the OpenAI-compatible Web API configured below for ttt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Base URL", text: Binding(get: { settings.llmBaseURL },
                                                     set: { settings.llmBaseURL = $0 }))
                SecureField("API key", text: Binding(get: { settings.llmAPIKey },
                                                       set: { settings.llmAPIKey = $0 }))
                TextField("Model", text: Binding(get: { settings.llmModel },
                                                  set: { settings.llmModel = $0 }))
                TextEditor(text: Binding(get: { settings.systemPrompt },
                                         set: { settings.systemPrompt = $0 }))
                    .frame(height: 80)
            }

            // STT locale lives in the [stt] tab next to Import, where the user
            // picks the clip whose language it has to match.
            Section("Speech detection") {
                Slider(value: Binding(get: { settings.silenceHangMs },
                                       set: { settings.silenceHangMs = $0 }), in: 300...2000, step: 50) {
                    Text("Silence hang: \(Int(settings.silenceHangMs)) ms")
                }
                Slider(value: Binding(get: { settings.rmsThreshold },
                                       set: { settings.rmsThreshold = $0 }), in: 0.001...0.05) {
                    Text("RMS threshold: \(settings.rmsThreshold, specifier: "%.3f")")
                }
            }

            Section("Custom voice") {
                LabeledContent("Reference voice") {
                    HStack {
                        Text(settings.customVoiceName.isEmpty ? "Not set" : settings.customVoiceName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(settings.customVoiceName.isEmpty ? .secondary : .primary)
                        Button("Import…") { importCustomVoice() }
                            .disabled(settings.ttsBackend == .apple)
                        if !settings.customVoiceName.isEmpty {
                            Button("Remove") {
                                settings.clearCustomVoice()
                                voiceMessage = nil
                            }
                            .disabled(settings.ttsBackend == .apple)
                        }
                    }
                }
                Toggle("Read typed text aloud in this voice", isOn: Binding(
                    get: { settings.readAloudMode },
                    set: { settings.readAloudMode = $0 }))
                    .disabled(settings.ttsBackend == .apple)
                Text(settings.ttsBackend == .apple
                     ? "Apple TTS uses the system voice for read-aloud mode. Switch to Qwen or Audio8 to manage a custom reference voice."
                     : settings.ttsBackend == .audio8
                     ? "When on, Send (or Return) speaks your exact text with Audio8 reference conditioning. A 5–15 s clip works best; enter its transcript in the TTS tab."
                     : "When on, Send (or Return) speaks your exact text in the imported voice instead of asking the assistant. A 5–15 s clip works best; the words spoken in it don't matter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let voiceMessage {
                    Text(voiceMessage)
                        .font(.caption)
                        .foregroundStyle(voiceMessageIsError ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .font(.callout) // matches SttsView's compact type scale
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
        .onAppear {
            parakeetPath = AppSettings.shared.parakeetModelURL()?.path ?? ""
            qwenDirPath = AppSettings.shared.qwenModelDirURL()?.path ?? ""
            audio8DirPath = AppSettings.shared.audio8ModelDirURL().path
        }
        .sheet(isPresented: $showDownloadModels) {
            DownloadModelsView(onModelsChanged: {
                parakeetPath = AppSettings.shared.parakeetModelURL()?.path ?? ""
                qwenDirPath = AppSettings.shared.qwenModelDirURL()?.path ?? ""
                audio8DirPath = AppSettings.shared.audio8ModelDirURL().path
                reloadModels()
            })
        }
        #if os(iOS)
        .fileImporter(isPresented: $showParakeetPicker,
                      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            let accessingScope = url.startAccessingSecurityScopedResource()
            defer { if accessingScope { url.stopAccessingSecurityScopedResource() } }
            do {
                try AppSettings.shared.setParakeetModel(url)
                parakeetPath = url.path
                reloadModels()
            } catch {
                showModelError(bookmarkErrorMessage("STT model", error: error))
            }
        }
        .fileImporter(isPresented: $showVoicePicker,
                      allowedContentTypes: [.audio, .wav, .mp3, .mpeg4Audio]) { result in
            guard case .success(let url) = result else { return }
            importCustomVoice(from: url)
        }
        .fileImporter(isPresented: $showAudio8ModelPicker,
                      allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let accessingScope = url.startAccessingSecurityScopedResource()
            defer { if accessingScope { url.stopAccessingSecurityScopedResource() } }
            do {
                try AppSettings.shared.setAudio8ModelDir(url)
                audio8DirPath = url.path
                reloadModels()
            } catch {
                showModelError(bookmarkErrorMessage("Audio8 model directory", error: error))
            }
        }
        #endif
    }

    private func pickParakeetModel() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AppSettings.shared.setParakeetModel(url)
                parakeetPath = url.path
                reloadModels()
            } catch {
                showModelError(bookmarkErrorMessage("STT model", error: error))
            }
        }
        #else
        showParakeetPicker = true
        #endif
    }

    #if os(macOS)
    private func pickQwenModelDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AppSettings.shared.setQwenModelDir(url)
                qwenDirPath = url.path
                reloadModels()
            } catch {
                showModelError(bookmarkErrorMessage("TTS model directory", error: error))
            }
        }
    }

    #endif

    private func pickAudio8ModelDir() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AppSettings.shared.setAudio8ModelDir(url)
                audio8DirPath = url.path
                reloadModels()
            } catch {
                showModelError(bookmarkErrorMessage("Audio8 model directory", error: error))
            }
        }
        #else
        showAudio8ModelPicker = true
        #endif
    }

    private func importCustomVoice() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importCustomVoice(from: url)
        #else
        showVoicePicker = true
        #endif
    }

    private func importCustomVoice(from url: URL) {
        voiceMessage = "Importing voice…"
        voiceMessageIsError = false
        #if os(iOS)
        let accessingScope = url.startAccessingSecurityScopedResource()
        #endif
        Task { @MainActor in
            #if os(iOS)
            defer { if accessingScope { url.stopAccessingSecurityScopedResource() } }
            #endif
            do {
                try AppSettings.shared.importCustomVoice(from: url, displayName: url.lastPathComponent)
                try await engine.warmCustomVoice()
                voiceMessage = "Voice imported."
                voiceMessageIsError = false
            } catch {
                voiceMessage = error.localizedDescription
                voiceMessageIsError = true
            }
        }
    }

    private func reloadModels() {
        modelMessage = "Loading models…"
        modelMessageIsError = false
        Task { @MainActor in
            await engine.loadModels()
            if case .error(let message) = engine.state {
                showModelError(message)
            } else {
                modelMessage = "Models loaded."
            }
        }
    }

    private func showModelError(_ message: String) {
        modelMessage = message
        modelMessageIsError = true
    }

    private func bookmarkErrorMessage(_ subject: String, error: Error) -> String {
        let nsError = error as NSError
        return "Could not save the \(subject) [\(nsError.domain) \(nsError.code)]: \(nsError.localizedDescription)"
    }
}

#Preview {
    SettingsView(engine: StsEngine())
}
