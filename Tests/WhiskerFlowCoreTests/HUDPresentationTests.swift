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

    func testFailureShowsTheFailureStateForLongerThanSuccess() {
        let presentation = FloatingHUDPresentation.current(
            isRecording: false, isTranscribing: false, successMessage: nil,
            failureMessage: "Couldn’t paste. Your text is on the clipboard."
        )

        XCTAssertEqual(presentation, .failure("Couldn’t paste. Your text is on the clipboard."))
        XCTAssertTrue(presentation.hidesAutomatically)
        XCTAssertEqual(presentation.displayDuration, 4)
        XCTAssertEqual(FloatingHUDPresentation.notification("Pasted").displayDuration, 1.1)
    }

    func testNoSpeechIsShownAsAFailure() {
        let presentation = FloatingHUDPresentation.current(
            isRecording: false, isTranscribing: false, successMessage: nil, failureMessage: "No speech detected"
        )

        XCTAssertEqual(presentation, .failure("No speech detected"))
    }

    func testLiveStatesKeepTheirLookOverAnEarlierFailure() {
        XCTAssertEqual(FloatingHUDPresentation.current(isRecording: true, isTranscribing: false, successMessage: nil,
                                                       failureMessage: "No speech detected"), .recording)
        XCTAssertEqual(FloatingHUDPresentation.current(isRecording: false, isTranscribing: true, successMessage: nil,
                                                       failureMessage: "No speech detected"), .transcribing)
        XCTAssertNil(FloatingHUDPresentation.recording.displayDuration)
        XCTAssertNil(FloatingHUDPresentation.transcribing.displayDuration)
        XCTAssertEqual(FloatingHUDPresentation.current(isRecording: false, isTranscribing: false, successMessage: nil), .hidden)
    }
}
