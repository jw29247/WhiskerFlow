import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

/// Esc with no dictation in progress must not change anything. The
/// preparing/recording paths are covered by `RecordingCoordinatorTests`; a live
/// capture needs a real microphone and is in the PR's manual test list.
final class DictationDiscardTests: XCTestCase {
    @MainActor
    func testEscapeWithNoDictationDoesNothing() {
        let name = "WhiskerFlow.discard-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore.inMemory(service: name))
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let state = AppState(settings: settings, store: store)
        state.status = .success("Pasted")

        XCTAssertFalse(state.discardDictation())
        XCTAssertEqual(state.status, .success("Pasted"), "No discard notice without a recording")
        XCTAssertFalse(state.isRecording)
        XCTAssertTrue(state.records.isEmpty)
    }
}
