import XCTest
import Foundation
@testable import WhiskerFlow

final class SoundServiceTests: XCTestCase {
    @MainActor
    func testAudioPlaybackDoesNotRunOnDictationMainThread() async {
        let played = expectation(description: "Playback invoked")
        let service = SoundService { _ in
            XCTAssertFalse(Thread.isMainThread, "Audio device waits must not block dictation or paste")
            played.fulfill()
        }
        service.play(.transcriptionSucceeded)
        await fulfillment(of: [played], timeout: 2)
    }
}
