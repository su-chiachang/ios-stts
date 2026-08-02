import Foundation

struct ModelFile: Hashable {
    let remoteURL: URL?
    let destinationFilename: String
}

/// STT assets contain one file. Qwen assets are an inseparable talker/codec
/// pair; Audio8 TTS assets are an inseparable generator/codec/tokenizer group.
struct ModelAsset: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let files: [ModelFile]
    let destinationDirectory: URL

    var isDownloadConfigured: Bool {
        files.allSatisfy { $0.remoteURL != nil }
    }

    var configurationError: String? {
        guard !isDownloadConfigured else { return nil }
        return "Download URL is not configured for this model."
    }
}

struct Audio8ModelResources: Hashable, Sendable {
    let generatorURL: URL
    let codecURL: URL
    let tokenizerURL: URL
}

/// The app exposes Base 0.6B and 1.7B talkers; qwentts.cpp discovers the
/// checkpoint mode from talker metadata when advanced checkpoints are used.
enum ModelCatalog {
    private static let hf = "https://huggingface.co"
    static let sttModelName = "nemotron-3.5-asr-streaming-0.6b-q4_k.gguf"

    static var parakeetDirectory: URL {
        AppSettings.modelsRootDirectory.appendingPathComponent("parakeet", isDirectory: true)
    }

    static var qwenDirectory: URL {
        AppSettings.modelsRootDirectory.appendingPathComponent("qwentts", isDirectory: true)
    }

    static var audio8Directory: URL {
        AppSettings.modelsRootDirectory.appendingPathComponent("audio8", isDirectory: true)
    }

    static let audio8GeneratorFilename = "audio8-generator-F32.gguf"
    static let audio8CodecFilename = "audio8-codec-F32.gguf"
    static let audio8TokenizerFilename = "tokenizer.json"
    static let audio8SttModelFilename = "ark-asr-0.6b-f16.gguf"
    private static let audio8GeneratorPrefix = "audio8-generator"
    private static let audio8CodecPrefix = "audio8-codec"
    private static let audio8SttModelPrefix = "ark-asr-"

    static let sttAssets: [ModelAsset] = [
        ModelAsset(
            id: "stt.nemotron",
            title: "Nemotron (streaming ASR)",
            subtitle: sttModelName,
            files: [ModelFile(
                remoteURL: URL(string: "\(hf)/mudler/parakeet-cpp-gguf/resolve/main/\(sttModelName)")!,
                destinationFilename: sttModelName)],
            destinationDirectory: parakeetDirectory),
    ]

    /// Audio8's ARK-ASR checkpoint is converted from the official
    /// Audio8/ARK-ASR release with audio8.cpp's exporter. The project does
    /// not assume a hosted conversion URL; users can place the GGUF in the
    /// selected Audio8 directory.
    static let audio8SttAssets: [ModelAsset] = [
        ModelAsset(
            id: "stt.audio8.ark-asr",
            title: "Audio8 ARK-ASR (0.6B)",
            subtitle: "ark-asr-0.6b-f16.gguf",
            files: [ModelFile(remoteURL: nil, destinationFilename: audio8SttModelFilename)],
            destinationDirectory: audio8Directory),
    ]

    private static func ttsAsset(_ variant: QwenTtsVariant,
                                 quantization: QwenTtsQuantization) -> ModelAsset {
        let talkerFilename = quantization.talkerFilename(for: variant)
        let codecFilename = quantization.codecFilename
        return ModelAsset(
            id: "tts.\(variant.rawValue).\(quantization.rawValue)",
            title: "\(variant.displayName) (\(quantization.displayName))",
            subtitle: "\(talkerFilename) + \(codecFilename)",
            files: [
                ModelFile(
                    remoteURL: URL(string: "\(hf)/Serveurperso/Qwen3-TTS-GGUF/resolve/main/\(talkerFilename)")!,
                    destinationFilename: talkerFilename),
                ModelFile(
                    remoteURL: URL(string: "\(hf)/Serveurperso/Qwen3-TTS-GGUF/resolve/main/\(codecFilename)")!,
                    destinationFilename: codecFilename),
            ],
            destinationDirectory: qwenDirectory)
    }

    static let ttsAssets: [ModelAsset] = QwenTtsVariant.allCases.flatMap { variant in
        QwenTtsQuantization.allCases.map { ttsAsset(variant, quantization: $0) }
    }

