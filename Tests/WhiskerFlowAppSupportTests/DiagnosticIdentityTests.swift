import XCTest
@testable import WhiskerFlowAppSupport

final class DiagnosticIdentityTests: XCTestCase {
    func testEachLaunchGetsItsOwnID() {
        let first = DiagnosticIdentity()
        let second = DiagnosticIdentity()
        XCTAssertNotNil(UUID(uuidString: first.launchID))
        XCTAssertNotEqual(first.launchID, second.launchID)
    }
}
