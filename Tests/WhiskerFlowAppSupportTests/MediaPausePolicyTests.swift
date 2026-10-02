import XCTest
@testable import WhiskerFlowAppSupport

final class MediaPausePolicyTests: XCTestCase {
    private let ownPID: Int32 = 500

    func testPausesOnlyWhatMacOSSaysIsPlaying() {
        XCTAssertTrue(MediaPausePolicy.shouldPause(NowPlayingStatus(isPlaying: true, pid: 77), ownPID: ownPID, inCall: false))
        XCTAssertFalse(MediaPausePolicy.shouldPause(NowPlayingStatus(isPlaying: false, pid: 77), ownPID: ownPID, inCall: false),
                       "paused media stays paused, and nothing else is started")
    }

    /// When macOS can't be asked, pressing play/pause could start music, so
    /// nothing is pressed.
    func testUnknownStateDoesNothing() {
        XCTAssertFalse(MediaPausePolicy.shouldPause(nil, ownPID: ownPID, inCall: false))
    }

    func testNeverDuringACallOrForWhiskerFlowItself() {
        XCTAssertFalse(MediaPausePolicy.shouldPause(NowPlayingStatus(isPlaying: true, pid: 77), ownPID: ownPID, inCall: true))
        XCTAssertFalse(MediaPausePolicy.shouldPause(NowPlayingStatus(isPlaying: true, pid: ownPID), ownPID: ownPID, inCall: false))
    }

    func testReadsTheHelpersAnswer() {
        XCTAssertEqual(NowPlayingStatus.parse("playing=1\npid=52205\n"), NowPlayingStatus(isPlaying: true, pid: 52205))
        XCTAssertEqual(NowPlayingStatus.parse("playing=0\npid=0\n"), NowPlayingStatus(isPlaying: false, pid: 0))
        XCTAssertNil(NowPlayingStatus.parse(""), "no answer is unknown, not 'not playing'")
        XCTAssertNil(NowPlayingStatus.parse("garbage"))
    }

    func testResumesOnlyWhatItPaused() {
        var session = MediaPauseSession()
        XCTAssertFalse(session.shouldResume(), "nothing was paused")
        session.didPause()
        XCTAssertTrue(session.shouldResume())
        XCTAssertFalse(session.shouldResume(), "resumes once")
    }
}
