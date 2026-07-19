import Foundation

struct ModelFile: Hashable {
    let remoteURL: URL
    let destinationFilename: String
}

/// STT assets contain one file; qwentts.cpp assets are an inseparable talker
/// and codec pair.
struct ModelAsset: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let files: [ModelFile]
    let destinationDirectory: URL
}

/// The app downloads the compact Base model. qwentts.cpp discovers the other
/// supported modes (1.7B, CustomVoice, VoiceDesign) from talker metadata when
/// their corresponding pair is placed in this same directory.
enum ModelCatalog {
    private static let hf = "https://huggingface.co"

    static var parakeetDirectory: URL {
        AppSettings.modelsRootDirectory.appendingPathComponent("parakeet", isDirectory: true)
    }

    static var qwenDirectory: URL {
        AppSettings.modelsRootDirectory.appendingPathComponent("qwen3tts", isDirectory: true)
    }

    static let sttAssets: [ModelAsset] = [
        ModelAsset(
            id: "stt.nemotron",
            title: "Nemotron (streaming ASR)",
            subtitle: "nemotron-3.5-asr-streaming-0.6b-q8_0.gguf",
            files: [ModelFile(
                remoteURL: URL(string: "\(hf)/mudler/parakeet-cpp-gguf/resolve/main/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf")!,
                destinationFilename: "nemotron-3.5-asr-streaming-0.6b-q8_0.gguf")],
            destinationDirectory: parakeetDirectory),
        ModelAsset(
            id: "stt.realtime",
            title: "Realtime EOU detector",
            subtitle: "realtime_eou_120m-v1-q8_0.gguf",
            files: [ModelFile(
                remoteURL: URL(string: "\(hf)/mudler/parakeet-cpp-gguf/resolve/main/realtime_eou_120m-v1-q8_0.gguf")!,
                destinationFilename: "realtime_eou_120m-v1-q8_0.gguf")],
            destinationDirectory: parakeetDirectory),
    ]

    static let ttsAssets: [ModelAsset] = [
        ModelAsset(
            id: "tts.base-0.6b-q8",
            title: "Base 0.6B (Q8)",
            subtitle: "qwen-talker-0.6b-base-Q8_0.gguf + qwen-tokenizer-12hz-Q8_0.gguf",
            files: [
                ModelFile(
                    remoteURL: URL(string: "\(hf)/Serveurperso/Qwen3-TTS-GGUF/resolve/main/qwen-talker-0.6b-base-Q8_0.gguf")!,
                    destinationFilename: "qwen-talker-0.6b-base-Q8_0.gguf"),
                ModelFile(
                    remoteURL: URL(string: "\(hf)/Serveurperso/Qwen3-TTS-GGUF/resolve/main/qwen-tokenizer-12hz-Q8_0.gguf")!,
                    destinationFilename: "qwen-tokenizer-12hz-Q8_0.gguf"),
            ],
            destinationDirectory: qwenDirectory),
    ]

    static func ttsAsset(for variant: QwenTtsVariant) -> ModelAsset? {
        ttsAssets.first { $0.id == "tts.\(variant.rawValue)" }
    }
}
