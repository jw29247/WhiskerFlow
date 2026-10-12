import Foundation
import XCTest
@testable import WhiskerFlowAppSupport

final class PasteVerificationTests: XCTestCase {
    @MainActor
    func testUnresponsiveDestinationCannotBlockMainActorOrDeadline() async {
        let start = Date()
        let task = Task { await PasteVerification.verify(timeout: 0.05, minimumWait: 0) {
            Thread.sleep(forTimeInterval: 0.3)
            return true
        } }
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15, "AX work must not run on the main actor")
        let result = await task.value
        XCTAssertFalse(result, "Late verification must not turn timeout into success")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testSuccessfulVerificationHonoursClipboardConsumptionWindow() async {
        let start = Date()
        let result = await PasteVerification.verify(timeout: 0.2, minimumWait: 0.04) { true }
        XCTAssertTrue(result)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.035)
    }
}
