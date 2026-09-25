import XCTest
@testable import WhiskerFlowAppSupport

final class BoundedAudioCaptureBufferTests: XCTestCase {
    func testResidentTailMatchesTheLastSamplesAcrossCompaction() {
        let buffer = BoundedAudioCaptureBuffer(maximumResidentSamples: 10) { _ in }
        var everything: [Float] = []
        // Uneven chunk sizes walk the head through several compactions.
        for chunk in 0..<40 {
            let samples = (0..<(chunk % 7 + 1)).map { Float(everything.count + $0) }
            everything += samples
            XCTAssertTrue(buffer.append(samples))

            let expected = Array(everything.suffix(10))
            XCTAssertEqual(buffer.totalSampleCount, everything.count)
            XCTAssertEqual(buffer.residentSampleCount, expected.count)
            XCTAssertEqual(buffer.residentStartSample, everything.count - expected.count)
            XCTAssertEqual(buffer.residentSuffix(fromAbsoluteSample: buffer.residentStartSample), expected)
            XCTAssertEqual(buffer.residentSuffix(fromAbsoluteSample: everything.count - 1), [everything.last!])
            XCTAssertEqual(buffer.residentSuffix(fromAbsoluteSample: everything.count), [])
        }
        XCTAssertNil(buffer.residentSuffix(fromAbsoluteSample: 0))
    }

    func testWriteFailureKeepsWhatWasAlreadyCaptured() {
        struct DiskFull: Error {}
        let failAfter = 2
        final class Writes: @unchecked Sendable { var count = 0 }
        let writes = Writes()
        let buffer = BoundedAudioCaptureBuffer(maximumResidentSamples: 100) { _ in
            writes.count += 1
            if writes.count > failAfter { throw DiskFull() }
        }

        XCTAssertTrue(buffer.append([0.1, 0.2]))
        XCTAssertTrue(buffer.append([0.3]))
        XCTAssertFalse(buffer.append([0.4]))
        XCTAssertFalse(buffer.append([0.5]))

        XCTAssertNotNil(buffer.failure)
        XCTAssertEqual(writes.count, 3, "a failed spool is not written to again")
        XCTAssertEqual(buffer.totalSampleCount, 3)
        XCTAssertEqual(buffer.residentSuffix(fromAbsoluteSample: 0), [0.1, 0.2, 0.3])
    }

    func testReadersDoNotWaitForASlowDurableWrite() {
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let buffer = BoundedAudioCaptureBuffer(maximumResidentSamples: 100) { samples in
            guard samples.first == 2 else { return }
            writeStarted.signal()
            releaseWrite.wait()
        }
        XCTAssertTrue(buffer.append([1]))

        let appended = expectation(description: "slow append finished")
        DispatchQueue.global().async {
            buffer.append([2])
            appended.fulfill()
        }
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 5), .success)
        // Samples become visible only once they are durable.
        XCTAssertEqual(buffer.totalSampleCount, 1)
        XCTAssertEqual(buffer.residentSuffix(fromAbsoluteSample: 0), [1])
        releaseWrite.signal()
        wait(for: [appended], timeout: 5)
        XCTAssertEqual(buffer.residentSuffix(fromAbsoluteSample: 0), [1, 2])
    }
}
