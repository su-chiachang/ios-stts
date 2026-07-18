import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var engine: ConversationEngine
    var settings = AppSettings.shared

    @State private var parakeetPath: String = ""
    @State private var qwenDirPath: String = ""
    @State private var modelMessage: String?
    @State private var modelMessageIsError = false
    @State private var showDownloadModels = false
    @State private var voiceMessage: String?
    @State private var voiceMessageIsError = false

    var body: some View {
        Form {
            Section("Models") {
                LabeledContent("Parakeet GGUF") {
                    HStack {
                        Text(parakeetPath.isEmpty ? "Not set" : parakeetPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(parakeetPath.isEmpty ? .secondary : .primary)
                        Button("Choose…") { pickParakeetModel() }
                    }
                }
                LabeledContent("Qwen3-TTS model dir") {
                    HStack {
                        Text(qwenDirPath.isEmpty ? "Not set" : qwenDirPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(qwenDirPath.isEmpty ? .secondary : .primary)
                        Button("Choose…") { pickQwenModelDir() }
                    }
                }
                Picker("Qwen3-TTS quantization", selection: Binding(
                    get: { settings.qwenModelVariant },
                    set: { settings.qwenModelVariant = $0; reloadModels() }
                )) {
                    ForEach(QwenTtsVariant.allCases) { variant in
                        Text(variant.displayName).tag(variant)
                    }
                }
                HStack {
                    Button("Download Models…") { showDownloadModels = true }
                    Button("Reload Models") { reloadModels() }
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

            Section("LLM (OpenAI-compatible)") {
                TextField("Base URL", text: Binding(get: { settings.llmBaseURL },
                                                     set: { settings.llmBaseURL = $0 }))
                SecureField("API Key (optional)", text: Binding(get: { settings.llmAPIKey },
                                                                 set: { settings.llmAPIKey = $0 }))
                TextField("Model", text: Binding(get: { settings.llmModel },
                                                  set: { settings.llmModel = $0 }))
                TextEditor(text: Binding(get: { settings.systemPrompt },
                                         set: { settings.systemPrompt = $0 }))
                    .frame(height: 80)
            }

            Section("Speech detection") {
                Picker("STT locale", selection: Binding(get: { settings.sttLocale },
                                                          set: { settings.sttLocale = $0 })) {
                    Text("Auto").tag("auto")
                    Text("Chinese").tag("zh-CN")
                    Text("English").tag("en")
                }
                Slider(value: Binding(get: { settings.silenceHangMs },
                                       set: { settings.silenceHangMs = $0 }), in: 300...2000, step: 50) {
                    Text("Silence hang: \(Int(settings.silenceHangMs)) ms")
                }
                Slider(value: Binding(get: { settings.rmsThreshold },
                                       set: { settings.rmsThreshold = $0 }), in: 0.001...0.05) {
                    Text("RMS threshold: \(settings.rmsThreshold, specifier: "%.3f")")
                }
            }

            Section("Custom voice (read aloud)") {
                LabeledContent("Reference voice") {
                    HStack {
                        Text(settings.customVoiceName.isEmpty ? "Not set" : settings.customVoiceName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(settings.customVoiceName.isEmpty ? .secondary : .primary)
                        Button("Import…") { importCustomVoice() }
                        if !settings.customVoiceName.isEmpty {
                            Button("Remove") {
                                settings.clearCustomVoice()
                                voiceMessage = nil
                            }
                        }
                    }
                }
                Toggle("Read typed text aloud in this voice", isOn: Binding(
                    get: { settings.readAloudMode },
                    set: { settings.readAloudMode = $0 }))
                Text("When on, Send (or Return) speaks your exact text in the imported voice instead of asking the assistant. A 5–15 s clip works best; the words spoken in it don't matter.")
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
        .frame(width: 480, height: 520)
        .onAppear {
            parakeetPath = AppSettings.shared.parakeetModelURL()?.path ?? ""
            qwenDirPath = AppSettings.shared.qwenModelDirURL()?.path ?? ""
        }
        .sheet(isPresented: $showDownloadModels) {
            DownloadModelsView(onModelsChanged: {
                parakeetPath = AppSettings.shared.parakeetModelURL()?.path ?? ""
                qwenDirPath = AppSettings.shared.qwenModelDirURL()?.path ?? ""
                reloadModels()
            })
        }
    }

    private func pickParakeetModel() {
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
    }

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

    private func importCustomVoice() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        voiceMessage = "Importing voice…"
        voiceMessageIsError = false
        Task { @MainActor in
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
    SettingsView(engine: ConversationEngine())
}
