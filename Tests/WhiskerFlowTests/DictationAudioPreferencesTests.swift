import XCTest
import WhiskerFlowAppSupport
@testable import WhiskerFlow

final class DictationAudioPreferencesTests: XCTestCase {
    @MainActor
    func testSpeakerEchoCancellationAndLivePreviewDefaultOnAndPersist() {
        let name = "WhiskerFlow.audio-preferences-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        XCTAssertTrue(settings.ignoreSpeakerAudio, "Speaker playback must be cancelled out of dictation by default")
        XCTAssertTrue(settings.liveTranscription, "The HUD shows live text by default")

        settings.ignoreSpeakerAudio = false
        let reloaded = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        XCTAssertFalse(reloaded.ignoreSpeakerAudio)
    }
}
