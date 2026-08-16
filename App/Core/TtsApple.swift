@preconcurrency import AVFAudio
import Combine
import Foundation

enum SpokenLanguage: String, Sendable {
    case en = "English"
    case zh = "Chinese"
    case ja = "Japanese"
}

struct TtsAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

enum AppleTtsError: Error, LocalizedError {
    case busy
    case invalidAudioBuffer
    case noAudio
    case sampleRateChanged

    var errorDescription: String? {
        switch self {
        case .busy:
            "Apple Speech is already synthesizing audio."
        case .invalidAudioBuffer:
            "Apple Speech returned an unsupported audio buffer."
        case .noAudio:
            "Apple Speech returned no audio. Check that a system voice is available."
        case .sampleRateChanged:
            "Apple Speech changed audio formats during synthesis."
        }
    }
}

enum AppleTtsVoiceQuality: Equatable, Sendable {
    case `default`
    case enhanced
    case other(Int)

    init(_ quality: AVSpeechSynthesisVoiceQuality) {
        if quality == .enhanced {
            self = .enhanced
        } else if quality == .default {
            self = .default
        } else {
            self = .other(quality.rawValue)
        }
    }

    var title: String {
        switch self {
        case .default: "Default"
        case .enhanced: "Enhanced"
        case .other(let rawValue): "Quality \(rawValue)"
        }
    }
}

struct AppleTtsVoice: Identifiable, Equatable, Sendable {
    let identifier: String
    let language: String
    let name: String
    let quality: AppleTtsVoiceQuality

    var id: String { identifier }
}

struct AppleTtsVoiceGroup: Identifiable, Equatable, Sendable {
    let language: String
    let languageName: String
    let voices: [AppleTtsVoice]

    var id: String { language }
}

struct AppleTtsVoiceCatalog {
    typealias VoiceSource = () -> [AppleTtsVoice]

    private let displayLocale: Locale
    private let source: VoiceSource

    init(displayLocale: Locale = .current) {
        self.init(displayLocale: displayLocale, source: Self.systemVoiceSnapshots)
    }

    init(displayLocale: Locale, source: @escaping VoiceSource) {
        self.displayLocale = displayLocale
        self.source = source
    }

    func groups() -> [AppleTtsVoiceGroup] {
        Self.groups(from: source(), displayLocale: displayLocale)
    }

    static func groups(
        from voices: [AppleTtsVoice],
        displayLocale: Locale
    ) -> [AppleTtsVoiceGroup] {
        let uniqueVoices = voices.reduce(into: [String: AppleTtsVoice]()) { result, voice in
            guard result[voice.identifier] == nil else { return }
            result[voice.identifier] = voice
        }
        let groupedVoices = Dictionary(grouping: uniqueVoices.values, by: \.language)

        return groupedVoices.keys.sorted().map { language in
            let voices = groupedVoices[language, default: []].sorted {
                if $0.name == $1.name {
                    return $0.identifier < $1.identifier
                }
                return $0.name < $1.name
            }
            return AppleTtsVoiceGroup(
                language: language,
                languageName: displayLocale.localizedString(forIdentifier: language) ?? language,
                voices: voices)
        }
    }

    private static func systemVoiceSnapshots() -> [AppleTtsVoice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            AppleTtsVoice(
                identifier: voice.identifier,
                language: voice.language,
                name: voice.name,
                quality: AppleTtsVoiceQuality(voice.quality))
        }
    }
}

@MainActor
final class AppleTtsVoiceCatalogStore: ObservableObject {
    @Published private(set) var groups: [AppleTtsVoiceGroup]

    private let catalog: AppleTtsVoiceCatalog
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(
        catalog: AppleTtsVoiceCatalog,
        notificationCenter: NotificationCenter = .default
    ) {
        self.catalog = catalog
        self.notificationCenter = notificationCenter
        self.groups = catalog.groups()
    }

    func refresh() {
        groups = catalog.groups()
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopObserving() {
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }
}

enum AppleTtsVoiceResolver {
    static func localeIdentifier(for language: SpokenLanguage) -> String {
        switch language {
        case .en: "en-US"
        case .zh: "zh-CN"
        case .ja: "ja-JP"
        }
    }

    /// A language-specific voice is preferred. If the requested region is not
    /// installed, use an installed voice with the same language before asking
    /// AVFAudio for the system's current default voice.
    static func voice(for language: SpokenLanguage) -> AVSpeechSynthesisVoice? {
        let localeIdentifier = localeIdentifier(for: language)
        if let exactVoice = AVSpeechSynthesisVoice(language: localeIdentifier) {
            return exactVoice
        }

        let languageCode = localeIdentifier.split(separator: "-").first.map(String.init)
        if let languageCode,
           let sameLanguageVoice = AVSpeechSynthesisVoice.speechVoices().first(where: {
               $0.language.split(separator: "-").first.map(String.init) == languageCode
           }) {
            return sameLanguageVoice
        }

        return AVSpeechSynthesisVoice(language: nil)
    }
}

private enum AppleTtsDelegateEvent: Sendable {
    case finished(utteranceID: UInt)
    case cancelled(utteranceID: UInt)
}

private func appleTtsUtteranceID(_ utterance: AVSpeechUtterance) -> UInt {
    UInt(bitPattern: ObjectIdentifier(utterance).hashValue)
}

private final class AppleTtsDelegateProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onEvent: (@Sendable (AppleTtsDelegateEvent) -> Void)?

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        onEvent?(.finished(utteranceID: appleTtsUtteranceID(utterance)))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        onEvent?(.cancelled(utteranceID: appleTtsUtteranceID(utterance)))
    }
}