    /// Audio8 URLs are intentionally unset until a versioned model release is
    /// configured. The asset remains visible so the UI can report an explicit
    /// unavailable/configuration state instead of falling back to Qwen.
    static let audio8Assets: [ModelAsset] = [
        ModelAsset(
            id: "tts.audio8.f32",
            title: "Audio8 (F32)",
            subtitle: "generator GGUF + codec GGUF + tokenizer.json",
            files: [
                ModelFile(remoteURL: nil, destinationFilename: audio8GeneratorFilename),
                ModelFile(remoteURL: nil, destinationFilename: audio8CodecFilename),
                ModelFile(remoteURL: nil, destinationFilename: audio8TokenizerFilename),
            ],
            destinationDirectory: audio8Directory),
    ]

    static func ttsAsset(for variant: QwenTtsVariant,
                         quantization: QwenTtsQuantization) -> ModelAsset? {
        ttsAssets.first { $0.id == "tts.\(variant.rawValue).\(quantization.rawValue)" }
    }

    static func audio8Resources(in directory: URL) -> Audio8ModelResources? {
        guard let (generator, codec) = audio8ResourcePair(in: directory) else { return nil }
        let tokenizer = directory.appendingPathComponent(audio8TokenizerFilename)
        guard FileManager.default.fileExists(atPath: tokenizer.path) else { return nil }
        return Audio8ModelResources(generatorURL: generator, codecURL: codec, tokenizerURL: tokenizer)
    }

    static func audio8ReadinessMessage(in directory: URL) -> String {
        let generators = audio8ResourceCandidates(in: directory,
                                                   exactName: audio8GeneratorFilename,
                                                   prefix: audio8GeneratorPrefix)
        let codecs = audio8ResourceCandidates(in: directory,
                                               exactName: audio8CodecFilename,
                                               prefix: audio8CodecPrefix)
        var missing: [String] = []
        if generators.isEmpty { missing.append("audio8-generator*.gguf") }
        if codecs.isEmpty { missing.append("audio8-codec*.gguf") }
        if !generators.isEmpty, !codecs.isEmpty, audio8ResourcePair(in: directory) == nil {
            missing.append("matching generator/codec version")
        }
        let tokenizer = directory.appendingPathComponent(audio8TokenizerFilename)
        if !FileManager.default.fileExists(atPath: tokenizer.path) {
            missing.append(audio8TokenizerFilename)
        }
        if missing.isEmpty { return "Audio8 model resources are ready." }
        return "Audio8 model resources are incomplete; missing: \(missing.joined(separator: ", "))."
    }

    static func audio8SttModelURL(in directory: URL) -> URL? {
        let candidates = audio8ResourceCandidates(in: directory,
                                                   exactName: audio8SttModelFilename,
                                                   prefix: audio8SttModelPrefix)
        return candidates.first
    }

    static func audio8SttReadinessMessage(in directory: URL) -> String {
        if audio8SttModelURL(in: directory) != nil {
            return "Audio8 ARK-ASR model is ready."
        }
        return "Audio8 ARK-ASR model is missing; add ark-asr-*.gguf to the Audio8 model directory."
    }

    private static func audio8ResourceCandidates(in directory: URL,
                                                 exactName: String,
                                                 prefix: String) -> [URL] {
        let fileManager = FileManager.default
        let exact = directory.appendingPathComponent(exactName)
        if fileManager.fileExists(atPath: exact.path) { return [exact] }
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return candidates
            .filter { $0.pathExtension.lowercased() == "gguf" && $0.deletingPathExtension().lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func audio8ResourcePair(in directory: URL) -> (URL, URL)? {
        let generators = audio8ResourceCandidates(in: directory,
                                                   exactName: audio8GeneratorFilename,
                                                   prefix: audio8GeneratorPrefix)
        let codecs = audio8ResourceCandidates(in: directory,
                                               exactName: audio8CodecFilename,
                                               prefix: audio8CodecPrefix)
        for generator in generators {
            let suffix = String(generator.deletingPathExtension().lastPathComponent.dropFirst(audio8GeneratorPrefix.count))
            if let codec = codecs.first(where: {
                let codecSuffix = String($0.deletingPathExtension().lastPathComponent.dropFirst(audio8CodecPrefix.count))
                return codecSuffix == suffix
            }) {
                return (generator, codec)
            }
        }
        return nil
    }
}
