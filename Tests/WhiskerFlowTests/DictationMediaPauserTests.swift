import XCTest
import WhiskerFlowAppSupport
@testable import WhiskerFlow

/// Records the commands sent to the Now Playing service.
final class MediaCommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [DictationMediaPauser.Command] = []
    var sent: [DictationMediaPauser.Command] { lock.withLock { commands } }
    func append(_ command: DictationMediaPauser.Command) { lock.withLock { commands.append(command) } }
}

/// A Now Playing state the test can change mid-dictation.
final class NowPlayingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NowPlayingStatus?
    init(_ value: NowPlayingStatus?) { self.value = value }
    var status: NowPlayingStatus? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
final class DictationMediaPauserTests: XCTestCase {
    private let log = MediaCommandLog()

    private func pauser(
        _ status: NowPlayingStatus?,
        processes: [CoreAudioProcesses.Process] = [],
        bundleIDs: [Int32: String] = [:]
    ) -> DictationMediaPauser {
        pauser(NowPlayingBox(status), processes: processes, bundleIDs: bundleIDs)
    }

    private func pauser(
        _ box: NowPlayingBox,
        processes: [CoreAudioProcesses.Process] = [],
        bundleIDs: [Int32: String] = [:]
    ) -> DictationMediaPauser {
        let log = log
        return DictationMediaPauser(ownPID: 1, ownBundleID: "agency.thatworks.WhiskerFlow",
                                    readStatus: { box.status }, readProcesses: { processes },
                                    bundleIDForPID: { bundleIDs[$0] },
                                    send: { log.append($0); return true })
    }

