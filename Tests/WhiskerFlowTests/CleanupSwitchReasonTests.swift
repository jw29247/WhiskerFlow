import XCTest
@testable import WhiskerFlow

/// The Cleanup switch is disabled until its model is downloaded; the reason
/// is shown beside it.
@MainActor
final class CleanupSwitchReasonTests: XCTestCase {
    func testAsksForTheDownloadBeforeTheModelIsInstalled() {
        XCTAssertEqual(CleanupSettingsView.switchUnavailableReason(supported: true, installed: false, enabled: false, downloading: false),
                       "Download the model below first")
    }

    func testSaysWhenADownloadIsUnderWay() {
        XCTAssertEqual(CleanupSettingsView.switchUnavailableReason(supported: true, installed: false, enabled: false, downloading: true),
                       "Available when the model below has downloaded")
    }

    func testNoReasonWhenTheSwitchCanBeUsed() {
        XCTAssertNil(CleanupSettingsView.switchUnavailableReason(supported: true, installed: true, enabled: false, downloading: false))
        // Still on with the model missing: the switch stays usable so it can be turned off.
        XCTAssertNil(CleanupSettingsView.switchUnavailableReason(supported: true, installed: false, enabled: true, downloading: false))
    }

    func testUnsupportedMacIsExplainedElsewhere() {
        XCTAssertNil(CleanupSettingsView.switchUnavailableReason(supported: false, installed: false, enabled: false, downloading: false))
    }
}
