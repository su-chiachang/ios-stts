// M2 verification: drives the REAL ConversationEngine.transcribeFile path
// (AudioFileInput → ParakeetStt.beginTurn/feed/endTurn → bubble) against
// arbitrary audio/video fixtures, unsandboxed.
//
// Usage: filetranscribetest <parakeet.gguf> <qwen3tts-model-dir> <file> [file2 ...]

import Darwin
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    fail("usage: filetranscribetest <parakeet.gguf> <qwen3tts-model-dir> <file> [file2 ...]")
}

try AppSettings.shared.setParakeetModel(URL(fileURLWithPath: args[1]))
try AppSettings.shared.setQwenModelDir(URL(fileURLWithPath: args[2]))

let engine = await ConversationEngine()
await engine.loadModels()
guard await engine.isReady else {
    fail("models failed to load: \(await engine.state)")
}

for path in args.dropFirst(3) {
    let url = URL(fileURLWithPath: path)
    print("== transcribing \(url.lastPathComponent)")
    let t0 = Date()
    await engine.transcribeFile(url)
    while await engine.state == .listening {
        try await Task.sleep(for: .milliseconds(50))
    }
    let elapsed = String(format: "%.2fs", -t0.timeIntervalSinceNow)
    let state = await engine.state
    let bubbles = await engine.bubbles
    if case .error(let msg) = state {
        print("   ERROR (\(elapsed)): \(msg)")
    } else {
        print("   (\(elapsed)) bubbles: \(bubbles.map(\.text))")
    }
}

print("== FILE TRANSCRIBE TEST DONE")
// See Tools/SmokeTest — same dual-ggml exit-time teardown race, same fix.
fflush(stdout)
_exit(0)
