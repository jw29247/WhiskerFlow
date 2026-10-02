import XCTest
@testable import WhiskerFlow

@MainActor
final class DictationMediaPauserTests: XCTestCase {
    private var presses = 0

    private func pauser(_ processes: [CoreAudioProcesses.Process]) -> DictationMediaPauser {
        DictationMediaPauser(ownBundleID: "agency.thatworks.WhiskerFlow", readProcesses: { processes },
                             postPlayPause: { [unowned self] in self.presses += 1 })
    }

    private func playing(_ bundleID: String) -> CoreAudioProcesses.Process {
        .init(pid: 1, bundleID: bundleID, isRunningInput: false, isRunningOutput: true)
    }

    private func settle(_ seconds: Double = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testPausesWhatIsPlayingAndResumesAfterDictation() async {
        let pauser = pauser([playing("com.spotify.client")])
        pauser.dictationStarted(inCall: false)
        await settle()
        XCTAssertEqual(presses, 1)
        pauser.dictationEnded()
        await settle(0.6)
        XCTAssertEqual(presses, 2)
    }

    func testNothingPlayingPressesNothing() async {
        let pauser = pauser([])
        pauser.dictationStarted(inCall: false)
        await settle()
        pauser.dictationEnded()
        await settle(0.6)
        XCTAssertEqual(presses, 0)
    }

    func testCallsAndOtherMicrophoneUsersAreLeftAlone() async {
        let inCall = pauser([playing("com.spotify.client")])
        inCall.dictationStarted(inCall: true)
        await settle()
        XCTAssertEqual(presses, 0)

        let otherMic = pauser([playing("com.google.Chrome.helper"),
                               .init(pid: 2, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)])
        otherMic.dictationStarted(inCall: false)
        await settle()
        XCTAssertEqual(presses, 0)
    }

    func testBackToBackDictationsStayPaused() async {
        let pauser = pauser([playing("com.apple.Music")])
        pauser.dictationStarted(inCall: false)
        await settle()
        pauser.dictationEnded()
        pauser.dictationStarted(inCall: false)
        await settle(0.6)
        XCTAssertEqual(presses, 1, "no resume between, no second pause")
        pauser.dictationEnded()
        await settle(0.6)
        XCTAssertEqual(presses, 2)
    }
}
