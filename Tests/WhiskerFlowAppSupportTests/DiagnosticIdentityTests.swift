import XCTest
@testable import WhiskerFlowAppSupport

final class DiagnosticIdentityTests: XCTestCase {
    func testInstallationIDPersistsAcrossLaunchesWithoutMachineIdentity() throws {
        let suite = "WhiskerFlow.DiagnosticIdentityTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DiagnosticIdentity(defaults: defaults)
        let second = DiagnosticIdentity(defaults: defaults)
        XCTAssertNotNil(UUID(uuidString: first.installationID))
        XCTAssertEqual(first.installationID, second.installationID)
        XCTAssertNotEqual(first.launchID, second.launchID)
    }

    func testMalformedStoredIDIsReplaced() throws {
        let suite = "WhiskerFlow.DiagnosticIdentityTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("private@example.com", forKey: "diagnostics.installationID")
        let identity = DiagnosticIdentity(defaults: defaults)
        XCTAssertNotNil(UUID(uuidString: identity.installationID))
        XCTAssertFalse(identity.installationID.contains("private"))
    }
}
