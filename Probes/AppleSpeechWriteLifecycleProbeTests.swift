@preconcurrency import AVFAudio
import Foundation
import XCTest

private enum ProbeMode: Equatable, Sendable {
    case normal
    case cancelAfterFirstBuffer
}

final class AppleSpeechWriteLifecycleProbeTests: XCTestCase {
    func testWriteLifecycle() async {
        let report = await AppleSpeechWriteLifecycleProbe(mode: .normal).run()
        attach(report, name: "Apple Speech write lifecycle")
    }

    func testWriteCancellationLifecycle() async {
        let report = await AppleSpeechWriteLifecycleProbe(mode: .cancelAfterFirstBuffer).run()
        attach(report, name: "Apple Speech write cancellation lifecycle")
    }

    private func attach(_ report: String, name: String) {
        let attachment = XCTAttachment(string: report)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
    }
}

@MainActor
private final class AppleSpeechWriteLifecycleProbe {
    private let mode: ProbeMode
    private let synthesizer = AVSpeechSynthesizer()
    private let ledger: ProbeLedger
    private let delegate: ProbeDelegate

    init(mode: ProbeMode) {
        self.mode = mode
        let ledger = ProbeLedger()
        self.ledger = ledger
        delegate = ProbeDelegate { [ledger] event in
            ledger.record(delegateEvent: event)
        }
    }

    func run() async -> String {
        synthesizer.delegate = delegate

        let utterance = AVSpeechUtterance(
            string: "This is a lifecycle probe. It intentionally contains enough text to expose buffering and cancellation behavior.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        ledger.record(started: mode)
        synthesizer.write(utterance) { [ledger, mode, synthesizer] buffer in
            let isFirstDataBuffer = ledger.record(buffer: buffer)
            if mode == .cancelAfterFirstBuffer && isFirstDataBuffer {
                let returned = synthesizer.stopSpeaking(at: .immediate)
                ledger.record(stopReason: "inside first data callback", returned: returned)
            }
        }

        switch mode {
        case .normal:
            await waitForTerminal(maximumNanoseconds: 5_000_000_000)
            if !ledger.hasTerminalSignal {
                stop(reason: "normal timeout")
                await sleep(nanoseconds: 500_000_000)
            } else {
                await sleep(nanoseconds: 500_000_000)
            }
        case .cancelAfterFirstBuffer:
            await waitForData(maximumNanoseconds: 5_000_000_000)
            if !ledger.hasStopRequest {
                stop(reason: "no first data callback")
            }
            await sleep(nanoseconds: 1_000_000_000)
        }

        return ledger.report(mode: mode)
    }

    private func stop(reason: String) {
        let result = synthesizer.stopSpeaking(at: .immediate)
        ledger.record(stopReason: reason, returned: result)
    }

    private func waitForTerminal(maximumNanoseconds: UInt64) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + maximumNanoseconds
        while !ledger.hasTerminalSignal,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForData(maximumNanoseconds: UInt64) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + maximumNanoseconds
        while !ledger.hasDataBuffer,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await sleep(nanoseconds: 100_000_000)
        }
    }

    private func sleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

private final class ProbeDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let onEvent: @Sendable (String) -> Void

    init(onEvent: @escaping @Sendable (String) -> Void) {
        self.onEvent = onEvent
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        onEvent("didFinish")
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        onEvent("didCancel")
    }
}

private final class ProbeLedger: @unchecked Sendable {
    private struct BufferRecord {
        let frameLength: AVAudioFrameCount
        let sampleRate: Double?
        let channels: AVAudioChannelCount?
        let interleaved: Bool?
        let callbackThread: String
        let callbackUptimeNanoseconds: UInt64
    }

    private let lock = NSLock()
    private var modeDescription = ""
    private var startedUptimeNanoseconds: UInt64?
    private var buffers: [BufferRecord] = []
    private var delegateEvents: [(name: String, thread: String)] = []
    private var stopReason: String?
    private var stopReturned: Bool?
    private var stopUptimeNanoseconds: UInt64?
    private var callbacksAfterStop = 0
    private var terminalSignals: [String] = []

