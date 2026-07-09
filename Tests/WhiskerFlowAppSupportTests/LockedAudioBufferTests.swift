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

    func testConcurrentAppendsRetainEverySample() {
        let buffer = LockedAudioBuffer()
        DispatchQueue.concurrentPerform(iterations: 100) { value in
            buffer.append([Float(value)])
        }
        XCTAssertEqual(buffer.snapshot().count, 100)
    }
}
