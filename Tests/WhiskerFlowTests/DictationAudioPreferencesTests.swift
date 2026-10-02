import XCTest
import WhiskerFlowAppSupport
@testable import WhiskerFlow

final class DictationAudioPreferencesTests: XCTestCase {
    @MainActor
    func testLivePreviewDefaultsOnAndRetiredEchoCancellationSettingIsCleared() {
        let name = "WhiskerFlow.audio-preferences-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "ignoreSpeakerAudio")
        defaults.set(["mic": 1.0], forKey: "voiceProcessingHungInputs")
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        XCTAssertTrue(settings.liveTranscription, "The HUD shows live text by default")
        XCTAssertNil(defaults.object(forKey: "ignoreSpeakerAudio"))
        XCTAssertNil(defaults.object(forKey: "voiceProcessingHungInputs"))
    }
}
