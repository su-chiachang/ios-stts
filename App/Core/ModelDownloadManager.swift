import Foundation

enum ModelDownloadState: Equatable {
    case notStarted
    case downloading(fraction: Double?, receivedBytes: Int64, totalBytes: Int64?)
    case completed
    case failed(String)
    case cancelled
}

/// Thread-safe task→asset lookup the URLSession delegate queue reads and
/// writes synchronously. `didFinishDownloadingTo` must move the temp file
/// before returning (the OS deletes it right after), and delegate callbacks
/// land on an arbitrary background queue, not the main actor — so this
/// can't be a `@MainActor`-isolated stored property.
private final class TaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var assetIDs: [Int: String] = [:]
    private var destinations: [Int: URL] = [:]

    func register(taskID: Int, assetID: String, destination: URL) {
        lock.lock(); defer { lock.unlock() }
        assetIDs[taskID] = assetID
        destinations[taskID] = destination
    }
    func assetID(for taskID: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return assetIDs[taskID]
    }
    func destination(for taskID: Int) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return destinations[taskID]
    }
    func clear(taskID: Int) {
        lock.lock(); defer { lock.unlock() }
        assetIDs.removeValue(forKey: taskID)
        destinations.removeValue(forKey: taskID)
    }
}

/// Downloads `ModelAsset`s (one or more files each) into their destination
/// directory, tracking per-asset progress for the Download Models UI.
/// Behaves like scripts/fetch-models.sh: skips files that already exist,
/// same source URLs, same on-disk layout — just driven from in-app UI with
/// per-row progress/cancel instead of a terminal.
@MainActor
@Observable
final class ModelDownloadManager: NSObject {
    static let shared = ModelDownloadManager()

    private(set) var states: [String: ModelDownloadState] = [:]

    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    @ObservationIgnored private let registry = TaskRegistry()

    private struct Job {
        let asset: ModelAsset
        var fileIndex = 0
        var writtenByFile: [Int64]
        var expectedByFile: [Int64?]
        var task: URLSessionDownloadTask?
    }
    @ObservationIgnored private var jobs: [String: Job] = [:]

    func state(for asset: ModelAsset) -> ModelDownloadState {
        states[asset.id] ?? (isDownloaded(asset) ? .completed : .notStarted)
    }

    func isDownloaded(_ asset: ModelAsset) -> Bool {
        let fm = FileManager.default
        return asset.files.allSatisfy {
            fm.fileExists(atPath: asset.destinationDirectory.appendingPathComponent($0.destinationFilename).path)
        }
    }

    func start(_ asset: ModelAsset) {
        guard jobs[asset.id] == nil else { return }
        try? FileManager.default.createDirectory(at: asset.destinationDirectory, withIntermediateDirectories: true)
        jobs[asset.id] = Job(asset: asset,
                              writtenByFile: Array(repeating: 0, count: asset.files.count),
                              expectedByFile: Array(repeating: nil, count: asset.files.count))
        states[asset.id] = .downloading(fraction: 0, receivedBytes: 0, totalBytes: nil)
        launchCurrentFile(assetID: asset.id)
    }

    func cancel(_ asset: ModelAsset) {
        guard let job = jobs[asset.id] else { return }
        job.task?.cancel()
        jobs[asset.id] = nil
        states[asset.id] = .cancelled
    }

    private func launchCurrentFile(assetID: String) {
        guard var job = jobs[assetID] else { return }
        guard job.fileIndex < job.asset.files.count else {
            jobs[assetID] = nil
            states[assetID] = .completed
            return
        }
        let file = job.asset.files[job.fileIndex]
        let dest = job.asset.destinationDirectory.appendingPathComponent(file.destinationFilename)
        // Same skip-if-exists behavior as fetch-models.sh's fetch().
        if (try? dest.checkResourceIsReachable()) == true {
            job.fileIndex += 1
            jobs[assetID] = job
            launchCurrentFile(assetID: assetID)
            return
        }
        let task = session.downloadTask(with: file.remoteURL)
        job.task = task
        jobs[assetID] = job
        registry.register(taskID: task.taskIdentifier, assetID: assetID, destination: dest)
        task.resume()
    }

    private func updateProgress(assetID: String, fileIndex: Int, written: Int64, expected: Int64?) {
        guard var job = jobs[assetID], job.fileIndex == fileIndex else { return }
        job.writtenByFile[fileIndex] = written
        job.expectedByFile[fileIndex] = expected
        jobs[assetID] = job
        let totalWritten = job.writtenByFile.reduce(0, +)
        let knownExpected = job.expectedByFile.compactMap { $0 }
        let totalExpected: Int64? = knownExpected.count == job.expectedByFile.count ? knownExpected.reduce(0, +) : nil
        let fraction = totalExpected.flatMap { $0 > 0 ? Double(totalWritten) / Double($0) : nil }
        states[assetID] = .downloading(fraction: fraction, receivedBytes: totalWritten, totalBytes: totalExpected)
    }

    private func advanceToNextFile(assetID: String) {
        guard var job = jobs[assetID] else { return }
        job.fileIndex += 1
        job.task = nil
        jobs[assetID] = job
        launchCurrentFile(assetID: assetID)
    }

    private func fail(assetID: String, error: Error) {
        jobs[assetID] = nil
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            states[assetID] = .cancelled
        } else {
            states[assetID] = .failed(error.localizedDescription)
        }
    }
}

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                 totalBytesExpectedToWrite: Int64) {
        guard let assetID = registry.assetID(for: downloadTask.taskIdentifier) else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        Task { @MainActor in
            guard let job = self.jobs[assetID] else { return }
            self.updateProgress(assetID: assetID, fileIndex: job.fileIndex, written: totalBytesWritten, expected: expected)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didFinishDownloadingTo location: URL) {
        let taskID = downloadTask.taskIdentifier
        guard let dest = registry.destination(for: taskID) else { return }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
        } catch {
            if let assetID = registry.assetID(for: taskID) {
                Task { @MainActor in self.fail(assetID: assetID, error: error) }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        guard let assetID = registry.assetID(for: taskID) else { return }
        registry.clear(taskID: taskID)
        Task { @MainActor in
            if let error {
                self.fail(assetID: assetID, error: error)
            } else {
                self.advanceToNextFile(assetID: assetID)
            }
        }
    }
}
