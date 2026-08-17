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

    func testSttInputTypeDefaultsToFileAndRejectsUnknownValues() {
        XCTAssertEqual(SttInputType.resolve(rawValue: nil), .file)
        XCTAssertEqual(SttInputType.resolve(rawValue: "unknown"), .file)
        XCTAssertEqual(SttInputType.resolve(rawValue: "file"), .file)
        XCTAssertEqual(SttInputType.resolve(rawValue: "live"), .live)
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

    func testPreparedAudioFileLeavesAudioOnlyInputUntouched() async throws {
        let url = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let prepared = try await SttPreparedAudioFile.prepare(url)
        defer { prepared.removeTemporaryFile() }

        XCTAssertEqual(prepared.url, url)
    }

    func testPreparedAudioFileRemuxesOnlyWhenDurationsMeaningfullyDiffer() {
        XCTAssertFalse(
            SttPreparedAudioFile.requiresPreparation(
                trackDuration: 10,
                audioFileDuration: 9.95))
        XCTAssertTrue(
            SttPreparedAudioFile.requiresPreparation(
                trackDuration: 10,
                audioFileDuration: 9.5))
        XCTAssertTrue(
            SttPreparedAudioFile.requiresPreparation(
                trackDuration: 10,
                audioFileDuration: .nan))
    }

    func testPreparedAudioFileRemovesTemporaryFileWhenOperationIsCancelled() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stts-cancellation-(UUID().uuidString).tmp")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: url) }

        let prepared = SttPreparedAudioFile(url: url, isTemporary: true)
        let task = Task {
            try await prepared.withCancellationCleanup {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        await Task.yield()
        task.cancel()
        _ = await task.result

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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
            let nativeASBD = request.nativeAudioFormat.streamDescription.pointee
            XCTAssertEqual(asbd.mBitsPerChannel, nativeASBD.mBitsPerChannel)
            XCTAssertEqual(
                asbd.mFormatFlags & kAudioFormatFlagIsFloat,
                nativeASBD.mFormatFlags & kAudioFormatFlagIsFloat)
            XCTAssertEqual(
                asbd.mFormatFlags & kAudioFormatFlagIsBigEndian,
                nativeASBD.mFormatFlags & kAudioFormatFlagIsBigEndian)
            XCTAssertEqual(
                asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved,
                nativeASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved)
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

    func testSttWordHighlightingSelectsWordOnlyWithinItsTimeRange() {
        let words = [
            SttWordTimestamp(text: "hello", start: 1, end: 1.5),
            SttWordTimestamp(text: "world", start: 2, end: 2.75)
        ]

        XCTAssertNil(SttWordHighlighting.activeWordIndex(at: 0.99, in: words))
        XCTAssertEqual(SttWordHighlighting.activeWordIndex(at: 1, in: words), 0)
        XCTAssertNil(SttWordHighlighting.activeWordIndex(at: 1.5, in: words))
        XCTAssertEqual(SttWordHighlighting.activeWordIndex(at: 2.25, in: words), 1)
        XCTAssertNil(SttWordHighlighting.activeWordIndex(at: 2.75, in: words))
    }

    func testSttTranscriptSegmentsKeepTranscriptTextAndWordIndexes() {
        let words = [
            SttWordTimestamp(text: "hello", start: 1, end: 1.5),
            SttWordTimestamp(text: "world", start: 2, end: 2.75)
        ]

        let segments = SttWordHighlighting.transcriptSegments(
            in: "hello, world!",
            words: words)

        XCTAssertEqual(
            segments,
            [
                SttTranscriptSegment(text: "hello", wordIndex: 0),
                SttTranscriptSegment(text: ", ", wordIndex: nil),
                SttTranscriptSegment(text: "world", wordIndex: 1),
                SttTranscriptSegment(text: "!", wordIndex: nil)
            ])
        XCTAssertEqual(segments.map(\.text).joined(), "hello, world!")
    }

    func testSttAppleNewFileTranscribesPastMalformedAVAudioFileLength() async throws {
        guard let path = ProcessInfo.processInfo.environment["STTS_TEST_MALFORMED_AUDIO_URL"] else {
            throw XCTSkip(
                "Set STTS_TEST_MALFORMED_AUDIO_URL to a long media fixture with bad Core Audio packet metadata.")
        }

        let url = URL(fileURLWithPath: path)
        let assetDuration = try await AVURLAsset(url: url).load(.duration).seconds
        let audioFile = try AVAudioFile(forReading: url)
        let audioFileDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        XCTAssertLessThan(audioFileDuration, assetDuration * 0.5, "Fixture no longer reproduces the AVAudioFile truncation.")

        let stt = try await SttAppleNew.make(localeIdentifier: "en-US")
        for inputType in SttInputType.allCases {
            let result = try await stt.transcribeFile(url, inputType: inputType)
            let lastWordEnd = try XCTUnwrap(result.words.map(\.end).max())

            XCTAssertGreaterThan(
                lastWordEnd,
                assetDuration * 0.9,
                "\(inputType) stopped before the end of the prepared audio file.")
        }
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
