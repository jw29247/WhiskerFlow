import XCTest
@testable import WhiskerFlowCore

@MainActor
private final class FakeAnnouncer: DictationAnnouncing {
    var isActive = true
    var spoken: [String] = []
    func announce(_ message: String) { spoken.append(message) }
}

@MainActor
final class DictationAnnouncementTests: XCTestCase {
    func testEachDictationStepIsAnnouncedOnce() {
        let fake = FakeAnnouncer()
        let tracker = DictationAnnouncementTracker(announcer: fake)

        for presentation: FloatingHUDPresentation in [
            .recording, .recording, .transcribing, .notification("Pasting…"),
            .notification("Pasted"), .notification("Pasted"), .hidden
        ] {
            tracker.observe(presentation)
        }

        XCTAssertEqual(fake.spoken, ["Recording", "Transcribing", "Pasted"])
    }

    func testCopiedUsesTheHUDWording() {
        XCTAssertEqual(DictationAnnouncement.message(from: .transcribing, to: .notification("Copied to clipboard")),
                       "Copied to clipboard")
    }

    func testFailureIncludesTheReason() {
        XCTAssertEqual(DictationAnnouncement.message(from: .transcribing, to: .failure("No speech detected")),
                       "Dictation failed: No speech detected")
        XCTAssertEqual(DictationAnnouncement.message(from: .transcribing, to: .failure(" ")), "Dictation failed")
    }

    func testDiscardAndAutomaticStopSpeakTheirNotice() {
        XCTAssertEqual(DictationAnnouncement.message(from: .recording, to: .notification("Recording discarded")),
                       "Recording discarded")
        let autoStop = "Stopped after 2 minutes of silence. Saved to History."
        XCTAssertEqual(DictationAnnouncement.message(from: .transcribing, to: .notification(autoStop)), autoStop)
    }

    func testUnchangedAndHiddenStatesSayNothing() {
        XCTAssertNil(DictationAnnouncement.message(from: .recording, to: .recording))
        XCTAssertNil(DictationAnnouncement.message(from: .failure("x"), to: .failure("x")))
        XCTAssertNil(DictationAnnouncement.message(from: .notification("Pasted"), to: .hidden))
    }

    func testNothingIsAnnouncedWithoutVoiceOver() {
        let fake = FakeAnnouncer()
        fake.isActive = false
        let tracker = DictationAnnouncementTracker(announcer: fake)

        tracker.observe(.recording)
        tracker.observe(.transcribing)
        XCTAssertEqual(fake.spoken, [])

        // Turning VoiceOver on mid-dictation does not replay the earlier state.
        fake.isActive = true
        tracker.observe(.transcribing)
        tracker.observe(.notification("Pasted"))
        XCTAssertEqual(fake.spoken, ["Pasted"])
    }
}
