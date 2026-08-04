import Foundation
import ModelBundle

struct ModelFile: Hashable {
    let remoteURL: URL?
    let destinationFilename: String
    let expectedBytes: Int64?
    let sha256: String?

    init(remoteURL: URL?, destinationFilename: String,
         expectedBytes: Int64? = nil, sha256: String? = nil) {
        self.remoteURL = remoteURL
        self.destinationFilename = destinationFilename
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
    }
}

/// STT assets contain one file. Qwen assets are an inseparable talker/codec
/// pair; Audio8 TTS assets are an inseparable generator/codec/tokenizer group.
struct ModelAsset: Identifiable, Hashable {
    let id: String
    let version: String
    let title: String
    let subtitle: String
    let files: [ModelFile]
    let destinationDirectory: URL
    let requiresIntegrity: Bool

    init(id: String, version: String = "v1", title: String, subtitle: String,
         files: [ModelFile], destinationDirectory: URL, requiresIntegrity: Bool = false) {
        self.id = id
        self.version = version
        self.title = title
        self.subtitle = subtitle
        self.files = files
        self.destinationDirectory = destinationDirectory
        self.requiresIntegrity = requiresIntegrity
    }

    var isDownloadConfigured: Bool {
        files.allSatisfy { file in
            guard file.remoteURL != nil else { return false }
            guard requiresIntegrity else { return true }
            return file.expectedBytes != nil && file.sha256 != nil
        }
    }

    var configurationError: String? {
        guard !isDownloadConfigured else { return nil }
        return requiresIntegrity
            ? "Versioned release URL and integrity manifest are not configured for this model."
            : "Download URL is not configured for this model."
    }

    var bundleSpecification: ModelBundleSpecification {
        ModelBundleSpecification(
            identifier: id,
            version: version,
            requiresIntegrity: requiresIntegrity,
            files: files.map {
                ModelBundleFile(filename: $0.destinationFilename,
                                expectedBytes: $0.expectedBytes,
                                sha256: $0.sha256)
            })
    }
}

struct Audio8ModelResources: Hashable, Sendable {
    let generatorURL: URL
    let codecURL: URL
    let tokenizerURL: URL
}

enum Audio8TtsVariant: String, CaseIterable, Hashable, Sendable {
    case f32Reference = "f32-reference"
    case q8_0Hybrid = "q8-0-hybrid"

    static let minimumSupportedPhysicalMemoryBytes: UInt64 = 8 * 1024 * 1024 * 1024

    var displayName: String {
        switch self {
        case .f32Reference: "F32 reference"
        case .q8_0Hybrid: "Q8_0 hybrid"
        }
    }

    var exportDtype: String {
        switch self {
        case .f32Reference: "F32"
        case .q8_0Hybrid: "Q8_0"
        }
    }
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
    static let audio8Q8GeneratorFilename = "audio8-generator-Q8_0-hybrid-v1.gguf"
    static let audio8Q8CodecFilename = "audio8-codec-F32-Q8_0-hybrid-v1.gguf"
    static let audio8SttModelFilename = "ark-asr-0.6b-f16.gguf"
    private static let audio8GeneratorPrefix = "audio8-generator"
    private static let audio8CodecPrefix = "audio8-codec"
    private static let audio8Q8GeneratorPrefix = "audio8-generator-Q8_0-hybrid"
    private static let audio8Q8CodecPrefix = "audio8-codec-F32-Q8_0-hybrid"
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

    /// Safe local-audit fallback. A publishable `audio8-release-manifest.json`
    /// bundled by a release build takes precedence and supplies URLs, sizes,
    /// and SHA-256 values from the offline exporter handoff.
    private static let fallbackAudio8Assets: [ModelAsset] = [
        ModelAsset(
            id: "tts.audio8.f32-reference",
            version: "f32-reference-v1",
            title: "Audio8 (F32 reference)",
            subtitle: "generator GGUF + codec GGUF + tokenizer.json",
            files: [
                ModelFile(remoteURL: nil, destinationFilename: audio8GeneratorFilename),
                ModelFile(remoteURL: nil, destinationFilename: audio8CodecFilename),
                ModelFile(remoteURL: nil, destinationFilename: audio8TokenizerFilename),
            ],
            destinationDirectory: audio8Directory,
            requiresIntegrity: true),
        ModelAsset(
            id: "tts.audio8.q8-0-hybrid",
            version: "q8-0-hybrid-v1",
            title: "Audio8 (Q8_0 hybrid)",
            subtitle: "Q8_0 Generator + F32 Codec + tokenizer.json",
            files: [
                ModelFile(remoteURL: nil, destinationFilename: audio8Q8GeneratorFilename),
                ModelFile(remoteURL: nil, destinationFilename: audio8Q8CodecFilename),
                ModelFile(remoteURL: nil, destinationFilename: audio8TokenizerFilename),
            ],
            destinationDirectory: audio8Directory,
            requiresIntegrity: true),
    ]

