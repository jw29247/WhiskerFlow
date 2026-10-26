import XCTest
@testable import WhiskerFlowAppSupport

final class MediaPausePolicyTests: XCTestCase {
    private let ownPID: Int32 = 500
    private let spotify = NowPlayingStatus(isPlaying: true, pid: 77)

    func testPausesOnlyWhatMacOSSaysIsPlaying() {
        XCTAssertEqual(MediaPausePolicy.decide(spotify, ownPID: ownPID, inCall: false), .pause)
        XCTAssertEqual(MediaPausePolicy.decide(NowPlayingStatus(isPlaying: false, pid: 77), ownPID: ownPID, inCall: false),
                       .notPlaying, "paused media stays paused, and nothing else is started")
    }

    /// When macOS can't be asked, pressing play/pause could start music, so
    /// nothing is pressed.
    func testUnknownStateDoesNothing() {
        XCTAssertEqual(MediaPausePolicy.decide(nil, ownPID: ownPID, inCall: false), .unknown)
    }

    func testNeverDuringACallOrForWhiskerFlowItself() {
        XCTAssertEqual(MediaPausePolicy.decide(spotify, ownPID: ownPID, inCall: true), .call)
        XCTAssertEqual(MediaPausePolicy.decide(NowPlayingStatus(isPlaying: true, pid: ownPID), ownPID: ownPID, inCall: false),
                       .ownApp)
    }

    /// A webcam utility, noise filter or meeting recorder holding the
    /// microphone used to stop every pause.
    func testOtherAppsOnTheMicrophoneDontStopThePause() {
        let inputs = [AudioInputProcess(pid: 9, bundleID: "com.elgato.CameraHub"),
                      AudioInputProcess(pid: 10, bundleID: "ai.krisp.krispMac")]
        XCTAssertEqual(MediaPausePolicy.decide(spotify, ownPID: ownPID, inCall: false,
                                               nowPlayingBundleID: "com.spotify.client", inputs: inputs), .pause)
    }

    /// The playing app is on a call nobody recognised: pausing would cut it.
    func testThePlayingAppOnTheMicrophoneIsACall() {
        func decide(_ bundleID: String?, _ input: AudioInputProcess) -> MediaPausePolicy.Decision {
            MediaPausePolicy.decide(spotify, ownPID: ownPID, inCall: false, nowPlayingBundleID: bundleID, inputs: [input])
        }
        XCTAssertEqual(decide(nil, AudioInputProcess(pid: 77, bundleID: nil)), .playingAppOnMicrophone)
        XCTAssertEqual(decide("com.google.Chrome", AudioInputProcess(pid: 81, bundleID: "com.google.Chrome.helper")),
                       .playingAppOnMicrophone)
        XCTAssertEqual(decide("com.apple.Safari", AudioInputProcess(pid: 82, bundleID: "com.apple.WebKit.GPU")),
                       .playingAppOnMicrophone)
        XCTAssertEqual(decide("com.google.Chrome", AudioInputProcess(pid: 83, bundleID: "com.google.ChromeRemoteDesktop")),
                       .pause, "a prefix that isn't a helper is another app")
        XCTAssertEqual(decide("com.spotify.client", AudioInputProcess(pid: 84, bundleID: "com.apple.WebKit.GPU")),
                       .pause, "Safari's call says nothing about Spotify")
    }

    func testResumesOnlyTheAppItPausedWhileItIsStillPaused() {
        XCTAssertEqual(MediaPausePolicy.resumeDecision(NowPlayingStatus(isPlaying: false, pid: 77), pausedPID: 77), .play)
        XCTAssertEqual(MediaPausePolicy.resumeDecision(nil, pausedPID: 77), .play, "the pause was ours")
        XCTAssertEqual(MediaPausePolicy.resumeDecision(NowPlayingStatus(isPlaying: true, pid: 77), pausedPID: 77),
                       .alreadyPlaying)
        XCTAssertEqual(MediaPausePolicy.resumeDecision(NowPlayingStatus(isPlaying: false, pid: 0), pausedPID: 77),
                       .appChanged, "with no app, play could start Music")
        XCTAssertEqual(MediaPausePolicy.resumeDecision(NowPlayingStatus(isPlaying: false, pid: 90), pausedPID: 77),
                       .appChanged)
    }

    func testReadsTheHelpersAnswer() {
        XCTAssertEqual(NowPlayingStatus.parse("playing=1\npid=52205\n"), NowPlayingStatus(isPlaying: true, pid: 52205))
        XCTAssertEqual(NowPlayingStatus.parse("playing=0\npid=0\n"), NowPlayingStatus(isPlaying: false, pid: 0))
        XCTAssertNil(NowPlayingStatus.parse(""), "no answer is unknown, not 'not playing'")
        XCTAssertNil(NowPlayingStatus.parse("garbage"))
        XCTAssertTrue(NowPlayingStatus.parseConfirmation("sent=1\nconfirmed=1\n"))
        XCTAssertFalse(NowPlayingStatus.parseConfirmation("sent=1\nconfirmed=0\n"))
        XCTAssertFalse(NowPlayingStatus.parseConfirmation("sent=1\n"))
    }

    func testResumesOnlyWhatItPaused() {
        var session = MediaPauseSession()
        XCTAssertNil(session.takeResume(), "nothing was paused")
        session.didPause(pid: 77)
        XCTAssertTrue(session.isPaused)
        XCTAssertEqual(session.takeResume(), 77)
        XCTAssertNil(session.takeResume(), "resumes once")
    }
}
