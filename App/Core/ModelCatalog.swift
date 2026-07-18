import Foundation

/// One remote file and the name it's saved under locally.
struct ModelFile: Hashable {
    let remoteURL: URL
    let destinationFilename: String
}

/// A single row in the Download Models UI. STT entries are one file each;
/// TTS entries are a talker + tokenizer pair — qwen3-tts.cpp always loads
/// them together (see QwenTtsVariant), so they download/cancel as a unit.
struct ModelAsset: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let files: [ModelFile]
    let destinationDirectory: URL
}

/// Mirrors scripts/fetch-models.sh: same source repos, same on-disk
/// filenames (models/parakeet, models/qwen3tts), just downloaded in-app
/// instead of via a shell script run outside the sandbox.
///
/// Only Q8 has a verified-compatible prebuilt source. qwen3-tts.cpp's
/// vendored loader (TTSTransformer::create_tensors) hardcodes lookups for
/// tensor names like "talker.blk.N...weight" — a convention specific to how
/// badlogicgames/qwen3-tts-0.6b-q8_0-gguf converted this talker to GGUF.
/// Other GGUF exports of the same model (e.g.
/// hans00/Qwen3-TTS-12Hz-0.6B-GGUF, which otherwise conveniently bundles
/// F16/Q8/Q4 in one repo) use a different, more generic tensor naming (plain
/// "blk.N...weight") that this loader silently fails to match — it ends up
/// with zero tensors and load fails with a misleading "Failed to allocate
/// tensor buffer" rather than a clear "unrecognized schema" error. Don't add
/// a prebuilt F16/Q4 source here without first confirming its tensor names
/// carry the "talker." prefix (dump the GGUF header and check). Until then,
/// F16/Q4 require the --convert pipeline in scripts/fetch-models.sh.
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
            id: "tts.q8_0",
            title: "Q8",
            subtitle: "qwen3-tts-0.6b-q8_0.gguf + qwen3-tts-tokenizer-f16.gguf",
            files: [
                ModelFile(remoteURL: URL(string: "\(hf)/badlogicgames/qwen3-tts-0.6b-q8_0-gguf/resolve/main/qwen3-tts-0.6b-q8_0.gguf")!,
                          destinationFilename: "qwen3-tts-0.6b-q8_0.gguf"),
                ModelFile(remoteURL: URL(string: "\(hf)/badlogicgames/qwen3-tts-0.6b-q8_0-gguf/resolve/main/qwen3-tts-tokenizer-f16.gguf")!,
                          destinationFilename: "qwen3-tts-tokenizer-f16.gguf"),
            ],
            destinationDirectory: qwenDirectory),
    ]

    /// Looks up the TTS asset for a given quantization choice, so the UI can
    /// highlight whichever variant Settings currently has selected. `nil`
    /// for variants with no fast-download source (F16, Q4) — those must be
    /// produced via scripts/fetch-models.sh --convert and picked by hand in
    /// Settings.
    static func ttsAsset(for variant: QwenTtsVariant) -> ModelAsset? {
        ttsAssets.first { $0.id == "tts.\(variant.rawValue)" }
    }
}
