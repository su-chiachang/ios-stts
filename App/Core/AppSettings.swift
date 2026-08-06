import Foundation
import ModelBundle

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
    var sttBackend: SttBackend {
        didSet { UserDefaults.standard.set(sttBackend.rawValue, forKey: Keys.sttBackend) }
    }
    var silenceHangMs: Double {
        didSet { UserDefaults.standard.set(silenceHangMs, forKey: Keys.silenceHangMs) }
    }
    var rmsThreshold: Double {
        didSet { UserDefaults.standard.set(rmsThreshold, forKey: Keys.rmsThreshold) }
    }
    var ttsBackend: TtsBackend {
        didSet { UserDefaults.standard.set(ttsBackend.rawValue, forKey: Keys.ttsBackend) }
    }
    var qwenModelVariant: QwenTtsVariant {
        didSet { UserDefaults.standard.set(qwenModelVariant.rawValue, forKey: Keys.qwenModelVariant) }
    }
    var qwenModelQuantization: QwenTtsQuantization {
        didSet { UserDefaults.standard.set(qwenModelQuantization.rawValue, forKey: Keys.qwenModelQuantization) }
    }
    var audio8ReferenceTranscript: String {
        didSet { UserDefaults.standard.set(audio8ReferenceTranscript, forKey: Keys.audio8ReferenceTranscript) }
    }
    var audio8TtsVariant: Audio8TtsVariant {
        didSet { UserDefaults.standard.set(audio8TtsVariant.rawValue, forKey: Keys.audio8TtsVariant) }
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
    /// Keep one security-scoped access per persisted bookmark. Re-resolving a
    /// bookmark on every SwiftUI refresh without balancing the access count
    /// eventually makes the selected directory inaccessible.
    private var scopedBookmarkURLs: [String: URL] = [:]

    private enum Keys {
        static let llmBaseURL = "llmBaseURL"
        static let llmAPIKey = "llmAPIKey"
        static let llmModel = "llmModel"
        static let systemPrompt = "systemPrompt"
        static let sttLocale = "sttLocale"
        static let sttBackend = "sttBackend"
        static let silenceHangMs = "silenceHangMs"
        static let rmsThreshold = "rmsThreshold"
        static let ttsBackend = "ttsBackend"
        static let parakeetBookmark = "parakeetModelBookmark"
        static let qwenBookmark = "qwenModelDirBookmark"
        static let audio8Bookmark = "audio8ModelDirBookmark"
        static let qwenModelVariant = "qwenModelVariant"
        static let qwenModelQuantization = "qwenModelQuantization"
        static let audio8ReferenceTranscript = "audio8ReferenceTranscript"
        static let audio8TtsVariant = "audio8TtsVariant"
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
        llmBaseURL = d.string(forKey: Keys.llmBaseURL) ?? "http://127.0.0.1:1234/v1"
        llmAPIKey = d.string(forKey: Keys.llmAPIKey) ?? ""
        llmModel = d.string(forKey: Keys.llmModel) ?? "gemma"
        systemPrompt = d.string(forKey: Keys.systemPrompt) ?? Self.defaultSystemPrompt
        sttLocale = d.string(forKey: Keys.sttLocale) ?? "auto"
        sttBackend = d.string(forKey: Keys.sttBackend).flatMap(SttBackend.init(rawValue:)) ?? .appleSpeech
        silenceHangMs = d.object(forKey: Keys.silenceHangMs) as? Double ?? 800
        rmsThreshold = d.object(forKey: Keys.rmsThreshold) as? Double ?? 0.015
        ttsBackend = d.string(forKey: Keys.ttsBackend).flatMap(TtsBackend.init(rawValue:)) ?? .appleSpeech
        qwenModelVariant = d.string(forKey: Keys.qwenModelVariant).flatMap(QwenTtsVariant.init(rawValue:)) ?? .base06b
        qwenModelQuantization = d.string(forKey: Keys.qwenModelQuantization).flatMap(QwenTtsQuantization.init(rawValue:)) ?? .q4_k_m
        audio8ReferenceTranscript = d.string(forKey: Keys.audio8ReferenceTranscript) ?? ""
        audio8TtsVariant = d.string(forKey: Keys.audio8TtsVariant).flatMap(Audio8TtsVariant.init(rawValue:)) ?? .f32Reference
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
    /// models/parakeet, models/qwentts, and models/audio8 layout used by the
    /// in-app catalog. See ModelCatalog.
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

    /// Returns the selected Audio8 directory even when its atomic resource
    /// group is incomplete, so Settings can show the actionable missing-file
    /// state instead of silently hiding the user's selection.
    func audio8ModelDirURL() -> URL {
        resolveBookmark(Keys.audio8Bookmark) ?? ModelCatalog.audio8Directory
    }

    func audio8ModelResources() -> Audio8ModelResources? {
        let directory = audio8ModelDirURL()
        guard let resources = ModelCatalog.audio8Resources(for: audio8TtsVariant, in: directory) else {
            return nil
        }
        // App-managed release bundles must retain their activation marker and
        // pass the full manifest/hash check immediately before native loading.
        // A user-selected directory is a deliberate manual-import path and is
        // still handed to Audio8Tts, whose native loader validates GGUF.
        if directory == ModelCatalog.audio8Directory,
           let asset = ModelCatalog.audio8Asset(for: audio8TtsVariant),
           asset.requiresIntegrity {
            guard ModelBundleVerifier.isActivated(asset.bundleSpecification, at: directory) else {
                return nil
            }
        }
        return resources
    }

    func audio8ModelReadinessMessage() -> String {
        let directory = audio8ModelDirURL()
        if let memoryMessage = audio8MemoryCompatibilityMessage() {
            return memoryMessage
        }
        if ModelCatalog.audio8Resources(for: audio8TtsVariant, in: directory) != nil {
            if audio8ModelResources() != nil {
                return "Audio8 \(audio8TtsVariant.displayName) resources are ready."
            }
            return "Audio8 \(audio8TtsVariant.displayName) files are present but the active bundle manifest/version/integrity check has not passed."
        }
        let readiness = ModelCatalog.audio8ReadinessMessage(for: audio8TtsVariant, in: directory)
        guard let asset = ModelCatalog.audio8Asset(for: audio8TtsVariant),
              !asset.isDownloadConfigured else { return readiness }
        return readiness + " In-app Audio8 release URLs and integrity metadata are not configured yet."
    }

    func audio8MemoryCompatibilityMessage() -> String? {
        let available = ProcessInfo.processInfo.physicalMemory
        let minimum = Audio8TtsVariant.minimumSupportedPhysicalMemoryBytes
        guard available >= minimum else {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .memory
            return "Audio8 \(audio8TtsVariant.displayName) requires at least \(formatter.string(fromByteCount: Int64(minimum))) unified memory; this device reports \(formatter.string(fromByteCount: Int64(available)))."
        }
        return nil
    }

    private func downloadedParakeetModelURL() -> URL? {
        let url = ModelCatalog.parakeetDirectory.appendingPathComponent(ModelCatalog.sttModelName)
        return (try? url.checkResourceIsReachable()) == true ? url : nil
    }

    private func downloadedQwenModelDirURL() -> URL? {
        guard let asset = ModelCatalog.ttsAsset(for: qwenModelVariant, quantization: qwenModelQuantization) else { return nil }
        let fm = FileManager.default
        let ready = asset.files.allSatisfy {
            fm.fileExists(atPath: asset.destinationDirectory.appendingPathComponent($0.destinationFilename).path)
        }
        return ready ? ModelCatalog.qwenDirectory : nil
    }

    func setParakeetModel(_ url: URL) throws { try storeBookmark(url, key: Keys.parakeetBookmark) }
    func setQwenModelDir(_ url: URL) throws { try storeBookmark(url, key: Keys.qwenBookmark) }
    func setAudio8ModelDir(_ url: URL) throws { try storeBookmark(url, key: Keys.audio8Bookmark) }

    private func storeBookmark(_ url: URL, key: String) throws {
        // macOS can intermittently fail to retrieve the app-scope key here
        // (NSCocoaErrorDomain 256) even when the user selected the URL with
        // NSOpenPanel. In that case, preserve the panel's implicit security
        // scope instead. It provides the same read access this app needs and
        // avoids relying on ScopedBookmarkAgent's app-scope key. iOS doesn't
        // have app-scope bookmarks at all (.withSecurityScope is unavailable
        // there) — .fileImporter's document-scope security already covers it.
        let data: Data
        #if os(macOS)
        do {
            data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        } catch {
            data = try url.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        }
        #else
        data = try url.bookmarkData(options: [],
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
        #endif
        if let previous = scopedBookmarkURLs.removeValue(forKey: key) {
            previous.stopAccessingSecurityScopedResource()
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func resolveBookmark(_ key: String) -> URL? {
        if let cached = scopedBookmarkURLs[key] { return cached }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        #if os(macOS)
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        #else
        let url = try? URL(resolvingBookmarkData: data, options: [],
                            relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard let url, url.startAccessingSecurityScopedResource() else { return nil }
        scopedBookmarkURLs[key] = url
        return url
    }

    deinit {
        for url in scopedBookmarkURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
