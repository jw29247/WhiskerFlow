import XCTest
@testable import WhiskerFlowAppSupport

final class DiagnosticPrivacyTests: XCTestCase {
    func testOnlyAllowlistedCategoriesAreRecorded() {
        for category in ["recording", "audio", "model", "storage", "glossary", "network"] {
            XCTAssertTrue(DiagnosticPrivacy.allowsCategory(category))
        }
        for category in ["transcript", "clipboard", "microphone-name", "onboarding"] {
            XCTAssertFalse(DiagnosticPrivacy.allowsCategory(category))
        }
        XCTAssertFalse(DiagnosticPrivacy.allowsCategory(nil))
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

    func testSafeMetadataDropsFreeTextUnderAllowedKeys() {
        let metadata = DiagnosticPrivacy.safeMetadata(from: [
            "phase": "private dictated words",
            "source": "/Users/person/glossary.json",
            "model": String(repeating: "a", count: 65),
            "error_code": "",
            "stop_reason": "device_disconnected",
            "kept_rules": "12"
        ])
        XCTAssertEqual(metadata, ["stop_reason": "device_disconnected", "kept_rules": "12"])
    }
}
