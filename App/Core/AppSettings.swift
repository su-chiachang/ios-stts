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
        qwenModelVariant = d.string(forKey: Keys.qwenModelVariant).flatMap(QwenTtsVariant.init(rawValue:)) ?? .q8_0
    }

    // MARK: - Security-scoped model paths

    func parakeetModelURL() -> URL? { resolveBookmark(Keys.parakeetBookmark) }
    func qwenModelDirURL() -> URL? { resolveBookmark(Keys.qwenBookmark) }

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
