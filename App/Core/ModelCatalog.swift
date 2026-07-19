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

/// qwentts.cpp discovers the selected synthesis mode from talker metadata.
enum ModelCatalog {
    private static let hf = "https://huggingface.co"

    static var parakeetDirectory: URL {
        AppSettings.modelsRootDirectory.appendingPathComponent("parakeet", isDirectory: true)
    }

    static var qwenDirectory: URL {
        AppSettings.modelsRootDirectory.appendingPathComponent("qwentts", isDirectory: true)
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

    private static func ttsAsset(_ variant: QwenTtsVariant) -> ModelAsset {
        ModelAsset(
            id: "tts.\(variant.rawValue)",
            title: variant.displayName,
            subtitle: "\(variant.talkerFilename) + \(variant.codecFilename)",
            files: [
                ModelFile(
                    remoteURL: URL(string: "\(hf)/Serveurperso/Qwen3-TTS-GGUF/resolve/main/\(variant.talkerFilename)")!,
                    destinationFilename: variant.talkerFilename),
                ModelFile(
                    remoteURL: URL(string: "\(hf)/Serveurperso/Qwen3-TTS-GGUF/resolve/main/\(variant.codecFilename)")!,
                    destinationFilename: variant.codecFilename),
            ],
            destinationDirectory: qwenDirectory)
    }

    static let ttsAssets: [ModelAsset] = [
        ttsAsset(.base06bQ8),
        ttsAsset(.base17bQ8),
        ttsAsset(.customVoice06bQ8),
        ttsAsset(.customVoice17bQ8),
        ttsAsset(.voiceDesign17bQ8),
    ]

    static func ttsAsset(for variant: QwenTtsVariant) -> ModelAsset? {
        ttsAssets.first { $0.id == "tts.\(variant.rawValue)" }
    }
}
