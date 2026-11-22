import AppKit
import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

private final class CopyingDeliveryService: TextDeliveryService {
    var hasAccessibilityPermission = true
    var copies: [String] = []
    func requestAccessibilityPermission() {}
    func copy(_ text: String) { copies.append(text) }
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?) async -> PasteDeliveryReceipt {
        XCTFail("the recording notice is never pasted")
        return PasteDeliveryReceipt(state: .failed, text: text, message: "")
    }
}

/// Silent tests: no microphone, capture, network or real clipboard.
@MainActor
final class MeetingRecordingNoticeTests: XCTestCase {
    private func settings() -> (AppSettings, UserDefaults, String) {
        let name = "MeetingRecordingNoticeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore.inMemory(service: name)), defaults, name)
    }

    // MARK: Notice text

    func testDefaultNoticeSaysRecordingTranscriptionAtlasAndHowToObject() {
        let text = MeetingRecordingNotice.defaultText
        XCTAssertTrue(text.contains("recording and transcribing this meeting"))
        XCTAssertTrue(text.contains("Atlas"))
        XCTAssertTrue(text.contains("rather I didn’t record"))
    }

    func testEmptyOrBlankCustomNoticeFallsBackToTheDefault() {
        for custom in ["", "   ", "\n\t "] {
            XCTAssertEqual(MeetingRecordingNotice.text(custom: custom), MeetingRecordingNotice.defaultText)
        }
    }

    func testCustomNoticeIsUsedTrimmed() {
        XCTAssertEqual(MeetingRecordingNotice.text(custom: "  Recording this one for the notes.\n"),
                       "Recording this one for the notes.")
    }

