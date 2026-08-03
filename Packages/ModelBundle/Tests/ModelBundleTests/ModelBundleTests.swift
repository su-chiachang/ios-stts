import Foundation
import XCTest
@testable import ModelBundle

final class ModelBundleTests: XCTestCase {
    private let helloSHA256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    func testValidBundlePassesSizeAndSHA256Verification() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello".utf8).write(to: directory.appendingPathComponent("model.gguf"))

        let bundle = ModelBundleSpecification(
            identifier: "audio8.q8.hybrid.v1",
            version: "q8-0-hybrid-v1",
            requiresIntegrity: true,
            files: [ModelBundleFile(
                filename: "model.gguf",
                expectedBytes: 5,
                sha256: helloSHA256)])

        XCTAssertNoThrow(try ModelBundleVerifier.verify(bundle, at: directory))
    }

    func testSizeMismatchMakesBundleUnavailable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello".utf8).write(to: directory.appendingPathComponent("model.gguf"))

        let bundle = ModelBundleSpecification(
            identifier: "audio8.q8.hybrid.v1",
            requiresIntegrity: true,
            files: [ModelBundleFile(
                filename: "model.gguf",
                expectedBytes: 6,
                sha256: helloSHA256)])

        XCTAssertThrowsError(try ModelBundleVerifier.verify(bundle, at: directory)) { error in
            XCTAssertEqual(error as? ModelBundleVerificationError,
                           .sizeMismatch(filename: "model.gguf", expected: 6, actual: 5))
        }
    }

    func testHashMismatchMakesBundleUnavailable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello".utf8).write(to: directory.appendingPathComponent("model.gguf"))

        let bundle = ModelBundleSpecification(
            identifier: "audio8.q8.hybrid.v1",
            requiresIntegrity: true,
            files: [ModelBundleFile(
                filename: "model.gguf",
                expectedBytes: 5,
                sha256: String(repeating: "0", count: 64))])

        XCTAssertThrowsError(try ModelBundleVerifier.verify(bundle, at: directory)) { error in
            XCTAssertEqual(error as? ModelBundleVerificationError,
                           .hashMismatch(filename: "model.gguf"))
        }
    }

    func testIntegrityIsRequiredForStrictBundle() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello".utf8).write(to: directory.appendingPathComponent("model.gguf"))

        let bundle = ModelBundleSpecification(
            identifier: "audio8.q8.hybrid.v1",
            requiresIntegrity: true,
            files: [ModelBundleFile(filename: "model.gguf")])

        XCTAssertThrowsError(try ModelBundleVerifier.verify(bundle, at: directory)) { error in
            XCTAssertEqual(error as? ModelBundleVerificationError,
                           .missingIntegrity(filename: "model.gguf"))
        }
    }

    func testActivationMovesVerifiedFilesAndWritesCompletionMarkerLast() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: staging.appendingPathComponent("model.gguf"))

        let bundle = ModelBundleSpecification(
            identifier: "audio8.q8.hybrid.v1",
            version: "q8-0-hybrid-v1",
            requiresIntegrity: true,
            files: [ModelBundleFile(
                filename: "model.gguf",
                expectedBytes: 5,
                sha256: helloSHA256)])

        XCTAssertFalse(ModelBundleVerifier.isActivated(bundle, at: destination))
        try ModelBundleVerifier.activate(bundle, from: staging, to: destination)

        XCTAssertTrue(ModelBundleVerifier.isActivated(bundle, at: destination))
        XCTAssertNoThrow(try ModelBundleVerifier.verifyActivated(bundle, at: destination))
        let marker = destination.appendingPathComponent(ModelBundleVerifier.markerFilename(for: bundle))
        XCTAssertEqual(try String(contentsOf: marker), "audio8.q8.hybrid.v1\nq8-0-hybrid-v1")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("model.gguf")), "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        try Data("hallo".utf8).write(to: destination.appendingPathComponent("model.gguf"))
        XCTAssertFalse(ModelBundleVerifier.isActivated(bundle, at: destination))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }
}
