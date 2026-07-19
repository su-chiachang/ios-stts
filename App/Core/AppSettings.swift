import Foundation

/// User-configurable settings, persisted to UserDefaults. Model directories
/// are chosen via NSOpenPanel (sandboxed) and kept as security-scoped
/// bookmarks so we can re-access them across launches.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var llmBaseURL: String {
        didSet { UserDefaults.standard.set(llmBaseURL, forKey: Keys.llmBaseURL) }
    }
    var llmAPIKey: String {
        didSet { UserDefaults.standard.set(llmAPIKey, forKey: Keys.llmAPIKey) }
    }
    var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: Keys.llmModel) }
    }
    var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    var sttLocale: String {
        didSet { UserDefaults.standard.set(sttLocale, forKey: Keys.sttLocale) }
    }
    var silenceHangMs: Double {
        didSet { UserDefaults.standard.set(silenceHangMs, forKey: Keys.silenceHangMs) }
    }
    var rmsThreshold: Double {
        didSet { UserDefaults.standard.set(rmsThreshold, forKey: Keys.rmsThreshold) }
    }
    var qwenModelVariant: QwenTtsVariant {
        didSet { UserDefaults.standard.set(qwenModelVariant.rawValue, forKey: Keys.qwenModelVariant) }
    }

    /// When on, typed text is read aloud verbatim in the custom voice instead
    /// of being sent to the assistant LLM (the "speak as me" path).
    var readAloudMode: Bool {
        didSet { UserDefaults.standard.set(readAloudMode, forKey: Keys.readAloudMode) }
    }
    /// Display name of the imported custom voice (empty = none).
    private(set) var customVoiceName: String {
        didSet { UserDefaults.standard.set(customVoiceName, forKey: Keys.customVoiceName) }
    }
    /// Filename (under `customVoiceDirectory`) of the reference WAV. Uniquely
    /// named per import so a replaced voice never collides with a cached
    /// embedding (see QwenTts). Empty = none.
    private(set) var customVoiceFilename: String {
        didSet { UserDefaults.standard.set(customVoiceFilename, forKey: Keys.customVoiceFilename) }
    }

    private enum Keys {
        static let llmBaseURL = "llmBaseURL"
        static let llmAPIKey = "llmAPIKey"
        static let llmModel = "llmModel"
        static let systemPrompt = "systemPrompt"
        static let sttLocale = "sttLocale"
        static let silenceHangMs = "silenceHangMs"
        static let rmsThreshold = "rmsThreshold"
        static let parakeetBookmark = "parakeetModelBookmark"
        static let qwenBookmark = "qwenModelDirBookmark"
        static let qwenModelVariant = "qwenModelVariant"
        static let readAloudMode = "readAloudMode"
        static let customVoiceName = "customVoiceName"
        static let customVoiceFilename = "customVoiceFilename"
    }

    static let defaultSystemPrompt = """
    You are a voice assistant in a spoken conversation. Reply concisely \
    (1-3 short sentences), in the same language the user spoke — Chinese \
    or English. No markdown, no lists, no emojis.
    """

    private init() {
        let d = UserDefaults.standard
        llmBaseURL = d.string(forKey: Keys.llmBaseURL) ?? "http://127.0.0.1:8080/v1"
        llmAPIKey = d.string(forKey: Keys.llmAPIKey) ?? ""
        llmModel = d.string(forKey: Keys.llmModel) ?? "gemma"
        systemPrompt = d.string(forKey: Keys.systemPrompt) ?? Self.defaultSystemPrompt
        sttLocale = d.string(forKey: Keys.sttLocale) ?? "auto"
        silenceHangMs = d.object(forKey: Keys.silenceHangMs) as? Double ?? 800
        rmsThreshold = d.object(forKey: Keys.rmsThreshold) as? Double ?? 0.015
        qwenModelVariant = d.string(forKey: Keys.qwenModelVariant).flatMap(QwenTtsVariant.init(rawValue:)) ?? .base06bQ8
        readAloudMode = d.bool(forKey: Keys.readAloudMode)
        customVoiceName = d.string(forKey: Keys.customVoiceName) ?? ""
        customVoiceFilename = d.string(forKey: Keys.customVoiceFilename) ?? ""
    }

    // MARK: - Model locations
    //
    // Two ways a model can end up configured: the user points at an
    // arbitrary file/folder via NSOpenPanel (stored as a security-scoped
    // bookmark), or it was fetched in-app by the Download Models UI into
    // this app's own sandbox container (needs no bookmark — the app always
    // owns that directory). A bookmark, if set, wins.

    /// Root directory downloaded models live under, mirroring the
    /// models/parakeet and models/qwen3tts layout scripts/fetch-models.sh
    /// uses in a dev checkout. See ModelCatalog.
    static var modelsRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("STTS/models", isDirectory: true)
    }

    /// Directory the imported custom-voice reference WAV lives in. Inside the
    /// app's own container, so it needs no security-scoped bookmark.
    static var customVoiceDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("STTS/customVoice", isDirectory: true)
    }

    /// The imported reference WAV, or nil if none is set (or the file is gone).
    func customVoiceReferenceURL() -> URL? {
        guard !customVoiceFilename.isEmpty else { return nil }
        let url = Self.customVoiceDirectory.appendingPathComponent(customVoiceFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Imports `sourceURL` as the custom voice, converting it to the reference
    /// WAV format and recording it, replacing any previous voice. Returns the
    /// on-disk reference URL.
    @discardableResult
    func importCustomVoice(from sourceURL: URL, displayName: String) throws -> URL {
        let dir = Self.customVoiceDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "reference-\(UUID().uuidString).wav"
        let destination = dir.appendingPathComponent(filename)
        try ReferenceAudioImporter.writeReferenceWav(from: sourceURL, to: destination)
        let previous = customVoiceFilename
        customVoiceFilename = filename
        customVoiceName = displayName
        if !previous.isEmpty, previous != filename {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(previous))
        }
        return destination
    }

    /// Removes the custom voice and deletes its reference WAV.
    func clearCustomVoice() {
        let filename = customVoiceFilename
        customVoiceFilename = ""
        customVoiceName = ""
        if !filename.isEmpty {
            try? FileManager.default.removeItem(at: Self.customVoiceDirectory.appendingPathComponent(filename))
        }
    }

    func parakeetModelURL() -> URL? {
        resolveBookmark(Keys.parakeetBookmark) ?? downloadedParakeetModelURL()
    }
    func qwenModelDirURL() -> URL? {
        resolveBookmark(Keys.qwenBookmark) ?? downloadedQwenModelDirURL()
    }

    private func downloadedParakeetModelURL() -> URL? {
        let url = ModelCatalog.parakeetDirectory.appendingPathComponent("nemotron-3.5-asr-streaming-0.6b-q8_0.gguf")
        return (try? url.checkResourceIsReachable()) == true ? url : nil
    }

    private func downloadedQwenModelDirURL() -> URL? {
        guard let asset = ModelCatalog.ttsAsset(for: qwenModelVariant) else { return nil }
        let fm = FileManager.default
        let ready = asset.files.allSatisfy {
            fm.fileExists(atPath: asset.destinationDirectory.appendingPathComponent($0.destinationFilename).path)
        }
        return ready ? ModelCatalog.qwenDirectory : nil
    }

    func setParakeetModel(_ url: URL) throws { try storeBookmark(url, key: Keys.parakeetBookmark) }
    func setQwenModelDir(_ url: URL) throws { try storeBookmark(url, key: Keys.qwenBookmark) }

    private func storeBookmark(_ url: URL, key: String) throws {
        // macOS can intermittently fail to retrieve the app-scope key here
        // (NSCocoaErrorDomain 256) even when the user selected the URL with
        // NSOpenPanel. In that case, preserve the panel's implicit security
        // scope instead. It provides the same read access this app needs and
        // avoids relying on ScopedBookmarkAgent's app-scope key.
        let data: Data
        do {
            data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        } catch {
            data = try url.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func resolveBookmark(_ key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url, url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }
}
