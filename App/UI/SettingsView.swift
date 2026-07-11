import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var engine: ConversationEngine
    var settings = AppSettings.shared

    @State private var parakeetPath: String = ""
    @State private var qwenDirPath: String = ""

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
                Button("Reload Models") {
                    Task { await engine.loadModels() }
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
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .onAppear {
            parakeetPath = AppSettings.shared.parakeetModelURL()?.path ?? ""
            qwenDirPath = AppSettings.shared.qwenModelDirURL()?.path ?? ""
        }
    }

    private func pickParakeetModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            try? AppSettings.shared.setParakeetModel(url)
            parakeetPath = url.path
        }
    }

    private func pickQwenModelDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? AppSettings.shared.setQwenModelDir(url)
            qwenDirPath = url.path
        }
    }
}

#Preview {
    SettingsView(engine: ConversationEngine())
}
