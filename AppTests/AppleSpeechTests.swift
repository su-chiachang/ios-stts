import AVFoundation
import CoreMedia
import Foundation
import Speech
import XCTest
@testable import STTS

final class AppleSpeechTests: XCTestCase {
    func testAppleSpeechLocaleResolverMapsCompactIdentifiers() {
        XCTAssertEqual(
            SttAppleLocaleResolver.requestedLocale(for: "en").identifier(.bcp47),
            "en-US")
        XCTAssertEqual(
            SttAppleLocaleResolver.requestedLocale(for: "zh-Hant").identifier(.bcp47),
            "zh-TW")
        XCTAssertEqual(
            SttAppleLocaleResolver.requestedLocale(for: "zh-CN").identifier(.bcp47),
            "zh-CN")
    }

    func testAppleSpeechEmptyIdentifierUsesProvidedCurrentLocale() {
        let current = Locale(identifier: "ja-JP")
        let resolved = SttAppleLocaleResolver.requestedLocale(for: "", current: current)
        XCTAssertEqual(resolved.identifier(.bcp47), "ja-JP")
    }

    func testSttLocalePreferencePersistsCanonicalIdentifier() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SttLocalePreferences.key)
        defer {
            if let previous {
                defaults.set(previous, forKey: SttLocalePreferences.key)
            } else {
                defaults.removeObject(forKey: SttLocalePreferences.key)
            }
        }

        SttLocalePreferences.save("zh-Hant")

        XCTAssertEqual(SttLocalePreferences.identifier, "zh-TW")
    }

    func testSttAppleVersionDefaultsToNew() {
        XCTAssertEqual(SttAppleVersion.resolve(rawValue: nil), .new)
        XCTAssertEqual(SttAppleVersion.resolve(rawValue: "unknown"), .new)
        XCTAssertEqual(SttAppleVersion.resolve(rawValue: "old"), .old)
    }

    func testSttAppleNewTypeDefaultsToFileAndRejectsUnknownValues() {
        XCTAssertEqual(SttAppleNewType.resolve(rawValue: nil), .file)
        XCTAssertEqual(SttAppleNewType.resolve(rawValue: "unknown"), .file)
        XCTAssertEqual(SttAppleNewType.resolve(rawValue: "file"), .file)
        XCTAssertEqual(SttAppleNewType.resolve(rawValue: "live"), .live)
    }

    func testSttAppleOldTypeDefaultsToFileAndRejectsUnknownValues() {
        XCTAssertEqual(SttAppleOldType.resolve(rawValue: nil), .file)
        XCTAssertEqual(SttAppleOldType.resolve(rawValue: "unknown"), .file)
        XCTAssertEqual(SttAppleOldType.resolve(rawValue: "file"), .file)
        XCTAssertEqual(SttAppleOldType.resolve(rawValue: "live"), .live)
    }

    func testAnalyzerInputFileReaderStreamsAndDrainsConvertedAudio() async throws {
        let url = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let audioFile = try AVAudioFile(forReading: url)
        let analyzerFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false))
        let reader = AnalyzerInputFileReader(
            audioFile: audioFile,
            analyzerFormat: analyzerFormat,
            frameCount: 1_024)
        var frameLengths: [AVAudioFrameCount] = []

        while let input = try await reader.next() {
            frameLengths.append(input.buffer.frameLength)
        }

        XCTAssertGreaterThan(frameLengths.count, 1)
        XCTAssertTrue(frameLengths.allSatisfy { $0 > 0 && $0 <= 4_096 })
        let expectedFrameCount = 4_000
        let actualFrameCount = Int(frameLengths.reduce(0, +))
        XCTAssertLessThanOrEqual(abs(actualFrameCount - expectedFrameCount), 16)
    }

    func testLegacyReaderProducesNativePCMSampleBuffers() async throws {
        let url = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        var sampleBufferCount = 0
        var sampleCount: CMItemCount = 0
        try await LegacyAudioSampleBufferReader.forEachSampleBuffer(
            from: url,
            nativeFormat: request.nativeAudioFormat
        ) { sampleBuffer in
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sampleBuffer))
            let streamDescription = try XCTUnwrap(
                CMAudioFormatDescriptionGetStreamBasicDescription(description))
            let asbd = streamDescription.pointee
            XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
            XCTAssertEqual(asbd.mSampleRate, request.nativeAudioFormat.sampleRate, accuracy: 0.001)
            XCTAssertEqual(asbd.mChannelsPerFrame, request.nativeAudioFormat.channelCount)
            XCTAssertEqual(asbd.mBitsPerChannel, 32)
            XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, 0)
            XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsBigEndian, 0)
            XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
            sampleBufferCount += 1
            sampleCount += CMSampleBufferGetNumSamples(sampleBuffer)
        }

        XCTAssertGreaterThan(sampleBufferCount, 0)
        XCTAssertGreaterThan(sampleCount, 0)
    }

    func testSttWordTimestampExtractorReadsTimedRuns() {
        var transcription = AttributedString("hello world")
        let helloRange = try! XCTUnwrap(transcription.range(of: "hello"))
        let worldRange = try! XCTUnwrap(transcription.range(of: "world"))

        transcription[helloRange][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] =
            CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 1000),
                duration: CMTime(seconds: 0.5, preferredTimescale: 1000))
        transcription[worldRange][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] =
            CMTimeRange(
                start: CMTime(seconds: 2, preferredTimescale: 1000),
                duration: CMTime(seconds: 0.75, preferredTimescale: 1000))

        let words = SttAppleNewWords.words(from: transcription)

        XCTAssertEqual(words.map(\.text), ["hello", "world"])
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(words[0].end, 1.5, accuracy: 0.001)
        XCTAssertEqual(words[1].start, 2, accuracy: 0.001)
        XCTAssertEqual(words[1].end, 2.75, accuracy: 0.001)
    }

    private func makeTemporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-buffer-test-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 1,
                interleaved: false))
        let frameCount: AVAudioFrameCount = 11_025
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = Float(index % 100) / 100 - 0.5
        }
        buffer.frameLength = frameCount

        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try audioFile.write(from: buffer)
        return url
    }

}
