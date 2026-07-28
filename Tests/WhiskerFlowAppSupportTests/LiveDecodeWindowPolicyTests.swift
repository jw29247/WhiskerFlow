import XCTest
@testable import WhiskerFlowAppSupport

final class LiveDecodeWindowPolicyTests: XCTestCase {
    private let frame = LiveDecodeWindowPolicy.frameSampleCount
    private let loud: Float = 0.2
    private let quiet: Float = 0.001

    private func rms(frameCount: Int, silent: [Range<Int>] = []) -> [Float] {
        var values = [Float](repeating: loud, count: frameCount)
        for run in silent {
            for index in run { values[index] = quiet }
        }
        return values
    }

    // MARK: - cutPoint

    func testNoCutBelowFreezeThreshold() {
        let frameCount = 40
        XCTAssertNil(LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: frameCount * frame,
            frameRMS: rms(frameCount: frameCount, silent: [0..<frameCount])
        ))
    }

    func testCutLandsInsideTheSilenceRun() {
        let frameCount = 100
        let silence = 60..<65
        let cut = LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: frameCount * frame,
            frameRMS: rms(frameCount: frameCount, silent: [silence])
        )
        XCTAssertNotNil(cut)
        XCTAssertGreaterThanOrEqual(cut ?? 0, silence.lowerBound * frame)
        XCTAssertLessThanOrEqual(cut ?? 0, silence.upperBound * frame)
    }

    func testMostRecentSilenceRunWins() {
        let frameCount = 100
        let recent = 70..<75
        let cut = LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: frameCount * frame,
            frameRMS: rms(frameCount: frameCount, silent: [20..<26, recent])
        )
        XCTAssertNotNil(cut)
        XCTAssertGreaterThanOrEqual(cut ?? 0, recent.lowerBound * frame)
        XCTAssertLessThanOrEqual(cut ?? 0, recent.upperBound * frame)
    }

    func testShortSilenceRunIsIgnored() {
        let frameCount = 100
        XCTAssertNil(LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: frameCount * frame,
            frameRMS: rms(frameCount: frameCount, silent: [60..<62])
        ))
    }

    func testHardCapForcesCutAtTheQuietestFrame() {
        let frameCount = 150
        var values = rms(frameCount: frameCount)
        values[100] = 0.05
        let cut = LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: frameCount * frame,
            frameRMS: values
        )
        XCTAssertEqual(cut, 100 * frame + frame / 2)
    }

    func testNoForcedCutBeforeTheHardCap() {
        let frameCount = 140
        var values = rms(frameCount: frameCount)
        values[100] = 0.05
        XCTAssertNil(LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: frameCount * frame,
            frameRMS: values
        ))
    }

    func testCutNeverExceedsTheWindowSampleCount() {
        let frameCount = 200
        let windowSampleCount = 80 * frame
        let cut = LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: windowSampleCount,
            frameRMS: rms(frameCount: frameCount, silent: [0..<frameCount])
        )
        XCTAssertEqual(cut, windowSampleCount)
    }

    func testEmptyFrameRMSHasNoCut() {
        XCTAssertNil(LiveDecodeWindowPolicy.cutPoint(windowSampleCount: 200 * frame, frameRMS: []))
    }

    // MARK: - frameRMS

    func testFrameRMSEmitsOneValuePerWholeFrameAndDropsThePartialTail() {
        let samples = [Float](repeating: 0.5, count: frame)
            + [Float](repeating: 0, count: frame)
            + [Float](repeating: 0.5, count: 7)
        let values = LiveDecodeWindowPolicy.frameRMS(samples)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(values[1], 0, accuracy: 0.0001)
    }

    func testFrameRMSOfAShortBufferIsEmpty() {
        XCTAssertTrue(LiveDecodeWindowPolicy.frameRMS([Float](repeating: 0.5, count: frame - 1)).isEmpty)
    }

    func testSilentWindowIsCutOnceItPassesTheFreezeThreshold() {
        let samples = [Float](repeating: 0, count: 90 * frame)
        let cut = LiveDecodeWindowPolicy.cutPoint(
            windowSampleCount: samples.count,
            frameRMS: LiveDecodeWindowPolicy.frameRMS(samples)
        )
        XCTAssertEqual(cut, 45 * frame)
    }

    // MARK: - join

    func testJoinInsertsASingleSpaceBetweenParts() {
        XCTAssertEqual(LiveDecodeWindowPolicy.join("Hello there", "friend"), "Hello there friend")
    }

    func testJoinTrimsDuplicateWhitespaceAtTheSeam() {
        XCTAssertEqual(LiveDecodeWindowPolicy.join("Hello  ", "  there"), "Hello there")
        XCTAssertEqual(LiveDecodeWindowPolicy.join("Hello\n", "\nthere"), "Hello there")
    }

    func testJoinDropsEmptyParts() {
        XCTAssertEqual(LiveDecodeWindowPolicy.join("", "there"), "there")
        XCTAssertEqual(LiveDecodeWindowPolicy.join("Hello", ""), "Hello")
        XCTAssertEqual(LiveDecodeWindowPolicy.join("   ", "  "), "")
    }
}