/// Bridges AVSpeechSynthesizer's generated PCM buffers into the app's shared
/// TTS contract. The actor serializes the non-Sendable system synthesizer and
/// drops callbacks that belong to a cancelled request.
actor TtsApple {
    private struct BufferSnapshot: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let isEnd: Bool

        init(samples: [Float], sampleRate: Double, isEnd: Bool = false) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.isEnd = isEnd
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateProxy: AppleTtsDelegateProxy
    private var activeRequestID: UUID?
    private var activeUtteranceID: UInt?
    private var activeSamples: [Float] = []
    private var activeSampleRate: Double?
    private var activeContinuation: CheckedContinuation<TtsAudioChunk, Error>?

    init() {
        let delegateProxy = AppleTtsDelegateProxy()
        self.delegateProxy = delegateProxy
        delegateProxy.onEvent = { [weak self] event in
            Task { [weak self] in
                await self?.receive(event: event)
            }
        }
    }

    func synthesize(
        _ text: String,
        language: SpokenLanguage
    ) async throws -> TtsAudioChunk {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppleTtsError.noAudio }
        try Task.checkCancellation()
        guard activeContinuation == nil else { throw AppleTtsError.busy }

        let requestID = UUID()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AppleTtsVoiceResolver.voice(for: language)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TtsAudioChunk, Error>) in
                activeRequestID = requestID
                activeUtteranceID = appleTtsUtteranceID(utterance)
                activeSamples = []
                activeSampleRate = nil
                activeContinuation = continuation
                synthesizer.delegate = delegateProxy

                synthesizer.write(utterance) { [weak self] buffer in
                    guard let snapshot = Self.snapshot(from: buffer) else {
                        Task { await self?.finish(requestID: requestID, with: .failure(AppleTtsError.invalidAudioBuffer)) }
                        return
                    }
                    Task { await self?.receive(snapshot, requestID: requestID) }
                }
            }
        }, onCancel: {
            Task { await self.cancel(requestID: requestID) }
        })
    }

    private func receive(_ snapshot: BufferSnapshot, requestID: UUID) {
        guard activeRequestID == requestID else { return }

        if snapshot.isEnd {
            guard let sampleRate = activeSampleRate,
                  !activeSamples.isEmpty else {
                finish(requestID: requestID, with: .failure(AppleTtsError.noAudio))
                return
            }
            finish(requestID: requestID,
                   with: .success(TtsAudioChunk(samples: activeSamples,
                                                sampleRate: sampleRate)))
            return
        }

        guard !snapshot.samples.isEmpty else { return }
        if let activeSampleRate,
           abs(activeSampleRate - snapshot.sampleRate) > 0.5 {
            finish(requestID: requestID, with: .failure(AppleTtsError.sampleRateChanged))
            return
        }
        activeSampleRate = activeSampleRate ?? snapshot.sampleRate
        activeSamples.append(contentsOf: snapshot.samples)
    }

    private func receive(event: AppleTtsDelegateEvent) {
        guard let activeUtteranceID else { return }

        switch event {
        case .finished(let utteranceID) where utteranceID == activeUtteranceID:
            complete(requestID: activeRequestID)
        case .cancelled(let utteranceID) where utteranceID == activeUtteranceID:
            if let requestID = activeRequestID {
                finish(requestID: requestID, with: .failure(CancellationError()))
            }
        default:
            return
        }
    }

    private func complete(requestID: UUID?) {
        guard let requestID,
              let sampleRate = activeSampleRate,
              !activeSamples.isEmpty else {
            if let requestID {
                finish(requestID: requestID, with: .failure(AppleTtsError.noAudio))
            }
            return
        }
        finish(requestID: requestID,
               with: .success(TtsAudioChunk(samples: activeSamples,
                                            sampleRate: sampleRate)))
    }

    private func cancel(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        _ = synthesizer.stopSpeaking(at: .immediate)
        finish(requestID: requestID, with: .failure(CancellationError()))
    }

    private func finish(requestID: UUID, with result: Result<TtsAudioChunk, Error>) {
        guard activeRequestID == requestID else { return }
        let continuation = activeContinuation
        activeRequestID = nil
        activeUtteranceID = nil
        activeContinuation = nil
        activeSamples.removeAll(keepingCapacity: true)
        activeSampleRate = nil
        continuation?.resume(with: result)
    }

    private static func snapshot(from buffer: AVAudioBuffer) -> BufferSnapshot? {
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return nil }
        let sampleRate = pcmBuffer.format.sampleRate
        guard sampleRate > 0 else { return nil }
        guard pcmBuffer.frameLength > 0 else {
            // Some OS releases deliver a zero-frame PCM callback after the
            // audio stream. The delegate finish event is also accepted as a
            // fallback; target-device behavior remains tracked in #20.
            return BufferSnapshot(samples: [], sampleRate: sampleRate, isEnd: true)
        }

        if pcmBuffer.format.channelCount == 1,
           let channel = pcmBuffer.floatChannelData?[0] {
            return BufferSnapshot(
                samples: Array(UnsafeBufferPointer(start: channel,
                                                   count: Int(pcmBuffer.frameLength))),
                sampleRate: sampleRate)
        }

        // Normalize any non-mono/interleaved callback to the mono Float32
        // contract consumed by AudioPlayer.
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                                channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                             frameCapacity: pcmBuffer.frameLength),
              let converter = AVAudioConverter(from: pcmBuffer.format,
                                               to: targetFormat) else {
            return nil
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        guard status != .error,
              conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            return nil
        }
        return BufferSnapshot(
            samples: Array(UnsafeBufferPointer(start: channel,
                                               count: Int(output.frameLength))),
            sampleRate: sampleRate)
    }
}
