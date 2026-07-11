import XCTest
@testable import WhiskerFlowAppSupport

final class MicrophoneSelectionTests: XCTestCase {
    private let devices = [
        AudioInputDescriptor(uid: "builtin-uid", name: "MacBook Microphone", transientID: 80),
        AudioInputDescriptor(uid: "usb-uid", name: "USB Microphone", transientID: 101)
    ]

    func testMigratesAvailableLegacyNumericIDToStableUID() {
        XCTAssertEqual(
            MicrophoneSelection.migrate(legacyDeviceID: "101", devices: devices),
            .device(uid: "usb-uid")
        )
    }

    func testUnavailableLegacyNumericIDFallsBackToSystemDefault() {
        XCTAssertEqual(
            MicrophoneSelection.migrate(legacyDeviceID: "999", devices: devices),
            .systemDefault
        )
    }

    func testReconcileKeepsAvailableUIDAndFallsBackWhenItDisappears() {
        XCTAssertEqual(
            MicrophoneSelection.reconcile(.device(uid: "usb-uid"), devices: devices),
            .device(uid: "usb-uid")
        )
        XCTAssertEqual(
            MicrophoneSelection.reconcile(.device(uid: "missing"), devices: devices),
            .systemDefault
        )
    }

    func testSpecificDeviceRetriesOnceWithSystemDefault() {
        XCTAssertEqual(
            MicrophoneSelection.captureCandidates(for: .device(uid: "usb-uid")),
            [.device(uid: "usb-uid"), .systemDefault]
        )
    }

    func testSystemDefaultIsAttemptedOnlyOnce() {
        XCTAssertEqual(
            MicrophoneSelection.captureCandidates(for: .systemDefault),
            [.systemDefault]
        )
    }
}
