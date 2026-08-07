import SwiftUI

/// The [tts] tab: type text and hear it spoken with Apple's system voice.
struct TtsView: View {
    var engine: StsEngine
    @State private var text = "Hello world"
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Voice") {
                    Label("Apple: language-matched system voice", systemImage: "waveform")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Apple TTS uses the system voice for each sentence's language and needs no downloaded model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                }

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
    }

    private var canSpeak: Bool {
        engine.isTTSReady
            && !engine.isProcessing
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func speak() {
        message = nil
        isError = false
        if !engine.speak(text) {
            message = "Apple TTS is not ready."
            isError = true
        }
    }
}

#Preview {
    TtsView(engine: StsEngine())
}
