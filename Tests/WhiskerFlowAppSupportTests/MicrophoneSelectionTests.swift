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

    func testPreferredDeviceRemainsRememberedWhenItDisappears() {
        XCTAssertEqual(
            MicrophoneSelection.reconcile(
                .device(uid: "usb-uid"),
                devices: [devices[0]]
            ),
            .device(uid: "usb-uid")
        )
    }

    func testConnectedPreferredDeviceIsTriedBeforeSystemDefault() {
        XCTAssertEqual(
            MicrophoneSelection.captureCandidates(
                for: .device(uid: "usb-uid"),
                devices: devices
            ),
            [.device(uid: "usb-uid"), .systemDefault]
        )
    }

    func testDisconnectedPreferredDeviceUsesSystemDefaultWithoutForgettingIt() {
        XCTAssertEqual(
            MicrophoneSelection.captureCandidates(
                for: .device(uid: "usb-uid"),
                devices: [devices[0]]
            ),
            [.systemDefault]
        )
        XCTAssertEqual(
            MicrophoneSelection.reconcile(
                .device(uid: "usb-uid"),
                devices: [devices[0]]
            ),
            .device(uid: "usb-uid")
        )
    }

    func testSystemDefaultIsAttemptedOnlyOnce() {
        XCTAssertEqual(
            MicrophoneSelection.captureCandidates(
                for: .systemDefault,
                devices: devices
            ),
            [.systemDefault]
        )
    }
}
