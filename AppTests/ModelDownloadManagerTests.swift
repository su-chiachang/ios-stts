import CryptoKit
import Foundation
import ModelBundle
import XCTest
@testable import STTS

@MainActor
final class ModelDownloadManagerTests: XCTestCase {
    func testPublishableBundleDownloadsVerifiesAndActivatesAtomically() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payloads: [String: Data] = [
            "generator.gguf": Data("generator-payload".utf8),
            "codec.gguf": Data("codec-payload".utf8),
            "tokenizer.json": Data("tokenizer-payload".utf8),
        ]
        StubModelDownloadURLProtocol.install(payloads)
        defer { StubModelDownloadURLProtocol.reset() }

        let asset = ModelAsset(
            id: "tts.audio8.test",
            version: "test-v1",
            title: "Audio8 test bundle",
            subtitle: "generator + codec + tokenizer",
            files: payloads.map { filename, data in
                ModelFile(
                    remoteURL: URL(string: "https://models.example/audio8/\(filename)"),
                    destinationFilename: filename,
                    expectedBytes: Int64(data.count),
                    sha256: sha256(data))
            }.sorted { $0.destinationFilename < $1.destinationFilename },
            destinationDirectory: root,
            requiresIntegrity: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubModelDownloadURLProtocol.self]
        let manager = ModelDownloadManager(configuration: configuration)

        manager.start(asset)
        try await waitUntilCompleted(asset, manager: manager)

        guard case .completed = manager.state(for: asset) else {
            XCTFail("download state was not completed")
            return
        }
        XCTAssertTrue(ModelBundleVerifier.isActivated(asset.bundleSpecification, at: root))
        for filename in payloads.keys {
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent(filename)),
                payloads[filename])
        }
    }

    private func waitUntilCompleted(_ asset: ModelAsset,
                                    manager: ModelDownloadManager) async throws {
        for _ in 0..<100 {
            switch manager.state(for: asset) {
            case .completed:
                return
            case .failed(let message):
                XCTFail("download failed: \(message)")
                return
            default:
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        XCTFail("download did not complete")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio8-download-manager-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }
}

private final class StubModelDownloadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var payloads: [URL: Data] = [:]

    static func install(_ payloads: [String: Data]) {
        lock.lock()
        defer { lock.unlock() }
        self.payloads = Dictionary(uniqueKeysWithValues: payloads.map { filename, data in
            (URL(string: "https://models.example/audio8/\(filename)")!, data)
        })
    }

    static func reset() {
        lock.lock()
        payloads.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "models.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let payload = Self.payloads[url]
        Self.lock.unlock()
        guard let payload else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(payload.count)"])
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
