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

/// Stands in for the resume delay: records what was asked for and returns at
/// once, so no test depends on how long a real sleep takes.
private final class ResumeDelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [UInt64] = []
    var requested: [UInt64] { lock.withLock { delays } }
    func sleep(_ nanoseconds: UInt64) { lock.withLock { delays.append(nanoseconds) } }
}

/// Holds a call inside the media helper until the test lets it finish.
private final class HeldCall: @unchecked Sendable {
    let entered: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func hold() {
        entered.fulfill()
        release.wait()
    }
    func finish() { release.signal() }
}

/// Counts calls across threads.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { () -> Int in count += 1; return count } }
}

@MainActor
final class DictationMediaPauserTests: XCTestCase {
    private let log = MediaCommandLog()
    private let delays = ResumeDelayLog()

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
        return pauser(readStatus: { box.status }, processes: processes, bundleIDs: bundleIDs,
                      send: { log.append($0); return true })
    }

    private func pauser(
        readStatus: @escaping @Sendable () -> NowPlayingStatus?,
        processes: [CoreAudioProcesses.Process] = [],
        bundleIDs: [Int32: String] = [:],
        send: @escaping @Sendable (DictationMediaPauser.Command) -> Bool
    ) -> DictationMediaPauser {
        let delays = delays
        return DictationMediaPauser(ownPID: 1, ownBundleID: "agency.thatworks.WhiskerFlow",
                                    readStatus: readStatus, readProcesses: { processes },
                                    bundleIDForPID: { bundleIDs[$0] }, send: send,
                                    sleep: { delays.sleep($0) })
    }

    /// Waits for the check, pause, resume and play already under way, in the
    /// order each can start the next.
    private func settle(_ pauser: DictationMediaPauser) async {
        await pauser.check?.value
        await pauser.pausing?.value
        await pauser.resume?.value
        await pauser.playing?.value
    }

    func testPausesWhatIsPlayingAndPlaysItAgainAfterDictation() async {
        let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
        let pauser = pauser(box)
        pauser.dictationStarted(inCall: false)
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause])
        box.status = NowPlayingStatus(isPlaying: false, pid: 42)
        pauser.dictationEnded()
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause, .play])
        XCTAssertEqual(delays.requested, [DictationMediaPauser.resumeDelayNanoseconds])
    }

    /// 2 October: the key was pressed with nothing playing, which started Music.
    func testNothingPlayingSendsNothing() async {
        for status in [NowPlayingStatus(isPlaying: false, pid: 42), NowPlayingStatus(isPlaying: false, pid: 0), nil] {
            let pauser = pauser(status)
            pauser.dictationStarted(inCall: false)
            await settle(pauser)
            pauser.dictationEnded()
            await settle(pauser)
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
        await settle(detected)
        await settle(undetected)
        XCTAssertEqual(log.sent, [])
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
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause])
    }

    func testBackToBackDictationsStayPaused() async {
        let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
        let pauser = pauser(box)
        pauser.dictationStarted(inCall: false)
        await settle(pauser)
        box.status = NowPlayingStatus(isPlaying: false, pid: 42)
        // The next dictation starts within the resume delay: the resume is
        // still pending when it is cancelled.
        pauser.dictationEnded()
        let pendingResume = pauser.resume
        pauser.dictationStarted(inCall: false)
        await pendingResume?.value
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause], "no play between, no second pause")
        pauser.dictationEnded()
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause, .play])
    }

    func testATapThatEndsBeforeTheCheckLeavesMediaAlone() async {
        let pauser = pauser(NowPlayingStatus(isPlaying: true, pid: 42))
        pauser.dictationStarted(inCall: false)
        let supersededCheck = pauser.check
        pauser.dictationEnded()
        await supersededCheck?.value
        await settle(pauser)
        XCTAssertEqual(log.sent, [])
    }

    /// Codex review of #20: a dictation that starts while the resume is still
    /// asking macOS what's playing must keep the media paused.
    func testDictationDuringTheResumeCheckStaysPaused() async {
        let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
        let resumeRead = HeldCall(expectation(description: "the resume is reading the status"))
        let reads = CallCounter()
        let log = log
        let pauser = pauser(
            // The second read is the first resume's check; it hangs until released.
            readStatus: {
                if reads.next() == 2 { resumeRead.hold() }
                return box.status
            },
            send: { log.append($0); return true }
        )
        pauser.dictationStarted(inCall: false)
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause])
        box.status = NowPlayingStatus(isPlaying: false, pid: 42)
        pauser.dictationEnded()
        let firstResume = pauser.resume
        await fulfillment(of: [resumeRead.entered], timeout: 10) // past the delay, inside the status read
        pauser.dictationStarted(inCall: false)
        resumeRead.finish()
        await firstResume?.value
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause], "no play while the second dictation records")
        pauser.dictationEnded()
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause, .play])
    }

    /// A dictation that starts while the play is still landing would read the
    /// media as paused and leave it playing into the recording.
    func testDictationWhilePlayIsLandingPausesAgain() async {
        let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
        let landing = HeldCall(expectation(description: "the play is sent"))
        let log = log
        let pauser = pauser(
            readStatus: { box.status },
            send: { command in
                log.append(command)
                if command == .play { landing.hold() }
                box.status = NowPlayingStatus(isPlaying: command == .play, pid: 42)
                return true
            }
        )
        pauser.dictationStarted(inCall: false)
        await settle(pauser)
        pauser.dictationEnded()
        await fulfillment(of: [landing.entered], timeout: 10) // the play is sent and has not landed yet
        XCTAssertEqual(log.sent, [.pause, .play])
        pauser.dictationStarted(inCall: false)
        landing.finish()
        await settle(pauser)
        XCTAssertEqual(log.sent, [.pause, .play, .pause])
    }

    /// The user played something else, or resumed it themselves, while
    /// dictating: playing again would be a second, unwanted press.
    func testDoesNotResumeWhenTheUserAlreadyChangedPlayback() async {
        for after in [NowPlayingStatus(isPlaying: true, pid: 42), NowPlayingStatus(isPlaying: false, pid: 99),
                      NowPlayingStatus(isPlaying: false, pid: 0)] {
            let box = NowPlayingBox(NowPlayingStatus(isPlaying: true, pid: 42))
            let pauser = pauser(box)
            pauser.dictationStarted(inCall: false)
            await settle(pauser)
            box.status = after
            pauser.dictationEnded()
            await settle(pauser)
        }
        XCTAssertEqual(log.sent, [.pause, .pause, .pause])
    }
}
