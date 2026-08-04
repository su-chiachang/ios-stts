import Foundation
import XCTest
@testable import STTS

final class Audio8ReleaseManifestTests: XCTestCase {
    func testPublishableManifestMapsBothBundlesToAtomicDownloadAssets() throws {
        let manifest = try Audio8ReleaseManifest(data: manifestData())
        let destination = URL(fileURLWithPath: "/tmp/audio8-models")

        let assets = try manifest.assets(destinationDirectory: destination)

        XCTAssertEqual(assets.map(\.id), [
            "tts.audio8.f32-reference",
            "tts.audio8.q8-0-hybrid",
        ])
        XCTAssertEqual(assets.map(\.files.count), [3, 3])
        XCTAssertTrue(assets.allSatisfy(\.isDownloadConfigured))
        XCTAssertEqual(assets[0].files[0].expectedBytes, 2_404_653_632)
        XCTAssertEqual(assets[0].files[0].sha256,
                       "d435f97a3f755a2b494ecefffda50631173db8275b5723f647d750c049039909")
        XCTAssertEqual(assets[1].files[0].remoteURL?.scheme, "https")
        XCTAssertEqual(assets[1].destinationDirectory, destination)
    }

    func testNonPublishableManifestCannotBecomeDownloadableAssets() throws {
        let manifest = try Audio8ReleaseManifest(data: manifestData(publishable: false))

        XCTAssertThrowsError(try manifest.assets(destinationDirectory: URL(fileURLWithPath: "/tmp/audio8-models"))) { error in
            XCTAssertEqual(error as? Audio8ReleaseManifestError, .notPublishable)
        }
    }

    func testManifestRejectsWrongExportDtype() {
        XCTAssertThrowsError(try Audio8ReleaseManifest(
            data: manifestData(q8ExportDtype: "F32"))) { error in
            XCTAssertEqual(error as? Audio8ReleaseManifestError,
                           .invalidBundle("tts.audio8.q8-0-hybrid"))
        }
    }

    func testManifestRejectsRemoteURLOutsideReleaseBase() {
        XCTAssertThrowsError(try Audio8ReleaseManifest(
            data: manifestData(remoteOutsideBase: true))) { error in
            XCTAssertEqual(error as? Audio8ReleaseManifestError,
                           .invalidBundle("tts.audio8.q8-0-hybrid"))
        }
    }

    func testBundledDefaultRemainsUnavailableWithoutPublishableRelease() {
        XCTAssertTrue(ModelCatalog.audio8Assets.allSatisfy { !$0.isDownloadConfigured })
    }

    private func manifestData(publishable: Bool = true,
                              q8ExportDtype: String = "Q8_0",
                              remoteOutsideBase: Bool = false) throws -> Data {
        let baseURL = "https://models.example/audio8/v1"
        let remoteURL: (String) -> Any = { filename in
            guard publishable else { return NSNull() }
            if remoteOutsideBase && filename.hasPrefix("audio8-generator-Q8") {
                return "https://other.example/audio8/\(filename)"
            }
            return "\(baseURL)/\(filename)"
        }
        let f32Generator = [
            "role": "generator",
            "artifact_filename": "audio8-generator-F32-f9612f13.gguf",
            "bytes": 2_404_653_632,
            "sha256": "d435f97a3f755a2b494ecefffda50631173db8275b5723f647d750c049039909",
            "destination_filename": "audio8-generator-F32.gguf",
            "remote_url": remoteURL("audio8-generator-F32-f9612f13.gguf"),
        ] as [String: Any]
        let q8Generator = [
            "role": "generator",
            "artifact_filename": "audio8-generator-Q8_0-hybrid-f9612f13.gguf",
            "bytes": 1_178_352_288,
            "sha256": "96fe2ed44114ecb6d8c8a0439a28052f0ec4895c06858dc0bb6b5dd1ca878512",
            "destination_filename": "audio8-generator-Q8_0-hybrid-v1.gguf",
            "remote_url": remoteURL("audio8-generator-Q8_0-hybrid-f9612f13.gguf"),
        ] as [String: Any]
        let f32Codec = [
            "role": "codec",
            "artifact_filename": "audio8-codec-F32-f9612f13.gguf",
            "bytes": 1_349_626_432,
            "sha256": "8bc2374d16a66b0d8cde4c8c0085173faeb3f9bca05347b93a601fb4998393d2",
            "destination_filename": "audio8-codec-F32.gguf",
            "remote_url": remoteURL("audio8-codec-F32-f9612f13.gguf"),
        ] as [String: Any]
        let q8Codec = [
            "role": "codec",
            "artifact_filename": "audio8-codec-F32-f9612f13.gguf",
            "bytes": 1_349_626_432,
            "sha256": "8bc2374d16a66b0d8cde4c8c0085173faeb3f9bca05347b93a601fb4998393d2",
            "destination_filename": "audio8-codec-F32-Q8_0-hybrid-v1.gguf",
            "remote_url": remoteURL("audio8-codec-F32-f9612f13.gguf"),
        ] as [String: Any]
        let tokenizer = [
            "role": "tokenizer",
            "artifact_filename": "tokenizer.json",
            "bytes": 12_217_872,
            "sha256": "f24e08099d45a8adf3f52f5f0b03276e433bb9d689bb15fcbcc48ce58744588b",
            "destination_filename": "tokenizer.json",
            "remote_url": remoteURL("tokenizer.json"),
        ] as [String: Any]
        let f32Bundle: [String: Any] = [
            "id": "tts.audio8.f32-reference",
            "version": "f32-reference-v1",
            "export_dtype": "F32",
            "files": [f32Generator, f32Codec, tokenizer],
        ]
        let q8Bundle: [String: Any] = [
            "id": "tts.audio8.q8-0-hybrid",
            "version": "q8-0-hybrid-v1",
            "export_dtype": q8ExportDtype,
            "files": [q8Generator, q8Codec, tokenizer],
        ]
        let document: [String: Any] = [
            "schema_version": 1,
            "model_id": "Audio8/Audio8-TTS-Preview-0.6b",
            "source_revision": "f9612f13a0ab40facf3d050fc908b9e6db05c2be",
            "release_base_url": publishable ? baseURL : NSNull(),
            "publishable": publishable,
            "bundles": [f32Bundle, q8Bundle],
        ]
        return try JSONSerialization.data(withJSONObject: document)
    }
}
