@preconcurrency import AVFoundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

final class OrdinaryAudioSpoolTests: XCTestCase {
    func testWhisperFileWindowOptionsRequireSerialTimestampedDecode() {
        let options = WhisperKitEngine.fileWindowDecodingOptions(language: "en")
        XCTAssertFalse(options.withoutTimestamps)
        XCTAssertTrue(options.wordTimestamps)
        XCTAssertEqual(options.concurrentWorkerCount, 1)
    }

    func testWhisperFileWindowUsesWordsForOverlapOwnership() throws {
        let first = WhisperKitEngine.timedWordSegments(from: [
            (text: " send", start: 27.0, end: 27.3),
            (text: " report", start: 27.4, end: 28.0),
            (text: " by", start: 29.0, end: 29.3),
            (text: " Friday", start: 29.7, end: 30.2)
        ])
        let second = WhisperKitEngine.timedWordSegments(from: [
            (text: " by", start: 0.1, end: 0.4),
            (text: " Friday", start: 0.6, end: 1.0),
            (text: " then", start: 1.2, end: 1.5),
            (text: " confirm", start: 1.6, end: 2.1)
        ])

        var assembler = BoundedTranscriptAssembler()
        try assembler.append(
            TranscriptionResult(text: "send report by Friday", segments: first),
            offsetSeconds: 0, ownership: 0..<29.5, requiresTimings: true)
        try assembler.append(
            TranscriptionResult(text: "by Friday then confirm", segments: second),
            offsetSeconds: 29, ownership: 29.5..<Double.infinity, requiresTimings: true)
        XCTAssertEqual(
            try assembler.finish(language: "en", duration: 32).text,
            "send report by Friday then confirm"
        )
    }

    func testFinalDecodeTranslatesAbsoluteConfirmedOffsetIntoRolledResidentTail() {
        let residentSamples = (0..<480_000).map { Float($0) }
        let captured = CapturedAudio(
            samples: residentSamples,
            stopReason: .userReleased,
            audioURL: URL(fileURLWithPath: "/tmp/capture.wav"),
            totalSampleCount: 16_000 * 95,
            residentStartSample: 16_000 * 65
        )

        let tail = LiveDictationSession.finalDecodeSamples(
            captured: captured,
            confirmedSampleCount: 16_000 * 90,
            lastDecodedSampleCount: 16_000 * 90,
            windowIsEmpty: false
        )

        XCTAssertEqual(tail?.count, 16_000 * 5)
        XCTAssertEqual(tail?.first, Float(16_000 * 25))
        XCTAssertEqual(tail?.last, Float(480_000 - 1))
    }

    func testSpoolPersistsEveryFrameWhileKeepingOnlyBoundedTailResident() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiskerFlow-spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.wav")

        var spool: OrdinaryAudioSpool? = try OrdinaryAudioSpool(url: url)
        let chunk = [Float](repeating: 0.125, count: 16_000)
        for _ in 0..<95 { XCTAssertTrue(spool?.append(chunk) == true) }

        XCTAssertEqual(spool?.totalSampleCount, 16_000 * 95)
        XCTAssertEqual(spool?.residentSamples.count, 16_000 * 30)
        spool = nil // finalizes the WAV header before reopening it

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, AVAudioFramePosition(16_000 * 95))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
    }

    func testDiscardRemovesIncompleteSpool() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiskerFlow-spool-\(UUID().uuidString).wav")
        let spool = try OrdinaryAudioSpool(url: url)
        XCTAssertTrue(spool.append([0.1, 0.2, 0.3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try spool.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
