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

    func testCrashTextKeepsAssertionSignal() {
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText("Fatal error: Index out of range"),
            "Fatal error: Index out of range"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText("Unexpectedly found nil while unwrapping an Optional value"),
            "Unexpectedly found nil while unwrapping an Optional value"
        )
    }

    func testCrashTextRedactsHomeDirectories() {
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText(
                "Fatal error: file /Users/jacob/Projects/Client Pitch/Sources/App.swift, line 42"
            ),
            "Fatal error: file /Users/…, line 42"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText("could not read /home/jacob/.ssh/id_rsa"),
            "could not read /home/…"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText("stat failed for \"/Users/jacob.smith/Desktop\""),
            "stat failed for \"/Users/…\""
        )
    }

    func testCrashTextReducesContainerPathsToBasenames() {
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText(
                "write failed /private/var/folders/9x/qk8s1/T/whiskerflow/recording.wav"
            ),
            "write failed recording.wav"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText("/var/folders/9x/qk8s1/T/model.mlmodelc missing"),
            "model.mlmodelc missing"
        )
    }

    func testCrashTextRedactsMailAddressesAndIdentifiers() {
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText("licence check failed for jacob@thatworks.agency"),
            "licence check failed for …"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText(
                "device 4E1B2C3D-5A6F-4B8C-9D0E-1F2A3B4C5D6E unavailable"
            ),
            "device … unavailable"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText("hash a3f9c1d84b7e0526bb11ff9042cd77e1 mismatch"),
            "hash … mismatch"
        )
        XCTAssertEqual(
            DiagnosticPrivacy.sanitizedCrashText("bad address 0x00007ff8a1b2c3d4e5"),
            "bad address …"
        )
    }

    func testCrashTextHandlesMixedPayloads() throws {
        let result = try XCTUnwrap(DiagnosticPrivacy.sanitizedCrashText(
            """
            Fatal error: upload of /Users/jacob/Documents/NDA.pdf for jacob@thatworks.agency \
            from /private/var/folders/9x/qk8s1/T/staged.pdf failed \
            (device 4E1B2C3D-5A6F-4B8C-9D0E-1F2A3B4C5D6E)
            """
        ))
        XCTAssertTrue(result.hasPrefix("Fatal error: upload of /Users/…"))
        XCTAssertFalse(result.contains("jacob"))
        XCTAssertFalse(result.contains("NDA.pdf"))
        XCTAssertFalse(result.contains("thatworks"))
        XCTAssertFalse(result.contains("folders"))
        XCTAssertFalse(result.contains("4E1B2C3D"))
        XCTAssertTrue(result.contains("staged.pdf"))
        XCTAssertTrue(result.contains("failed"))
    }

    func testCrashTextIsHardTruncatedAndDropsEmptyValues() {
        let long = "Fatal error: " + String(repeating: "verbose framework detail ", count: 60)
        let sanitized = DiagnosticPrivacy.sanitizedCrashText(long)
        XCTAssertEqual(sanitized?.count, 300)
        XCTAssertTrue(sanitized?.hasPrefix("Fatal error: verbose") == true)
        XCTAssertTrue(sanitized?.hasSuffix("…") == true)

        XCTAssertNil(DiagnosticPrivacy.sanitizedCrashText(nil))
        XCTAssertNil(DiagnosticPrivacy.sanitizedCrashText(""))
        XCTAssertNil(DiagnosticPrivacy.sanitizedCrashText("   \n "))
        XCTAssertEqual(DiagnosticPrivacy.sanitizedCrashText("/Users/jacob/secret.txt"), "/Users/…")
    }
}
