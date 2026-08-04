import XCTest
@testable import STTS

final class ModelCatalogTests: XCTestCase {
    func testVersionedF32ReferenceResourcesAreDiscoveredAsOnePair() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let generator = directory.appendingPathComponent(
            "audio8-generator-F32-f9612f13.gguf")
        let codec = directory.appendingPathComponent(
            "audio8-codec-F32-f9612f13.gguf")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        try Data("generator".utf8).write(to: generator)
        try Data("codec".utf8).write(to: codec)
        try Data("tokenizer".utf8).write(to: tokenizer)

        let resources = ModelCatalog.audio8Resources(for: .f32Reference,
                                                     in: directory)

        XCTAssertEqual(resources?.generatorURL.lastPathComponent,
                       generator.lastPathComponent)
        XCTAssertEqual(resources?.codecURL.lastPathComponent,
                       codec.lastPathComponent)
        XCTAssertEqual(resources?.tokenizerURL.lastPathComponent,
                       tokenizer.lastPathComponent)
    }

    func testVersionedQ8HybridResourcesAreDiscoveredAsOnePair() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let generator = directory.appendingPathComponent(
            "audio8-generator-Q8_0-hybrid-f9612f13.gguf")
        let codec = directory.appendingPathComponent(
            "audio8-codec-F32-Q8_0-hybrid-f9612f13.gguf")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        try Data("generator".utf8).write(to: generator)
        try Data("codec".utf8).write(to: codec)
        try Data("tokenizer".utf8).write(to: tokenizer)

        let resources = ModelCatalog.audio8Resources(for: .q8_0Hybrid,
                                                     in: directory)

        XCTAssertEqual(resources?.generatorURL.lastPathComponent,
                       generator.lastPathComponent)
        XCTAssertEqual(resources?.codecURL.lastPathComponent,
                       codec.lastPathComponent)
        XCTAssertEqual(resources?.tokenizerURL.lastPathComponent,
                       tokenizer.lastPathComponent)
    }

    func testAmbiguousVersionedQ8HybridPairsAreNotSelected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for revision in ["f9612f13", "other-revision"] {
            try Data("generator".utf8).write(to: directory.appendingPathComponent(
                "audio8-generator-Q8_0-hybrid-\(revision).gguf"))
            try Data("codec".utf8).write(to: directory.appendingPathComponent(
                "audio8-codec-F32-Q8_0-hybrid-\(revision).gguf"))
        }
        try Data("tokenizer".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))

        XCTAssertNil(ModelCatalog.audio8Resources(for: .q8_0Hybrid, in: directory))
    }

    func testMismatchedVersionedQ8HybridPairIsNotSelected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("generator".utf8).write(to: directory.appendingPathComponent(
            "audio8-generator-Q8_0-hybrid-generator-revision.gguf"))
        try Data("codec".utf8).write(to: directory.appendingPathComponent(
            "audio8-codec-F32-Q8_0-hybrid-codec-revision.gguf"))
        try Data("tokenizer".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))

        XCTAssertNil(ModelCatalog.audio8Resources(for: .q8_0Hybrid, in: directory))
    }

    func testVersionedPairWithoutTokenizerIsNotReady() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("generator".utf8).write(to: directory.appendingPathComponent(
            "audio8-generator-Q8_0-hybrid-f9612f13.gguf"))
        try Data("codec".utf8).write(to: directory.appendingPathComponent(
            "audio8-codec-F32-Q8_0-hybrid-f9612f13.gguf"))

        XCTAssertNil(ModelCatalog.audio8Resources(for: .q8_0Hybrid, in: directory))
    }

    func testDirectoryWithCanonicalGeneratorNameIsNotReady() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(
                "audio8-generator-Q8_0-hybrid-v1.gguf"),
            withIntermediateDirectories: true)
        try Data("codec".utf8).write(to: directory.appendingPathComponent(
            "audio8-codec-F32-Q8_0-hybrid-v1.gguf"))
        try Data("tokenizer".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))

        XCTAssertNil(ModelCatalog.audio8Resources(for: .q8_0Hybrid, in: directory))
    }

    func testVersionedPairWithTokenizerDirectoryIsNotReady() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("generator".utf8).write(to: directory.appendingPathComponent(
            "audio8-generator-Q8_0-hybrid-f9612f13.gguf"))
        try Data("codec".utf8).write(to: directory.appendingPathComponent(
            "audio8-codec-F32-Q8_0-hybrid-f9612f13.gguf"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("tokenizer.json"),
            withIntermediateDirectories: true)

        XCTAssertNil(ModelCatalog.audio8Resources(for: .q8_0Hybrid, in: directory))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio8-model-catalog-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }
}
