import XCTest
@testable import WhiskerFlowAppSupport

final class DiagnosticPrivacyTests: XCTestCase {
    func testOnlyAllowlistedLifecycleCategoriesCanBecomeBreadcrumbs() {
        for category in ["recording", "audio", "model", "storage", "glossary"] {
            XCTAssertTrue(DiagnosticPrivacy.allowsBreadcrumb(category: category))
        }
        for category in ["transcript", "clipboard", "microphone-name", "network"] {
            XCTAssertFalse(DiagnosticPrivacy.allowsBreadcrumb(category: category))
        }
    }

    func testSafeMetadataDropsContentAndIdentifiers() {
        let metadata = DiagnosticPrivacy.safeMetadata(from: [
            "phase": "recording",
            "engine": "whisperKit",
            "error_code": "-10877",
            "transcript": "private dictated words",
            "audio_path": "/Users/person/recording.wav",
            "device_uid": "secret-device",
            "device_name": "Jacob's AirPods"
        ])
        XCTAssertEqual(metadata, [
            "phase": "recording",
            "engine": "whisperKit",
            "error_code": "-10877"
        ])
    }

    func testDebugImagePathsAreReducedToBasenames() {
        XCTAssertEqual(
            DiagnosticPrivacy.safeDebugImageName(
                "/private/tmp/WhiskerFlow.app/Contents/MacOS/WhiskerFlow"
            ),
            "WhiskerFlow"
        )
        XCTAssertEqual(DiagnosticPrivacy.safeDebugImageName("dyld"), "dyld")
        XCTAssertNil(DiagnosticPrivacy.safeDebugImageName(nil))
    }
}
