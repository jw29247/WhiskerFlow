import XCTest
@testable import WhiskerFlowAppSupport

final class LockedAudioBufferTests: XCTestCase {
    func testAppendSnapshotAndDrainAreConsistent() {
        let buffer = LockedAudioBuffer()
        buffer.append([0.1, 0.2])
        XCTAssertEqual(buffer.snapshot(), [0.1, 0.2])
        buffer.append([0.3])
        XCTAssertEqual(buffer.drain(), [0.1, 0.2, 0.3])
        XCTAssertTrue(buffer.snapshot().isEmpty)
    }

    func testCountTracksAppendsAndResets() {
        let buffer = LockedAudioBuffer()
        XCTAssertEqual(buffer.count, 0)
        buffer.append([0.1, 0.2, 0.3])
        XCTAssertEqual(buffer.count, 3)
        buffer.reset()
        XCTAssertEqual(buffer.count, 0)
    }

    func testSuffixReturnsTailFromIndex() {
        let buffer = LockedAudioBuffer()
        buffer.append([0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(buffer.suffix(from: 0), [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(buffer.suffix(from: 2), [0.3, 0.4])
        XCTAssertEqual(buffer.suffix(from: 4), [])
    }

    func testSuffixClampsOutOfRangeIndexes() {
        let buffer = LockedAudioBuffer()
        buffer.append([0.1, 0.2])
        XCTAssertEqual(buffer.suffix(from: 9), [])
        XCTAssertEqual(buffer.suffix(from: -3), [0.1, 0.2])
        XCTAssertEqual(LockedAudioBuffer().suffix(from: 5), [])
    }

    func testConcurrentAppendsRetainEverySample() {
        let buffer = LockedAudioBuffer()
        DispatchQueue.concurrentPerform(iterations: 100) { value in
            buffer.append([Float(value)])
        }
        XCTAssertEqual(buffer.snapshot().count, 100)
    }
}
