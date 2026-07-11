import Foundation

/// Detects the end of a spoken turn from 16 kHz PCM chunks. Model EOU events
/// take priority; silence is the reliable path for models such as nemotron
/// that do not emit EOU tokens.
struct EndpointDetector {
    private let rmsThreshold: Float
    private let silenceHangMs: Double
    private(set) var hasDetectedSpeech = false
    private(set) var silenceMs: Double = 0
    private(set) var hasTriggered = false

    init(rmsThreshold: Double, silenceHangMs: Double) {
        self.rmsThreshold = Float(rmsThreshold)
        self.silenceHangMs = silenceHangMs
    }

    mutating func reset() {
        hasDetectedSpeech = false
        silenceMs = 0
        hasTriggered = false
    }

    /// Returns true once for an EOU event, or after speech followed by enough
    /// silence while the STT transcript is non-empty.
    mutating func process(_ pcm: [Float], modelEOU: Bool, hasTranscript: Bool) -> Bool {
        guard !hasTriggered else { return false }

        if modelEOU {
            hasTriggered = true
            return true
        }

        guard !pcm.isEmpty else { return false }
        let rms = sqrt(pcm.reduce(Float.zero) { $0 + $1 * $1 } / Float(pcm.count))
        if rms >= rmsThreshold {
            hasDetectedSpeech = true
            silenceMs = 0
            return false
        }

        guard hasDetectedSpeech else { return false }
        silenceMs += Double(pcm.count) / 16 // 16 samples per millisecond at 16 kHz.
        if hasTranscript && silenceMs >= silenceHangMs {
            hasTriggered = true
            return true
        }
        return false
    }
}
