import CParakeet
import Foundation

enum ParakeetError: Error, LocalizedError {
    case loadFailed(String)
    case streamBeginFailed(String)
    case callFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let m): "Failed to load parakeet model: \(m)"
        case .streamBeginFailed(let m): "Failed to begin streaming session: \(m)"
        case .callFailed(let m): m
        }
    }
}

/// Wraps the parakeet C streaming API. An `actor` because the underlying
/// context is not safe to call from more than one thread at a time (mirrors
/// whisper.swiftui's `actor WhisperContext` pattern).
actor ParakeetStt {
    struct FeedResult {
        let newText: String
        let eou: Bool
        let eob: Bool
    }

    private var ctx: OpaquePointer?
    private var stream: OpaquePointer?

    init(modelPath: String) throws {
        guard let ctx = parakeet_capi_load(modelPath) else {
            throw ParakeetError.loadFailed("parakeet_capi_load returned NULL for \(modelPath)")
        }
        self.ctx = ctx
    }

    deinit {
        if let stream { parakeet_capi_stream_free(stream) }
        if let ctx { parakeet_capi_free(ctx) }
    }

    private func lastError() -> String {
        guard let ctx, let cstr = parakeet_capi_last_error(ctx) else { return "unknown error" }
        return String(cString: cstr)
    }

    /// Begin a new streaming turn. `lang` is a locale key ("auto", "zh", "en", ...)
    /// or nil to use the model's default target-lang handling.
    func beginTurn(lang: String?) throws {
        guard let ctx else { throw ParakeetError.callFailed("context not loaded") }
        if let stream {
            parakeet_capi_stream_free(stream)
            self.stream = nil
        }
        let newStream: OpaquePointer?
        if let lang {
            newStream = parakeet_capi_stream_begin_lang(ctx, lang)
        } else {
            newStream = parakeet_capi_stream_begin(ctx)
        }
        guard let newStream else {
            throw ParakeetError.streamBeginFailed(lastError())
        }
        stream = newStream
    }

    /// Feed one chunk of 16 kHz mono Float32 PCM. Returns any newly finalized
    /// text plus EOU/EOB event flags for this chunk.
    func feed(_ pcm: [Float]) throws -> FeedResult {
        guard let stream else { throw ParakeetError.callFailed("no active stream (call beginTurn first)") }
        var eou: Int32 = 0
        let cstr: UnsafeMutablePointer<CChar>? = pcm.withUnsafeBufferPointer { buf in
            parakeet_capi_stream_feed(stream, buf.baseAddress, Int32(buf.count), &eou)
        }
        guard let cstr else { throw ParakeetError.callFailed(lastError()) }
        defer { parakeet_capi_free_string(cstr) }
        let text = Self.strippingLanguageTag(String(cString: cstr))
        return FeedResult(newText: text,
                           eou: eou & Int32(PARAKEET_EVENT_EOU) != 0,
                           eob: eou & Int32(PARAKEET_EVENT_EOB) != 0)
    }

    /// Result of a whole-file timestamped transcription: recognized words with
    /// per-word timing plus the encoder frame stride (seconds) used to scale
    /// sentence-gap thresholds during segmentation.
    struct TimestampedResult {
        let words: [TranscriptWord]
        let frameSec: Double
    }

    /// Transcribes a whole clip (16 kHz mono Float32 PCM) in one shot, returning
    /// per-word timestamps + confidence. Uses the batched JSON C API (which
    /// accepts raw PCM, so any AVFoundation-decodable input — mp3/wav/mp4 —
    /// works) rather than the streaming path used for interactive turns.
    /// `lang` is a locale key ("en", "zh-CN", "auto", …) or nil for the model
    /// default.
    func transcribeFileWords(pcm: [Float], lang: String?) throws -> TimestampedResult {
        guard let ctx else { throw ParakeetError.callFailed("context not loaded") }
        guard !pcm.isEmpty else { return TimestampedResult(words: [], frameSec: 0) }

        func run(_ langPtr: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
            var counts: [Int32] = [Int32(pcm.count)]
            return pcm.withUnsafeBufferPointer { pbuf in
                counts.withUnsafeBufferPointer { cbuf in
                    parakeet_capi_transcribe_pcm_batch_json_lang(
                        ctx, pbuf.baseAddress, cbuf.baseAddress, 1, 16_000, 0, langPtr)
                }
            }
        }

        let cstr: UnsafeMutablePointer<CChar>?
        if let lang, lang != "auto" {
            cstr = lang.withCString { run($0) }
        } else {
            cstr = run(nil)
        }
        guard let cstr else { throw ParakeetError.callFailed(lastError()) }
        defer { parakeet_capi_free_string(cstr) }

        let data = Data(String(cString: cstr).utf8)
        let clips = try JSONDecoder().decode([JSONClip].self, from: data)
        guard let clip = clips.first else { return TimestampedResult(words: [], frameSec: 0) }
        let words = clip.words.map {
            TranscriptWord(text: Self.strippingLanguageTag($0.w),
                           start: $0.start, end: $0.end, confidence: $0.conf)
        }
        return TimestampedResult(words: words, frameSec: clip.frame_sec)
    }

    private struct JSONClip: Decodable {
        let frame_sec: Double
        let words: [JSONWord]
    }
    private struct JSONWord: Decodable {
        let w: String
        let start: Double
        let end: Double
        let conf: Double
    }

    /// Flush the tail of the current turn and free the stream.
    @discardableResult
    func endTurn() throws -> String {
        guard let stream else { return "" }
        defer {
            parakeet_capi_stream_free(stream)
            self.stream = nil
        }
        guard let cstr = parakeet_capi_stream_finalize(stream) else {
            throw ParakeetError.callFailed(lastError())
        }
        defer { parakeet_capi_free_string(cstr) }
        return Self.strippingLanguageTag(String(cString: cstr))
    }

    /// nemotron emits a literal `<zh-CN>` / `<en-US>` locale token inline in
    /// the transcript (confirmed against the model output, not a CLI
    /// artifact — the C API does not strip it). Remove it before display.
    private static func strippingLanguageTag(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return text.replacing(#/<[a-zA-Z]{2}(-[a-zA-Z]{2})?>/#, with: "")
    }
}
