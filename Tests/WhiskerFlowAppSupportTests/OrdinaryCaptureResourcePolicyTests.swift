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
        for pair in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(pair.0.upperBound - pair.1.lowerBound, 16_000)
        }
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