    var hasDataBuffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffers.contains { $0.frameLength > 0 }
    }

    var hasTerminalSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !terminalSignals.isEmpty
    }

    func record(started mode: ProbeMode) {
        lock.lock()
        defer { lock.unlock() }
        startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        modeDescription = mode == .normal ? "normal" : "cancelAfterFirstBuffer"
    }

    func record(buffer: AVAudioBuffer) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let pcmBuffer = buffer as? AVAudioPCMBuffer
        let frameLength = pcmBuffer?.frameLength ?? 0
        let record = BufferRecord(
            frameLength: frameLength,
            sampleRate: pcmBuffer?.format.sampleRate,
            channels: pcmBuffer?.format.channelCount,
            interleaved: pcmBuffer?.format.isInterleaved,
            callbackThread: Thread.isMainThread ? "main" : (Thread.current.name ?? "background"),
            callbackUptimeNanoseconds: now)

        lock.lock()
        let isFirstDataBuffer = frameLength > 0 && !buffers.contains { $0.frameLength > 0 }
        buffers.append(record)
        if frameLength == 0 { terminalSignals.append("zeroFrame") }
        if let stopUptimeNanoseconds,
           now >= stopUptimeNanoseconds {
            callbacksAfterStop += 1
        }
        lock.unlock()
        return isFirstDataBuffer
    }

    func record(delegateEvent: String) {
        lock.lock()
        delegateEvents.append((delegateEvent, Thread.isMainThread ? "main" : (Thread.current.name ?? "background")))
        terminalSignals.append(delegateEvent)
        lock.unlock()
    }

    func record(stopReason: String, returned: Bool) {
        lock.lock()
        self.stopReason = stopReason
        stopReturned = returned
        stopUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    var hasStopRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopReason != nil
    }

    func report(mode: ProbeMode) -> String {
        lock.lock()
        let buffers = self.buffers
        let delegateEvents = self.delegateEvents
        let modeDescription = self.modeDescription
        let startedUptimeNanoseconds = self.startedUptimeNanoseconds
        let stopReason = self.stopReason
        let stopReturned = self.stopReturned
        let callbacksAfterStop = self.callbacksAfterStop
        let terminalSignals = self.terminalSignals
        lock.unlock()

        let platform = ProcessInfo.processInfo.operatingSystemVersionString
        let modeName = mode == .normal ? "normal" : "cancelAfterFirstBuffer"
        let lines = buffers.enumerated().map { index, buffer in
            let sampleRate = buffer.sampleRate.map { String($0) } ?? "n/a"
            let channels = buffer.channels.map { String($0) } ?? "n/a"
            let interleaved = buffer.interleaved.map { String($0) } ?? "n/a"
            let elapsedMilliseconds: String
            if let startedUptimeNanoseconds {
                elapsedMilliseconds = String(
                    format: "%.1f",
                    Double(buffer.callbackUptimeNanoseconds - startedUptimeNanoseconds) / 1_000_000.0)
            } else {
                elapsedMilliseconds = "n/a"
            }
            return "  [\(index)] frames=\(buffer.frameLength) sampleRate=\(sampleRate) channels=\(channels) interleaved=\(interleaved) thread=\(buffer.callbackThread) elapsedMs=\(elapsedMilliseconds)"
        }
        let delegateLine = delegateEvents.map { "\($0.name)@\($0.thread)" }.joined(separator: ", ")
        let stopReasonDescription = stopReason ?? "none"
        let stopReturnedDescription = stopReturned.map { String($0) } ?? "n/a"
        let terminalDescription = terminalSignals.joined(separator: ",")
        let delegateDescription = delegateLine.isEmpty ? "none" : delegateLine

        return ([
            "AppleSpeechWriteLifecycleProbe",
            "os=\(platform)",
            "mode=\(modeName)",
            "recordedMode=\(modeDescription)",
            "stopReason=\(stopReasonDescription)",
            "stopSpeakingReturned=\(stopReturnedDescription)",
            "callbackCount=\(buffers.count)",
            "callbacksAfterStop=\(callbacksAfterStop)",
            "terminalSignals=\(terminalDescription)",
            "delegateEvents=\(delegateDescription)",
            "buffers:",
        ] + lines).joined(separator: "\n")
    }
}
