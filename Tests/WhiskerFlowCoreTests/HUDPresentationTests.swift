import XCTest
@testable import WhiskerFlowCore

final class HUDPresentationTests: XCTestCase {
    func testClipboardSuccessShowsNotificationWhenNoLongerBusy() {
        let presentation = FloatingHUDPresentation.current(
            isRecording: false,
            isTranscribing: false,
            successMessage: "Copied to clipboard"
        )

        XCTAssertEqual(presentation, .notification("Copied to clipboard"))
        XCTAssertTrue(presentation.isVisible)
        XCTAssertTrue(presentation.hidesAutomatically)
    }
}