    func testCustomNoticeIsStoredAndEmptyByDefault() {
        let (settings, defaults, name) = settings()
        XCTAssertEqual(settings.meetingRecordingNotice, "", "a fresh install uses the default wording")
        settings.meetingRecordingNotice = "Recording for the notes."
        XCTAssertEqual(defaults.string(forKey: "meetingRecordingNotice"), "Recording for the notes.")
        let relaunched = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore.inMemory(service: name))
        XCTAssertEqual(relaunched.meetingRecordingNotice, "Recording for the notes.")
        relaunched.meetingRecordingNotice = ""
        XCTAssertEqual(MeetingRecordingNotice.text(custom: relaunched.meetingRecordingNotice), MeetingRecordingNotice.defaultText)
    }

    // MARK: Reminder per recording

    /// The call prompt, Record (or its shortcut) and the schedule each start a
    /// recording with a new session, through the coordinator's one start path.
    /// Each is reminded about, whatever happened to the previous reminder.
    func testEveryRecordingIsRemindedAboutWhateverHappenedBefore() {
        let reminder = MeetingRecordingReminder(wait: {})
        XCTAssertEqual(reminder.state, .hidden)
        XCTAssertFalse(reminder.isVisible(during: nil))

        let fromCallPrompt = UUID()
        reminder.recordingStarted(sessionID: fromCallPrompt)
        XCTAssertTrue(reminder.isVisible(during: fromCallPrompt))
        reminder.dismiss()
        XCTAssertFalse(reminder.isVisible(during: fromCallPrompt), "Dismiss hides it")

        let fromRecordButton = UUID()
        reminder.recordingStarted(sessionID: fromRecordButton)
        XCTAssertTrue(reminder.isVisible(during: fromRecordButton), "a dismissal does not carry over")
        reminder.copy("Notice") { _ in }
        XCTAssertTrue(reminder.isCopied)

        let fromSchedule = UUID()
        reminder.recordingStarted(sessionID: fromSchedule)
        XCTAssertEqual(reminder.state, .showing(sessionID: fromSchedule), "a copy does not carry over")
    }

    func testReminderStaysUntilDismissedOrCopiedAndGoesWithItsRecording() {
        let reminder = MeetingRecordingReminder(wait: {})
        let session = UUID()
        reminder.recordingStarted(sessionID: session)
        XCTAssertTrue(reminder.isVisible(during: session))
        XCTAssertFalse(reminder.isVisible(during: nil), "not once the recording has stopped")
        XCTAssertFalse(reminder.isVisible(during: UUID()), "not for another recording")
    }

    func testCopyConfirmsThenHides() async {
        var release: CheckedContinuation<Void, Never>?
        let waiting = expectation(description: "confirmation shown")
        let reminder = MeetingRecordingReminder(wait: {
            await withCheckedContinuation { release = $0; waiting.fulfill() }
        })
        let session = UUID()
        reminder.recordingStarted(sessionID: session)
        var copied: [String] = []
        reminder.copy("Recording for the notes.") { copied.append($0) }
        XCTAssertEqual(copied, ["Recording for the notes."])
        XCTAssertEqual(reminder.state, .copied(sessionID: session))
        XCTAssertTrue(reminder.isVisible(during: session), "the confirmation shows first")

        await fulfillment(of: [waiting], timeout: 5)
        reminder.copy("again") { copied.append($0) }
        XCTAssertEqual(copied.count, 1, "the confirmation has no second copy")
        release?.resume()
        await reminder.confirmationTask?.value
        XCTAssertEqual(reminder.state, .hidden)
    }

    func testANewRecordingDuringTheConfirmationIsNotHiddenByIt() async {
        var release: CheckedContinuation<Void, Never>?
        let waiting = expectation(description: "confirmation shown")
        let reminder = MeetingRecordingReminder(wait: {
            await withCheckedContinuation { release = $0; waiting.fulfill() }
        })
        reminder.recordingStarted(sessionID: UUID())
        reminder.copy("Notice") { _ in }
        await fulfillment(of: [waiting], timeout: 5)
        let task = reminder.confirmationTask
        let next = UUID()
        reminder.recordingStarted(sessionID: next)
        release?.resume()
        await task?.value
        XCTAssertEqual(reminder.state, .showing(sessionID: next))
    }

    func testNothingIsCopiedUnlessTheReminderIsShowing() {
        let reminder = MeetingRecordingReminder(wait: {})
        var copied: [String] = []
        reminder.copy("Notice") { copied.append($0) }
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(reminder.state, .hidden)
    }

    // MARK: Through the app

    /// Copy goes through the app's own copy path (`TextDeliveryService.copy`),
    /// with the custom wording, or the default when that is empty.
    func testCopyUsesTheAppsCopyPathAndTheCurrentWording() {
        let (settings, _, _) = settings()
        settings.playSounds = false
        let delivery = CopyingDeliveryService()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingRecordingNoticeTests.\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = AppState(settings: settings, store: TranscriptStore(fileURL: root.appendingPathComponent("t.json")),
                             pasteService: delivery)

        state.recordingReminder.recordingStarted(sessionID: UUID())
        state.copyMeetingRecordingNotice()
        XCTAssertEqual(delivery.copies, [MeetingRecordingNotice.defaultText])
        XCTAssertEqual(state.statusMessage, "Copied to clipboard")

        settings.meetingRecordingNotice = "Recording for the notes."
        state.recordingReminder.recordingStarted(sessionID: UUID())
        state.copyMeetingRecordingNotice()
        XCTAssertEqual(delivery.copies.last, "Recording for the notes.")

        state.dismissRecordingReminder()
        state.copyMeetingRecordingNotice()
        XCTAssertEqual(delivery.copies.count, 2, "nothing is copied once dismissed")
    }

    /// A recording that never starts raises no reminder: the schedule's start
    /// stops at the free-space check here, before any audio is captured.
    func testNoReminderWhenARecordingCouldNotStart() async {
        let (settings, _, name) = settings()
        settings.meetingModeEnabled = true
        let now = MeetingCaptureCoordinator.nowMs()
        settings.cacheMeetingSchedule([AtlasCaptureScheduleIntent(
            eventID: "sync", title: "Weekly sync", startMs: now - 60_000, endMs: now + 1_800_000,
            meetingURL: "https://meet.google.com/abc-defg-hij", location: nil, existingMeetingID: nil, overlapsPrevious: false)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let coordinator = MeetingCaptureCoordinator(
            settings: settings,
            microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()),
            transcription: TranscriptionService(),
            store: EncryptedMeetingChunkStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))),
            clientProvider: { nil },
            callDetector: CallDetectionService(readSignals: { CallDetectionSignals(inputs: [], windows: []) }),
            joinedMeetingProvider: { _ in true },
            diskStateReader: { "full" }
        )
        await coordinator.pollSchedule()
        XCTAssertEqual(coordinator.statusDetail, "At least 500 MB of local storage is required before recording.",
                       "Control: the schedule tried to record")
        XCTAssertEqual(coordinator.recordingReminder.state, .hidden)
    }
}
