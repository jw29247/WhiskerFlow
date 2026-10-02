import XCTest
@testable import WhiskerFlowAppSupport

final class MediaPausePolicyTests: XCTestCase {
    private let own = "agency.thatworks.WhiskerFlow"

    func testPausesAMediaAppThatIsPlaying() {
        XCTAssertTrue(MediaPausePolicy.shouldPause(processesPlayingAudio: ["com.spotify.client.helper"], ownBundleID: own, inCall: false))
        XCTAssertTrue(MediaPausePolicy.shouldPause(processesPlayingAudio: ["com.apple.Music"], ownBundleID: own, inCall: false))
    }

    func testPausesABrowserPlayingAudio() {
        XCTAssertTrue(MediaPausePolicy.shouldPause(processesPlayingAudio: ["com.google.Chrome.helper"], ownBundleID: own, inCall: false))
        XCTAssertTrue(MediaPausePolicy.shouldPause(processesPlayingAudio: ["com.apple.WebKit.GPU"], ownBundleID: own, inCall: false))
    }

    /// Play/pause goes to the last "now playing" app. With nothing playing it
    /// would start that app instead, so silence never sends the key.
    func testNothingPlayingNeverSendsTheKey() {
        XCTAssertFalse(MediaPausePolicy.shouldPause(processesPlayingAudio: [], ownBundleID: own, inCall: false))
    }

    /// Apps that hold audio output open without playing media (call apps,
    /// chat apps, system sounds, WhiskerFlow itself) don't count.
    func testOtherAudioOutputDoesNotCount() {
        for bundleID in [own, "us.zoom.xos", "com.tinyspeck.slackmacgap.helper", "com.apple.systemsoundserverd",
                         "com.hnc.Discord", nil] as [String?] {
            XCTAssertFalse(MediaPausePolicy.shouldPause(processesPlayingAudio: [bundleID], ownBundleID: own, inCall: false),
                           "\(bundleID ?? "nil")")
        }
    }

    /// A call's audio is the conversation, and the media key could start music
    /// in the middle of it.
    func testNeverDuringACall() {
        XCTAssertFalse(MediaPausePolicy.shouldPause(processesPlayingAudio: ["com.spotify.client"], ownBundleID: own, inCall: true))
    }

    func testResumesOnlyWhatItPaused() {
        var session = MediaPauseSession()
        XCTAssertFalse(session.shouldResume(), "nothing was paused")
        session.didPause()
        XCTAssertTrue(session.shouldResume())
        XCTAssertFalse(session.shouldResume(), "resumes once")
    }
}