    static let audio8Assets: [ModelAsset] =
        Audio8ReleaseManifest.bundledAssets(destinationDirectory: audio8Directory)
        ?? fallbackAudio8Assets

    static func audio8Asset(for variant: Audio8TtsVariant) -> ModelAsset? {
        audio8Assets.first { $0.id == "tts.audio8.\(variant.rawValue)" }
    }

    static func ttsAsset(for variant: QwenTtsVariant,
                         quantization: QwenTtsQuantization) -> ModelAsset? {
        ttsAssets.first { $0.id == "tts.\(variant.rawValue).\(quantization.rawValue)" }
    }

    static func audio8Resources(in directory: URL) -> Audio8ModelResources? {
        audio8Resources(for: .f32Reference, in: directory)
    }

    static func audio8Resources(for variant: Audio8TtsVariant,
                                in directory: URL) -> Audio8ModelResources? {
        guard let asset = audio8Asset(for: variant), asset.files.count == 3 else { return nil }
        let urls = asset.files.map { directory.appendingPathComponent($0.destinationFilename) }
        if urls.allSatisfy({ isRegularFile($0) }) {
            return Audio8ModelResources(generatorURL: urls[0], codecURL: urls[1], tokenizerURL: urls[2])
        }

        // Preserve the user-provided workflow: hand-built/reference exports
        // may carry a version suffix, while downloaded release bundles use
        // the exact catalog filenames above. The native loader still checks
        // GGUF metadata against the selected export dtype before loadModels()
        // accepts a discovered pair.
        guard let (generator, codec) = audio8ResourcePair(in: directory,
                                                          variant: variant) else { return nil }
        let tokenizer = directory.appendingPathComponent(audio8TokenizerFilename)
        guard isRegularFile(tokenizer) else { return nil }
        return Audio8ModelResources(generatorURL: generator,
                                    codecURL: codec,
                                    tokenizerURL: tokenizer)
    }

    static func audio8ReadinessMessage(in directory: URL) -> String {
        audio8ReadinessMessage(for: .f32Reference, in: directory)
    }

    static func audio8ReadinessMessage(for variant: Audio8TtsVariant,
                                       in directory: URL) -> String {
        if let asset = audio8Asset(for: variant) {
            if audio8Resources(for: variant, in: directory) != nil {
                return "Audio8 \(variant.displayName) resources are ready."
            }
            let missing = asset.files.compactMap { file -> String? in
                let url = directory.appendingPathComponent(file.destinationFilename)
                return FileManager.default.fileExists(atPath: url.path) ? nil : file.destinationFilename
            }
            return "Audio8 \(variant.displayName) resources are incomplete; missing: \(missing.joined(separator: ", "))."
        }
        return "Audio8 \(variant.displayName) resources are unavailable."
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
        let exact = directory.appendingPathComponent(exactName)
        if isRegularFile(exact) { return [exact] }
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return candidates
            .filter {
                $0.pathExtension.lowercased() == "gguf" &&
                isRegularFile($0) &&
                $0.deletingPathExtension().lastPathComponent.hasPrefix(prefix)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private static func audio8ResourcePair(in directory: URL,
                                           variant: Audio8TtsVariant) -> (URL, URL)? {
        let generatorPrefix = variant == .q8_0Hybrid
            ? audio8Q8GeneratorPrefix
            : audio8GeneratorPrefix
        let codecPrefix = variant == .q8_0Hybrid
            ? audio8Q8CodecPrefix
            : audio8CodecPrefix
        let generators = audio8ResourceCandidates(in: directory,
                                                   exactName: variant == .q8_0Hybrid
                                                       ? audio8Q8GeneratorFilename
                                                       : audio8GeneratorFilename,
                                                   prefix: generatorPrefix)
        let codecs = audio8ResourceCandidates(in: directory,
                                               exactName: variant == .q8_0Hybrid
                                                   ? audio8Q8CodecFilename
                                                   : audio8CodecFilename,
                                               prefix: codecPrefix)
        var pairs: [(generator: URL, codec: URL)] = []
        for generator in generators {
            let suffix = String(generator.deletingPathExtension().lastPathComponent.dropFirst(generatorPrefix.count))
            let matches = codecs.filter {
                let codecSuffix = String($0.deletingPathExtension().lastPathComponent.dropFirst(codecPrefix.count))
                return codecSuffix == suffix
            }
            if matches.count == 1, let codec = matches.first {
                pairs.append((generator, codec))
            }
        }
        return pairs.count == 1 ? pairs[0] : nil
    }
}
