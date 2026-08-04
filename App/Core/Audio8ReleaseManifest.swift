import Foundation

enum Audio8ReleaseManifestError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case invalidSchemaVersion
    case invalidModelID
    case invalidSourceRevision
    case invalidBundle(String)
    case notPublishable

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Audio8 release manifest is not valid JSON."
        case .invalidSchemaVersion:
            "Audio8 release manifest schema version is unsupported."
        case .invalidModelID:
            "Audio8 release manifest identifies an unsupported model."
        case .invalidSourceRevision:
            "Audio8 release manifest source revision is not pinned."
        case .invalidBundle(let identifier):
            "Audio8 release manifest bundle is invalid: \(identifier)."
        case .notPublishable:
            "Audio8 release manifest has no publishable download URLs."
        }
    }
}

/// The App-side view of the JSON handoff emitted by
/// `audio8_release_manifest.py`. The manifest is deliberately separate from
/// the Swift catalog so a release build can replace only this resource after
/// the offline GGUF artifacts have been hosted.
struct Audio8ReleaseManifest: Sendable {
    static let expectedSchemaVersion = 1
    static let expectedModelID = "Audio8/Audio8-TTS-Preview-0.6b"
    static let expectedSourceRevision = "f9612f13a0ab40facf3d050fc908b9e6db05c2be"

    private struct Document: Decodable {
        let schemaVersion: Int
        let modelID: String
        let sourceRevision: String
        let releaseBaseURL: String?
        let publishable: Bool
        let bundles: [ReleaseBundle]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case modelID = "model_id"
            case sourceRevision = "source_revision"
            case releaseBaseURL = "release_base_url"
            case publishable
            case bundles
        }
    }

    private struct ReleaseBundle: Decodable, Sendable {
        let id: String
        let version: String
        let exportDtype: String
        let files: [ReleaseFile]

        enum CodingKeys: String, CodingKey {
            case id
            case version
            case exportDtype = "export_dtype"
            case files
        }
    }

    private struct ReleaseFile: Decodable, Sendable {
        let role: String
        let artifactFilename: String
        let bytes: Int64
        let sha256: String
        let destinationFilename: String
        let remoteURLString: String?

        enum CodingKeys: String, CodingKey {
            case role
            case artifactFilename = "artifact_filename"
            case bytes
            case sha256
            case destinationFilename = "destination_filename"
            case remoteURLString = "remote_url"
        }

        var remoteURL: URL? {
            guard let remoteURLString,
                  let url = URL(string: remoteURLString),
                  url.scheme?.lowercased() == "https",
                  url.host != nil else { return nil }
            return url
        }
    }

    private let document: Document

    init(data: Data) throws {
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw Audio8ReleaseManifestError.invalidJSON
        }
        try validate(document)
    }

    /// Converts a validated publishable manifest into the existing atomic
    /// ModelAsset representation consumed by ModelDownloadManager.
    func assets(destinationDirectory: URL) throws -> [ModelAsset] {
        guard document.publishable else {
            throw Audio8ReleaseManifestError.notPublishable
        }
        return document.bundles.map { bundle in
            let title: String
            let subtitle: String
            if bundle.exportDtype == "F32" {
                title = "Audio8 (F32 reference)"
                subtitle = "Generator F32 + Codec F32 + tokenizer.json"
            } else {
                title = "Audio8 (Q8_0 hybrid)"
                subtitle = "Q8_0 Generator + F32 Codec + tokenizer.json"
            }
            return ModelAsset(
                id: bundle.id,
                version: bundle.version,
                title: title,
                subtitle: subtitle,
                files: bundle.files.map {
                    ModelFile(remoteURL: $0.remoteURL,
                              destinationFilename: $0.destinationFilename,
                              expectedBytes: $0.bytes,
                              sha256: $0.sha256)
                },
                destinationDirectory: destinationDirectory,
                requiresIntegrity: true)
        }
    }

    /// A missing or local-audit manifest is safe: it leaves the built-in
    /// unavailable catalog in place instead of enabling unverified downloads.
    static func bundledAssets(destinationDirectory: URL) -> [ModelAsset]? {
        guard let url = Bundle.main.url(forResource: "audio8-release-manifest",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? Audio8ReleaseManifest(data: data),
              let assets = try? manifest.assets(destinationDirectory: destinationDirectory) else {
            return nil
        }
        return assets
    }

    private func validate(_ document: Document) throws {
        guard document.schemaVersion == Self.expectedSchemaVersion else {
            throw Audio8ReleaseManifestError.invalidSchemaVersion
        }
        guard document.modelID == Self.expectedModelID else {
            throw Audio8ReleaseManifestError.invalidModelID
        }
        guard document.sourceRevision == Self.expectedSourceRevision else {
            throw Audio8ReleaseManifestError.invalidSourceRevision
        }

        let expectedBundles: [(id: String, version: String, dtype: String,
                               files: [(role: String, destination: String)])] = [
            ("tts.audio8.f32-reference", "f32-reference-v1", "F32", [
                ("generator", "audio8-generator-F32.gguf"),
                ("codec", "audio8-codec-F32.gguf"),
                ("tokenizer", "tokenizer.json"),
            ]),
            ("tts.audio8.q8-0-hybrid", "q8-0-hybrid-v1", "Q8_0", [
                ("generator", "audio8-generator-Q8_0-hybrid-v1.gguf"),
                ("codec", "audio8-codec-F32-Q8_0-hybrid-v1.gguf"),
                ("tokenizer", "tokenizer.json"),
            ]),
        ]
        guard document.bundles.count == expectedBundles.count else {
            throw Audio8ReleaseManifestError.invalidBundle("bundle count")
        }

        for expected in expectedBundles {
            guard let bundle = document.bundles.first(where: { $0.id == expected.id }),
                  bundle.version == expected.version,
                  bundle.exportDtype == expected.dtype,
                  bundle.files.count == expected.files.count else {
                throw Audio8ReleaseManifestError.invalidBundle(expected.id)
            }
            for (file, expectedFile) in zip(bundle.files, expected.files) {
                guard file.role == expectedFile.role,
                      file.destinationFilename == expectedFile.destination,
                      file.bytes > 0,
                      file.sha256.count == 64,
                      file.sha256 == file.sha256.lowercased(),
                      file.sha256.allSatisfy({ $0.isHexDigit }),
                      file.remoteURL != nil || !document.publishable else {
                    throw Audio8ReleaseManifestError.invalidBundle(expected.id)
                }
            }
        }

        if document.publishable {
            guard let releaseBaseURL = document.releaseBaseURL,
                  let url = URL(string: releaseBaseURL),
                  url.scheme?.lowercased() == "https",
                  url.host != nil else {
                throw Audio8ReleaseManifestError.invalidBundle("release_base_url")
            }
        } else if document.releaseBaseURL != nil {
            throw Audio8ReleaseManifestError.invalidBundle("release_base_url")
        }
    }
}
