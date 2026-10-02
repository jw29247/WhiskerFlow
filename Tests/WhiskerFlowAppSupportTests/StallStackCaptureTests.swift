import XCTest
@testable import WhiskerFlowAppSupport

final class StallStackCaptureTests: XCTestCase {
    func testLongMainTraceKeepsRootAndDeepCallsWithinBound() {
        let report = "90 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)\n"
            + (0..<100).map { "+ 90 frame\($0) (in AppKit) + 4 [0x123] /private/source.swift" }.joined(separator: "\n")
            + "\n90 Thread_2\n+ 90 otherThreadSecret (in Other)"
        let frames = StallStackCapture.mainThreadFrames(report)
        XCTAssertEqual(frames.count, 64)
        XCTAssertTrue(frames.first?.contains("frame0 ") == true)
        XCTAssertTrue(frames.last?.contains("frame99 ") == true)
        XCTAssertFalse(frames.joined().contains("private"))
        XCTAssertFalse(frames.joined().contains("0x123"))
        XCTAssertFalse(frames.joined().contains("otherThreadSecret"))
    }

    func testKeepsOnlyMainThreadSymbolsWithoutPathsOrOtherThreads() {
        let report = """
        Path: /Users/private/Secret.app
            90 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)
            + 90 applicationMain (in WhiskerFlow) + 8 [0x123] /Users/private/App.swift:2
            +   90 blockedCall (in Foundation) + 20 [0x456]
            90 Thread_2
            + 90 backgroundSecret (in Other) + 2 [0x789]
        Binary Images: /Users/private/Secret.app
        """
        let frames = StallStackCapture.mainThreadFrames(report)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames[1].contains("blockedCall"))
        XCTAssertFalse(frames.joined().contains("private"))
        XCTAssertFalse(frames.joined().contains("0x"))
        XCTAssertFalse(frames.joined().contains("backgroundSecret"))
    }

    func testSamplingIsSkippedDuringAudioCaptureOrMemoryPressure() {
        XCTAssertNil(StallStackCapture.skipReason(memoryPressure: "normal", audioCaptureActive: false))
        XCTAssertNil(StallStackCapture.skipReason(memoryPressure: "unknown", audioCaptureActive: false))
        XCTAssertEqual(StallStackCapture.skipReason(memoryPressure: "warning", audioCaptureActive: false), "memory_pressure")
        XCTAssertEqual(StallStackCapture.skipReason(memoryPressure: "critical", audioCaptureActive: false), "memory_pressure")
        XCTAssertEqual(StallStackCapture.skipReason(memoryPressure: "normal", audioCaptureActive: true), "audio_capture_active")
    }

    func testBuiltInSamplerReturnsMainThreadSymbols() throws {
        let report = try StallStackCapture.sample(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(StallStackCapture.mainThreadFrames(report).isEmpty)
    }

    func testNoMainThreadIsNotPassingEvidence() {
        XCTAssertTrue(StallStackCapture.mainThreadFrames("sample failed").isEmpty)
    }
    func testReportShapeDistinguishesMissingMainHeaderFromMissingSymbols() {
        let unnamed = StallStackCapture.reportShape("90 Thread_1\n+ 90 blocked (in AppKit)")
        XCTAssertEqual(unnamed["sample_thread_headers"], 1)
        XCTAssertEqual(unnamed["sample_main_headers"], 0)
        XCTAssertEqual(unnamed["sample_symbol_lines"], 1)
        let unsymbolicated = StallStackCapture.reportShape("90 Thread_1 com.apple.main-thread\n+ 90 0x123")
        XCTAssertEqual(unsymbolicated["sample_main_headers"], 1)
        XCTAssertEqual(unsymbolicated["sample_symbol_lines"], 0)
        XCTAssertEqual(Set(unnamed.keys), Set(["sample_report_bytes", "sample_thread_headers", "sample_main_headers", "sample_symbol_lines"]))
    }

    func testUnlabelledMainThreadMatchesExactThreadID() {
        let report = """
        90 Thread_1234
        + 90 wrongThread (in Other)
        90 Thread_123
        + 90 blockedMain (in AppKit) + 4 [0x123] /private/file.swift:2
        90 Thread_5
        + 90 other (in Other)
        """
        let frames = StallStackCapture.mainThreadFrames(report, mainThreadID: 123)
        XCTAssertEqual(frames, ["+ 90 blockedMain (in AppKit)"])
        XCTAssertTrue(StallStackCapture.mainThreadFrames(report, mainThreadID: 12).isEmpty)
    }

    @MainActor
    func testNativeMainThreadIDWorksWithoutQueueLabel() async throws {
        let id = try XCTUnwrap(StallStackCapture.currentMainThreadID())
        let report = try await Task.detached {
            try StallStackCapture.sample(pid: ProcessInfo.processInfo.processIdentifier)
        }.value
        let unlabelled = report.replacingOccurrences(of: "com.apple.main-thread", with: "unlabelled")
        XCTAssertFalse(StallStackCapture.mainThreadFrames(unlabelled, mainThreadID: id).isEmpty)
    }

}
