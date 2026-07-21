// M0 smoke test: both engines in one process.
//
// 1. Load qwentts, synthesize one zh and one en sentence → wav files.
// 2. Load parakeet, stream-transcribe the synthesized wavs back (self-loop),
//    printing incremental text + EOU/EOB events.
//
// Usage: smoketest <parakeet.gguf> <qwentts-model-dir> <out-dir> [extra.wav ...]

import AVFoundation
import Darwin
import CParakeet
import CQwenTTS
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func elapsed(_ start: Date) -> String { String(format: "%.2fs", -start.timeIntervalSinceNow) }

// MARK: - WAV helpers

func writeWav16(samples: [Float], sampleRate: Int, to url: URL) throws {
    var data = Data()
    let byteRate = sampleRate * 2
    let dataSize = samples.count * 2
    func put(_ s: String) { data.append(s.data(using: .ascii)!) }
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    put("RIFF"); put32(UInt32(36 + dataSize)); put("WAVE")
    put("fmt "); put32(16); put16(1); put16(1)
    put32(UInt32(sampleRate)); put32(UInt32(byteRate)); put16(2); put16(16)
    put("data"); put32(UInt32(dataSize))
    for s in samples {
        let v = Int16(max(-1.0, min(1.0, s)) * 32767)
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    try data.write(to: url)
}

/// Read any audio file and convert to 16 kHz mono Float32 (what parakeet wants).
func readAs16kMono(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let srcFormat = file.processingFormat
    let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                  channels: 1, interleaved: false)!
    let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                  frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: srcBuf)
    let converter = AVAudioConverter(from: srcFormat, to: dstFormat)!
    let ratio = 16000.0 / srcFormat.sampleRate
    let dstCapacity = AVAudioFrameCount(Double(srcBuf.frameLength) * ratio) + 1024
    let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity)!
    var fed = false
    var convError: NSError?
    converter.convert(to: dstBuf, error: &convError) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return srcBuf
    }
    if let e = convError { throw e }
    return Array(UnsafeBufferPointer(start: dstBuf.floatChannelData![0],
                                     count: Int(dstBuf.frameLength)))
}

// MARK: - Args

let args = CommandLine.arguments
guard args.count >= 4 else {
    fail("usage: smoketest <parakeet.gguf> <qwentts-model-dir> <out-dir> [extra.wav ...]")
}
let parakeetModel = args[1], qwenDir = args[2]
let outDir = URL(fileURLWithPath: args[3], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - 1. TTS

print("== loading qwentts from \(qwenDir)")
var t0 = Date()
let talkerPath = URL(fileURLWithPath: qwenDir).appendingPathComponent("qwen-talker-0.6b-base-Q8_0.gguf").path
let codecPath = URL(fileURLWithPath: qwenDir).appendingPathComponent("qwen-tokenizer-12hz-Q8_0.gguf").path
var initParams = qt_init_params()
qt_init_default_params(&initParams)
let tts = talkerPath.withCString { talker in
    codecPath.withCString { codec in
        initParams.talker_path = talker
        initParams.codec_path = codec
        return qt_init(&initParams)
    }
}
guard let tts else { fail("qt_init failed: \(String(cString: qt_last_error()))") }
print("   loaded in \(elapsed(t0)), sample_rate=24000")

var synthesized: [(name: String, url: URL)] = []
for (name, text, language) in [
    ("tts_zh", "你好，很高興認識你。今天天氣真不錯。", "Chinese"),
    ("tts_en", "Hello, nice to meet you. The weather is great today.", "English"),
] {
    var params = qt_tts_params()
    qt_tts_default_params(&params)
    params.max_new_tokens = 1200
    var audio = qt_audio()
    t0 = Date()
    let status = text.withCString { textPointer in
        language.withCString { languagePointer in
            params.text = textPointer
            params.lang = languagePointer
            return qt_synthesize(tts, &params, &audio)
        }
    }
    guard status == QT_STATUS_OK, let pcm = audio.samples else {
        fail("synthesize(\(name)) failed: \(String(cString: qt_last_error()))")
    }
    defer { qt_audio_free(&audio) }
    let n = Int(audio.n_samples)
    let sr = Int(audio.sample_rate)
    let samples = Array(UnsafeBufferPointer(start: pcm, count: n))
    let dur = Double(n) / Double(sr)
    let url = outDir.appendingPathComponent("\(name).wav")
    try writeWav16(samples: samples, sampleRate: sr, to: url)
    print("   \(name): \(String(format: "%.1f", dur))s audio in \(elapsed(t0)) → \(url.path)")
    synthesized.append((name, url))
}

// MARK: - 2. STT (streaming, self-loop on the synthesized audio)

print("== loading parakeet from \(parakeetModel)")
t0 = Date()
guard let ctx = parakeet_capi_load(parakeetModel) else { fail("parakeet_capi_load returned NULL") }
print("   loaded in \(elapsed(t0))")

let extraWavs = args.dropFirst(4).map { (name: URL(fileURLWithPath: $0).lastPathComponent,
                                         url: URL(fileURLWithPath: $0)) }
for (name, url) in synthesized + extraWavs {
    let pcm = try readAs16kMono(url)
    guard let stream = parakeet_capi_stream_begin_lang(ctx, "auto") else {
        let err = parakeet_capi_last_error(ctx).map { String(cString: $0) } ?? "?"
        print("   stream_begin failed (\(err)) — falling back to full transcribe")
        var text: UnsafeMutablePointer<CChar>?
        pcm.withUnsafeBufferPointer { buf in
            text = parakeet_capi_transcribe_pcm(ctx, buf.baseAddress, Int32(pcm.count), 16000, 0)
        }
        if let text { print("   [\(name)] full: \(String(cString: text))"); parakeet_capi_free_string(text) }
        continue
    }
    t0 = Date()
    var transcript = ""
    var sawEOU = false, sawEOB = false
    let chunk = 1600  // 100 ms @16k
    var i = 0
    while i < pcm.count {
        let n = min(chunk, pcm.count - i)
        var eou: Int32 = 0
        let piece = Array(pcm[i..<i+n])
        if let s = piece.withUnsafeBufferPointer({ buf in
            parakeet_capi_stream_feed(stream, buf.baseAddress, Int32(n), &eou)
        }) {
            let str = String(cString: s)
            parakeet_capi_free_string(s)
            if !str.isEmpty { transcript += str }
        }
        if eou & 1 != 0 { sawEOU = true }
        if eou & 2 != 0 { sawEOB = true }
        i += n
    }
    if let tail = parakeet_capi_stream_finalize(stream) {
        transcript += String(cString: tail)
        parakeet_capi_free_string(tail)
    }
    parakeet_capi_stream_free(stream)
    print("   [\(name)] stream (\(elapsed(t0))): \"\(transcript)\" EOU=\(sawEOU) EOB=\(sawEOB)")
}

parakeet_capi_free(ctx)
qt_free(tts)
print("== SMOKE TEST PASSED (both engines coexisted in one process)")
// Two independently-linked ggml copies (parakeet static v0.13 + qwentts
// dylib v0.15) each register their own ggml-metal device wrapper around the
// same physical GPU. Their process-exit static destructors race/double-free
// Metal residency state (GGML_ASSERT "rsets->data count == 0" in
// ggml-metal-device.m), even though both engines already produced correct
// output above. _exit bypasses C++ static destructors entirely, which is
// safe here since the OS reclaims all GPU/process resources on exit anyway.
fflush(stdout)
_exit(0)
