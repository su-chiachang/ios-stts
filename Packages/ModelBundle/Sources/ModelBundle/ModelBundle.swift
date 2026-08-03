import CryptoKit
import Foundation

public struct ModelBundleFile: Hashable, Sendable {
    public let filename: String
    public let expectedBytes: Int64?
    public let sha256: String?

    public init(filename: String, expectedBytes: Int64? = nil, sha256: String? = nil) {
        self.filename = filename
        self.expectedBytes = expectedBytes
        self.sha256 = sha256?.lowercased()
    }
}

public struct ModelBundleSpecification: Hashable, Sendable {
    public let identifier: String
    public let version: String
    public let requiresIntegrity: Bool
    public let files: [ModelBundleFile]

    public init(identifier: String,
                version: String = "v1",
                requiresIntegrity: Bool,
                files: [ModelBundleFile]) {
        self.identifier = identifier
        self.version = version
        self.requiresIntegrity = requiresIntegrity
        self.files = files
    }
}

public enum ModelBundleVerificationError: Error, Equatable, LocalizedError, Sendable {
    case duplicateFile(filename: String)
    case missingFile(filename: String)
    case notRegularFile(filename: String)
    case missingIntegrity(filename: String)
    case unreadableFile(filename: String)
    case sizeMismatch(filename: String, expected: Int64, actual: Int64)
    case hashMismatch(filename: String)
    case inactiveBundle(identifier: String, version: String)

    public var errorDescription: String? {
        switch self {
        case .duplicateFile(let filename): "Duplicate model bundle file: \(filename)"
        case .missingFile(let filename): "Missing model bundle file: \(filename)"
        case .notRegularFile(let filename): "Model bundle path is not a regular file: \(filename)"
        case .missingIntegrity(let filename): "Missing integrity metadata for: \(filename)"
        case .unreadableFile(let filename): "Unable to read model bundle file: \(filename)"
        case .sizeMismatch(let filename, let expected, let actual):
            "Size mismatch for \(filename): expected \(expected), got \(actual)"
        case .hashMismatch(let filename): "SHA-256 mismatch for: \(filename)"
        case .inactiveBundle(let identifier, let version):
            "Model bundle is not active: \(identifier) (\(version))"
        }
    }
}

public enum ModelBundleVerifier {
    public static func verify(_ specification: ModelBundleSpecification,
                              at directory: URL,
                              fileManager: FileManager = .default) throws {
        var names = Set<String>()
        for file in specification.files {
            guard names.insert(file.filename).inserted else {
                throw ModelBundleVerificationError.duplicateFile(filename: file.filename)
            }
            if specification.requiresIntegrity && (file.expectedBytes == nil || file.sha256 == nil) {
                throw ModelBundleVerificationError.missingIntegrity(filename: file.filename)
            }
            let url = directory.appendingPathComponent(file.filename)
            guard fileManager.fileExists(atPath: url.path) else {
                throw ModelBundleVerificationError.missingFile(filename: file.filename)
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            } catch {
                throw ModelBundleVerificationError.unreadableFile(filename: file.filename)
            }
            guard values.isRegularFile == true else {
                throw ModelBundleVerificationError.notRegularFile(filename: file.filename)
            }
            if let expectedBytes = file.expectedBytes {
                let actualBytes = Int64(values.fileSize ?? -1)
                guard actualBytes == expectedBytes else {
                    throw ModelBundleVerificationError.sizeMismatch(
                        filename: file.filename,
                        expected: expectedBytes,
                        actual: actualBytes)
                }
            }
            if let expectedHash = file.sha256 {
                let actualHash = try sha256(of: url, filename: file.filename)
                guard actualHash == expectedHash.lowercased() else {
                    throw ModelBundleVerificationError.hashMismatch(filename: file.filename)
                }
            }
        }
    }

    public static func isActivated(_ specification: ModelBundleSpecification,
                                   at directory: URL,
                                   fileManager: FileManager = .default) -> Bool {
        guard hasActivationMarker(specification, at: directory, fileManager: fileManager) else {
            return false
        }
        return (try? verify(specification, at: directory, fileManager: fileManager)) != nil
    }

    public static func hasActivationMarker(_ specification: ModelBundleSpecification,
                                           at directory: URL,
                                           fileManager: FileManager = .default) -> Bool {
        let marker = directory.appendingPathComponent(markerFilename(for: specification))
        guard let data = try? Data(contentsOf: marker),
              String(data: data, encoding: .utf8) == activationMarkerPayload(for: specification) else {
            return false
        }
        return specification.files.allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
        }
    }

    public static func verifyActivated(_ specification: ModelBundleSpecification,
                                       at directory: URL,
                                       fileManager: FileManager = .default) throws {
        guard hasActivationMarker(specification, at: directory, fileManager: fileManager) else {
            throw ModelBundleVerificationError.inactiveBundle(
                identifier: specification.identifier,
                version: specification.version)
        }
        try verify(specification, at: directory, fileManager: fileManager)
    }

    public static func activate(_ specification: ModelBundleSpecification,
                                from stagingDirectory: URL,
                                to destinationDirectory: URL,
                                fileManager: FileManager = .default) throws {
        try verify(specification, at: stagingDirectory, fileManager: fileManager)
        try fileManager.createDirectory(at: destinationDirectory,
                                         withIntermediateDirectories: true)
        let marker = destinationDirectory.appendingPathComponent(markerFilename(for: specification))
        try? fileManager.removeItem(at: marker)
        for file in specification.files {
            let source = stagingDirectory.appendingPathComponent(file.filename)
            let destination = destinationDirectory.appendingPathComponent(file.filename)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: source, to: destination)
        }
        try Data(activationMarkerPayload(for: specification).utf8)
            .write(to: marker, options: .atomic)
        try? fileManager.removeItem(at: stagingDirectory)
    }

    public static func markerFilename(for specification: ModelBundleSpecification) -> String {
        ".\(specification.identifier).complete"
    }

    private static func activationMarkerPayload(for specification: ModelBundleSpecification) -> String {
        "\(specification.identifier)\n\(specification.version)"
    }

    private static func sha256(of url: URL, filename: String) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ModelBundleVerificationError.unreadableFile(filename: filename)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw ModelBundleVerificationError.unreadableFile(filename: filename)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
