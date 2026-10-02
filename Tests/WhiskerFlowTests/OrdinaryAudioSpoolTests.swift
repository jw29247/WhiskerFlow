@preconcurrency import AVFoundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

final class OrdinaryAudioSpoolTests: XCTestCase {
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
