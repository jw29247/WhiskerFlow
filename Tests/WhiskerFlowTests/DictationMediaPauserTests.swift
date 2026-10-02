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

@MainActor
final class DictationMediaPauserTests: XCTestCase {
    private let log = MediaCommandLog()

    private func pauser(_ status: NowPlayingStatus?, processes: [CoreAudioProcesses.Process] = []) -> DictationMediaPauser {
        let log = log
        return DictationMediaPauser(ownPID: 1, ownBundleID: "agency.thatworks.WhiskerFlow",
                                    readStatus: { status }, readProcesses: { processes }, send: { log.append($0) })
    }

    private func settle(_ seconds: Double = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testPausesWhatIsPlayingAndPlaysItAgainAfterDictation() async {
        let pauser = pauser(NowPlayingStatus(isPlaying: true, pid: 42))
        pauser.dictationStarted(inCall: false)
        await settle()
        XCTAssertEqual(log.sent, [.pause])
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

    func testCallsAndOtherMicrophoneUsersAreLeftAlone() async {
        pauser(NowPlayingStatus(isPlaying: true, pid: 42)).dictationStarted(inCall: true)
        await settle()
        pauser(NowPlayingStatus(isPlaying: true, pid: 42),
               processes: [.init(pid: 2, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)])
            .dictationStarted(inCall: false)
        await settle()
        XCTAssertEqual(log.sent, [])
    }

    func testBackToBackDictationsStayPaused() async {
        let pauser = pauser(NowPlayingStatus(isPlaying: true, pid: 42))
        pauser.dictationStarted(inCall: false)
        await settle()
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
}