    private func settle(_ seconds: Double = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testPausesWhatIsPlayingAndPlaysItAgainAfterDictation() async {
        let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
        let pauser = pauser(box)
        pauser.dictationStarted(inCall: false)
        await settle()
        XCTAssertEqual(log.sent, [.pause])
        box.status = NowPlayingStatus(isPlaying: false, pid: 42)
        pauser.dictationEnded()
        await settle(0.6)
        XCTAssertEqual(log.sent, [.pause, .play])
    }

    /// 2 October: the key was pressed with nothing playing, which started Music.
    func testNothingPlayingSendsNothing() async {
        for status in [NowPlayingStatus(isPlaying: false, pid: 42), NowPlayingStatus(isPlaying: false, pid: 0), nil] {
            let pauser = pauser(status)
            pauser.dictationStarted(inCall: false)
            await settle()
            pauser.dictationEnded()
            await settle(0.6)
        }
        XCTAssertEqual(log.sent, [])
    }

    func testCallsAreLeftAlone() async {
        let detected = pauser(NowPlayingStatus(isPlaying: true, pid: 42))
        detected.dictationStarted(inCall: true)
        // The playing browser is itself on the microphone: a call.
        let undetected = pauser(NowPlayingStatus(isPlaying: true, pid: 42),
                                processes: [.init(pid: 43, bundleID: "com.google.Chrome.helper",
                                                  isRunningInput: true, isRunningOutput: true)],
                                bundleIDs: [42: "com.google.Chrome"])
        undetected.dictationStarted(inCall: false)
        await settle()
        XCTAssertEqual(log.sent, [])
        withExtendedLifetime((detected, undetected)) {}
    }

    /// A webcam app, or WhiskerFlow's own capture, on the microphone used to
    /// stop every pause.
    func testOtherMicrophoneUsersDontStopThePause() async {
        let processes: [CoreAudioProcesses.Process] = [
            .init(pid: 1, bundleID: "agency.thatworks.WhiskerFlow", isRunningInput: true, isRunningOutput: false),
            .init(pid: 7, bundleID: "com.logitech.logitune", isRunningInput: true, isRunningOutput: false),
        ]
        let pauser = pauser(NowPlayingStatus(isPlaying: true, pid: 42), processes: processes,
                            bundleIDs: [42: "com.spotify.client"])
        pauser.dictationStarted(inCall: false)
        await settle()
        XCTAssertEqual(log.sent, [.pause])
    }

    func testBackToBackDictationsStayPaused() async {
        let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
        let pauser = pauser(box)
        pauser.dictationStarted(inCall: false)
        await settle()
        box.status = NowPlayingStatus(isPlaying: false, pid: 42)
        pauser.dictationEnded()
        pauser.dictationStarted(inCall: false)
        await settle(0.6)
        XCTAssertEqual(log.sent, [.pause], "no play between, no second pause")
        pauser.dictationEnded()
        await settle(0.6)
        XCTAssertEqual(log.sent, [.pause, .play])
    }

    func testATapThatEndsBeforeTheCheckLeavesMediaAlone() async {
        let pauser = pauser(NowPlayingStatus(isPlaying: true, pid: 42))
        pauser.dictationStarted(inCall: false)
        pauser.dictationEnded()
        await settle(0.6)
        XCTAssertEqual(log.sent, [])
    }

    /// Codex review of #20: a dictation that starts while the resume is still
    /// asking macOS what's playing must keep the media paused.
    func testDictationDuringTheResumeCheckStaysPaused() async {
        let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
        let log = log
        let pauser = DictationMediaPauser(
            ownPID: 1, ownBundleID: "agency.thatworks.WhiskerFlow",
            readStatus: { Thread.sleep(forTimeInterval: 0.3); return box.status }, readProcesses: { [] },
            bundleIDForPID: { _ in nil }, send: { log.append($0); return true }
        )
        pauser.dictationStarted(inCall: false)
        await settle(0.5)
        XCTAssertEqual(log.sent, [.pause])
        box.status = NowPlayingStatus(isPlaying: false, pid: 42)
        pauser.dictationEnded()
        await settle(0.55) // past the 400 ms delay, inside the 300 ms status read
        pauser.dictationStarted(inCall: false)
        await settle(1)
        XCTAssertEqual(log.sent, [.pause], "no play while the second dictation records")
        pauser.dictationEnded()
        await settle(1.2)
        XCTAssertEqual(log.sent, [.pause, .play])
    }

    /// A dictation that starts while the play is still landing would read the
    /// media as paused and leave it playing into the recording.
    func testDictationWhilePlayIsLandingPausesAgain() async {
        let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
        let log = log
        let pauser = DictationMediaPauser(
            ownPID: 1, ownBundleID: "agency.thatworks.WhiskerFlow",
            readStatus: { box.status }, readProcesses: { [] }, bundleIDForPID: { _ in nil },
            send: { command in
                log.append(command)
                if command == .play { Thread.sleep(forTimeInterval: 0.3) }
                box.status = NowPlayingStatus(isPlaying: command == .play, pid: 42)
                return true
            }
        )
        pauser.dictationStarted(inCall: false)
        await settle()
        pauser.dictationEnded()
        await settle(0.5) // the play is sent and has not landed yet
        XCTAssertEqual(log.sent, [.pause, .play])
        pauser.dictationStarted(inCall: false)
        await settle(0.5)
        XCTAssertEqual(log.sent, [.pause, .play, .pause])
        withExtendedLifetime(pauser) {}
    }

    /// The user played something else, or resumed it themselves, while
    /// dictating: playing again would be a second, unwanted press.
    func testDoesNotResumeWhenTheUserAlreadyChangedPlayback() async {
        for after in [NowPlayingStatus(isPlaying: true, pid: 42), NowPlayingStatus(isPlaying: false, pid: 99),
                      NowPlayingStatus(isPlaying: false, pid: 0)] {
            let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
            let pauser = pauser(box)
            pauser.dictationStarted(inCall: false)
            await settle()
            box.status = after
            pauser.dictationEnded()
            await settle(0.6)
        }
        XCTAssertEqual(log.sent, [.pause, .pause, .pause])
    }
}
