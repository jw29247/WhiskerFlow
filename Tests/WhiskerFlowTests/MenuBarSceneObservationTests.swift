import XCTest
import SwiftUI
import Observation
import WhiskerFlowCore
import WhiskerFlowAppSupport
@testable import WhiskerFlow

final class MenuBarSceneObservationTests: XCTestCase {
    @MainActor
    func testRecordingChangeDoesNotInvalidateSceneConstruction() async {
        let name = "MenuBarObservation.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        let state = AppState(settings: settings, store: TranscriptStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)))
        let scene = WhiskerFlowMenuBarScene(appState: state, updaterService: UpdaterService(startingUpdater: false))
        withObservationTracking {
            _ = scene.body
        } onChange: {
            XCTFail("Recording icon changes must invalidate the label, not the scene and command menus")
        }
        let labelChanged = expectation(description: "Recording still updates the icon label")
        withObservationTracking {
            _ = WhiskerFlowMenuBarLabel(appState: state).body
        } onChange: {
            labelChanged.fulfill()
        }
        state.isRecording = true
        await fulfillment(of: [labelChanged], timeout: 1)
    }
}
