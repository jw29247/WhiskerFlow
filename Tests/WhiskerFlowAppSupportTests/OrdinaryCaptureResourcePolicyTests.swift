import XCTest
@testable import WhiskerFlowAppSupport

final class OrdinaryCaptureResourcePolicyTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func add(_ amount: Int) { lock.withLock { storage += amount } }
        var value: Int { lock.withLock { storage } }
    }

    func testLongOrdinaryCaptureDoesNotKeepWholeRecordingResident() {
        let durableSampleCount = Counter()
        let buffer = BoundedAudioCaptureBuffer(maximumResidentSamples: 16_000 * 30) { samples in
            durableSampleCount.add(samples.count)
        }
        let oneSecond = [Float](repeating: 0.1, count: 16_000)

        // Two minutes is enough to prove the current growth is proportional to
        // recording duration without allocating a machine-stressing fixture.
        for _ in 0..<120 {
            buffer.append(oneSecond)
        }

        XCTAssertEqual(buffer.totalSampleCount, 16_000 * 120)
        XCTAssertEqual(durableSampleCount.value, 16_000 * 120)
        XCTAssertEqual(buffer.residentSampleCount, 16_000 * 30)
        XCTAssertNil(buffer.residentSuffix(fromAbsoluteSample: 0))
        XCTAssertEqual(buffer.residentSuffix(fromAbsoluteSample: 16_000 * 119)?.count, 16_000)
    }

    func testDurableWriteFailureDoesNotPretendSamplesWereCaptured() {
        struct DiskFailure: Error {}
        let attempts = Counter()
        let buffer = BoundedAudioCaptureBuffer(maximumResidentSamples: 10) { _ in
            attempts.add(1)
            throw DiskFailure()
        }

        XCTAssertFalse(buffer.append([0.1, 0.2]))
        XCTAssertFalse(buffer.append([0.3]))
        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(buffer.totalSampleCount, 0)
        XCTAssertEqual(buffer.residentSampleCount, 0)
        XCTAssertNotNil(buffer.failure)
    }

    func testDecodeWindowsPreserveFinalTailAndNeverExceedNativeWindow() {
        let ranges = BoundedDecodeWindowPolicy.frameRanges(
            totalFrames: Int64(16_000 * 95 + 137), sampleRate: 16_000)
        XCTAssertEqual(ranges.first, 0..<480_000)
        XCTAssertEqual(ranges.last?.upperBound, Int64(16_000 * 95 + 137))
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 480_000 })
        // Every seam overlaps by a second except the last, which is anchored to
        // the end of the audio and so overlaps its neighbour by more.
        for pair in zip(ranges, ranges.dropFirst()).dropLast() {
            XCTAssertEqual(pair.0.upperBound - pair.1.lowerBound, 16_000)
        }
        XCTAssertGreaterThanOrEqual(ranges[ranges.count - 2].upperBound - ranges.last!.lowerBound, 16_000)
    }

    /// 59.4 s used to leave a 1.4 s final window (overlap plus a key click)
    /// that Whisper decodes as empty, failing every retry of the recording.
    func testFinalDecodeWindowIsAlwaysFullLength() {
        for seconds in [30.5, 59.4, 60.2, 88.9, 95.0] {
            let total = Int64(16_000 * seconds)
            let ranges = BoundedDecodeWindowPolicy.frameRanges(totalFrames: total, sampleRate: 16_000)
            XCTAssertEqual(ranges.last?.count, 480_000, "\(seconds) s")
            XCTAssertEqual(ranges.last?.upperBound, total)
            for pair in zip(ranges, ranges.dropFirst()) {
                XCTAssertLessThan(pair.0.lowerBound, pair.1.lowerBound)
                XCTAssertGreaterThan(pair.0.upperBound, pair.1.lowerBound)
            }
        }
        XCTAssertEqual(
            BoundedDecodeWindowPolicy.frameRanges(totalFrames: 16_000 * 12, sampleRate: 16_000),
            [0..<192_000]
        )
    }

    /// Neighbouring windows split ownership mid-overlap, so each stitched word
    /// belongs to exactly one window even across the wider final seam.
    func testWindowOwnershipTilesTheTimelineWithoutGapsOrOverlap() {
        let ranges = BoundedDecodeWindowPolicy.frameRanges(
            totalFrames: Int64(16_000 * 59.4), sampleRate: 16_000)
        let owned = BoundedDecodeWindowPolicy.ownership(of: ranges, sampleRate: 16_000)
        XCTAssertEqual(owned.count, ranges.count)
        XCTAssertEqual(owned.first?.lowerBound, -.infinity)
        XCTAssertEqual(owned.last?.upperBound, .infinity)
        for pair in zip(owned, owned.dropFirst()) {
            XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound)
        }
        XCTAssertEqual(owned[0].upperBound, 29.5, accuracy: 0.0001)
        XCTAssertEqual(owned[1].upperBound, (29.4 + 59) / 2, accuracy: 0.0001)
    }

    func testSilentWindowCanBeSkippedButAudibleEmptyWindowCannot() {
        XCTAssertFalse(BoundedDecodeWindowPolicy.containsAudibleActivity(
            [Float](repeating: 0.001, count: 16_000 * 30)))
        var mostlySilent = [Float](repeating: 0, count: 16_000 * 30)
        mostlySilent.replaceSubrange(
            16_000 * 15..<16_000 * 16,
            with: repeatElement(Float(0.03), count: 16_000)
        )
        XCTAssertTrue(BoundedDecodeWindowPolicy.containsAudibleActivity(mostlySilent))
    }
}
